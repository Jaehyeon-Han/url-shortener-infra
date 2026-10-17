// 드레이너 오케스트레이션 — 부작용 계층(단, AWS SDK에 직접 의존하지 않음).
//
// AWS SDK의 클라이언트와 "명령 빌더"를 의존성으로 주입받아, 어떤 AWS 호출을 어떤 순서로
// 할지를 결정한다. SDK import가 없으므로 node_modules 없이도 단위 테스트가 가능하다
// (이 Terraform 레포에는 @aws-sdk가 설치돼 있지 않다. 실제 SDK 배선은 index.mjs가 한다).
//
// 설계 async-deploy-drainer.md 5·6절을 구현한다.
// 핵심 순서: "조건부 락 획득 → (executed_version이면 알람 갱신) → CreateDeployment" = 리더 선출.

import { decideNextAction } from "./decide.mjs";
import {
  pkOf,
  lookupConfigByFunction,
  lookupConfigByDeploymentGroup,
  normalizeEvent,
  buildPutMetricAlarmParams,
  buildAppSpecContent,
} from "./normalize.mjs";

// deps:
//   clients: { ddb, lambda, cloudwatch, codedeploy }  — 각 { send(command) }
//   commands: {
//     get(params), update(params),                     // DynamoDBDocument
//     getAlias(params), putMetricAlarm(params), createDeployment(params),
//   }  — 각 params를 받아 SDK Command 인스턴스(또는 테스트용 플레인 객체)를 반환
//   tableName, deployConfig, lockTtlSeconds
//   now: () => epoch 초 (기본 Date.now 기반)
export function createDrainer(deps) {
  const {
    clients,
    commands,
    tableName,
    deployConfig,
    lockTtlSeconds,
    now = () => Math.floor(Date.now() / 1000),
  } = deps;

  async function loadItem(functionName) {
    const res = await clients.ddb.send(
      commands.get({ TableName: tableName, Key: { PK: pkOf(functionName) } }),
    );
    return res.Item ?? {};
  }

  // 조건부 락 획득: 슬롯이 비었거나(attribute_not_exists) 좀비 락(lockExpiresAt < now)일 때만 성공.
  // 성공 시 placeholder(PENDING) 락 + TTL을 세팅한다. 실패(ConditionalCheckFailed)면 false.
  async function acquireLock(functionName, nowSec) {
    try {
      await clients.ddb.send(
        commands.update({
          TableName: tableName,
          Key: { PK: pkOf(functionName) },
          UpdateExpression:
            "SET lockExpiresAt = :exp, inFlightDeploymentId = :pending, updatedAt = :t",
          ConditionExpression:
            "attribute_not_exists(inFlightDeploymentId) OR lockExpiresAt < :now",
          ExpressionAttributeValues: {
            ":exp": nowSec + lockTtlSeconds,
            ":now": nowSec,
            ":pending": "PENDING",
            ":t": new Date().toISOString(),
          },
        }),
      );
      return true;
    } catch (err) {
      if (err?.name === "ConditionalCheckFailedException") {
        return false;
      }
      throw err;
    }
  }

  async function recordDeploymentId(functionName, deploymentId, nowSec) {
    await clients.ddb.send(
      commands.update({
        TableName: tableName,
        Key: { PK: pkOf(functionName) },
        UpdateExpression:
          "SET inFlightDeploymentId = :id, lockExpiresAt = :exp, updatedAt = :t",
        ExpressionAttributeValues: {
          ":id": deploymentId,
          ":exp": nowSec + lockTtlSeconds,
          ":t": new Date().toISOString(),
        },
      }),
    );
  }

  async function releaseLock(functionName, deployedVersion) {
    await clients.ddb.send(
      commands.update({
        TableName: tableName,
        Key: { PK: pkOf(functionName) },
        UpdateExpression:
          "SET deployedVersion = :dv, updatedAt = :t REMOVE inFlightDeploymentId, lockExpiresAt",
        ExpressionAttributeValues: {
          ":dv": String(deployedVersion),
          ":t": new Date().toISOString(),
        },
      }),
    );
  }

  // 롤백/중지(FAILURE/STOP) 전용 락 해제. 락만 제거하고 deployedVersion은 올리지 않는다
  // (실패한 버전을 성공으로 기록하지 않음). desiredVersion도 건드리지 않아, 다음 enqueue가
  // 오면 그때 배포가 재개된다(a 방식). 관측용으로 마지막 종료 상태/실패 버전을 남긴다.
  async function releaseLockKeepVersion(functionName, state, failedVersion) {
    await clients.ddb.send(
      commands.update({
        TableName: tableName,
        Key: { PK: pkOf(functionName) },
        UpdateExpression:
          "SET lastDeployState = :s, lastFailedVersion = :fv, updatedAt = :t REMOVE inFlightDeploymentId, lockExpiresAt",
        ExpressionAttributeValues: {
          ":s": String(state ?? "FAILURE"),
          ":fv": String(failedVersion ?? ""),
          ":t": new Date().toISOString(),
        },
      }),
    );
  }

  async function rollbackLock(functionName) {
    await clients.ddb.send(
      commands.update({
        TableName: tableName,
        Key: { PK: pkOf(functionName) },
        UpdateExpression: "REMOVE inFlightDeploymentId, lockExpiresAt",
        ConditionExpression: "inFlightDeploymentId = :pending",
        ExpressionAttributeValues: { ":pending": "PENDING" },
      }),
    );
  }

  // 실제 배포 수행(조건부 락 획득 후 호출). 설계 5절 2a~2c.
  async function performDeploy(cfg, targetVersion, nowSec) {
    const functionName = cfg.function;
    const alias = cfg.alias || "live";

    // 2a) executed_version 모드면 CreateDeployment 직전 신버전 기준 알람 갱신.
    if (cfg.errors_alarm_mode === "executed_version") {
      await clients.cloudwatch.send(
        commands.putMetricAlarm(buildPutMetricAlarmParams(cfg, targetVersion)),
      );
    }

    // 2b) 현재 alias 버전 → appspec 구성.
    const aliasRes = await clients.lambda.send(
      commands.getAlias({ FunctionName: functionName, Name: alias }),
    );
    const currentVersion = aliasRes.FunctionVersion;
    if (String(currentVersion) === String(targetVersion)) {
      await rollbackLock(functionName);
      return { deployed: false, reason: "alias-already-at-target" };
    }

    const appSpecContent = buildAppSpecContent({
      functionName,
      alias,
      currentVersion,
      targetVersion,
    });

    // 2c) CreateDeployment → 반환 deploymentId를 락에 기록.
    try {
      const dep = await clients.codedeploy.send(
        commands.createDeployment({
          applicationName: cfg.codedeploy_app,
          deploymentGroupName: cfg.codedeploy_group,
          revision: {
            revisionType: "AppSpecContent",
            appSpecContent: { content: appSpecContent },
          },
        }),
      );
      await recordDeploymentId(functionName, dep.deploymentId, nowSec);
      return { deployed: true, deploymentId: dep.deploymentId };
    } catch (err) {
      // DeploymentLimitExceeded: 락은 잡았으나 AWS가 아직 '진행 중'인 찰나 → 멱등 흡수.
      if (err?.name === "DeploymentLimitExceededException") {
        await rollbackLock(functionName).catch(() => {});
        return { deployed: false, reason: "deployment-limit-exceeded" };
      }
      await rollbackLock(functionName).catch(() => {});
      throw err;
    }
  }

  async function processTask(task) {
    const nowSec = now();

    let cfg;
    let functionName;
    if (task.eventType === "enqueue") {
      functionName = task.functionName;
      cfg = lookupConfigByFunction(deployConfig, functionName);
    } else if (task.eventType === "deployment-finished") {
      cfg = lookupConfigByDeploymentGroup(deployConfig, task.deploymentGroupName);
      functionName = cfg?.function;
    }
    if (!cfg || !functionName) {
      return { action: "NOOP", reason: "no-config" };
    }

    const item = await loadItem(functionName);
    const decision = decideNextAction({
      eventType: task.eventType,
      desiredVersion: item.desiredVersion,
      deployedVersion: item.deployedVersion,
      inFlightDeploymentId: item.inFlightDeploymentId,
      finishedDeploymentId: task.finishedDeploymentId,
      state: task.state,
      now: nowSec,
      lockExpiresAt: item.lockExpiresAt,
    });

    switch (decision.action) {
      case "NOOP":
        return { action: "NOOP" };

      case "RELEASE": {
        if (decision.keepDeployedVersion) {
          // 롤백/중지(FAILURE/STOP): 락만 해제, deployedVersion 유지, 자동 재배포 없음.
          await releaseLockKeepVersion(functionName, task.state, item.desiredVersion);
          return { action: "RELEASE", keptVersion: true, state: task.state };
        }
        // 성공 종료: deployedVersion을 방금 끝난 목표로 갱신하고 락 해제.
        await releaseLock(functionName, item.desiredVersion ?? item.deployedVersion);
        return { action: "RELEASE" };
      }

      case "RELEASE_THEN_DEPLOY": {
        if (task.eventType === "deployment-finished") {
          // 방금 끝난 배포 처리: deployedVersion을 보수적으로 갱신한 뒤 다음 배포로 넘어간다.
          // (정확한 현재 버전은 performDeploy의 GetAlias가 다시 읽어 보정한다.)
          await releaseLock(functionName, item.deployedVersion ?? "0");
        }
        const acquired = await acquireLock(functionName, nowSec);
        if (!acquired) {
          return { action: "NOOP", reason: "lock-contended" };
        }
        return {
          action: "DEPLOYED",
          ...(await performDeploy(cfg, decision.version, nowSec)),
        };
      }

      case "DEPLOY": {
        const acquired = await acquireLock(functionName, nowSec);
        if (!acquired) {
          return { action: "NOOP", reason: "lock-contended" };
        }
        return {
          action: "DEPLOYED",
          ...(await performDeploy(cfg, decision.version, nowSec)),
        };
      }

      default:
        return { action: "NOOP" };
    }
  }

  async function handle(event) {
    const tasks = normalizeEvent(event);
    const results = [];
    for (const task of tasks) {
      results.push(await processTask(task));
    }
    return { results };
  }

  return { handle, processTask };
}
