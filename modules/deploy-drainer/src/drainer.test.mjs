// 드레이너 오케스트레이션(drainer.mjs) 단위 테스트다. AWS SDK 없이 모킹한 clients/commands로
// "조건부 락 획득 → 알람 갱신 → GetAlias → CreateDeployment" 순서와 경쟁 흡수를 검증한다.
// 실행: node --test "modules/deploy-drainer/src/*.test.mjs"

import { test } from "node:test";
import assert from "node:assert/strict";
import { createDrainer } from "./drainer.mjs";

const CONFIG = {
  "FN#urlshortener-url": {
    function: "urlshortener-url",
    alias: "live",
    codedeploy_app: "urlshortener-url",
    codedeploy_group: "urlshortener-url",
    errors_alarm_mode: "executed_version",
    errors_alarm_name: "urlshortener-url-lambda-errors",
    notify_topic_arn: "arn:aws:sns:ap-northeast-2:123:url-notify",
    error_namespace: "UrlShortener/App",
    error_metric_name: "HandlerErrors",
    alarm_threshold: 3,
    alarm_period: 180,
  },
  "FN#urlshortener-auth": {
    function: "urlshortener-auth",
    alias: "live",
    codedeploy_app: "urlshortener-auth",
    codedeploy_group: "urlshortener-auth",
    errors_alarm_mode: "alias",
  },
};

// commands 빌더: params를 그대로 { kind, params } 태그 객체로 반환해, send가 종류를 식별하게 한다.
function makeCommands() {
  return {
    get: (p) => ({ kind: "get", params: p }),
    update: (p) => ({ kind: "update", params: p }),
    getAlias: (p) => ({ kind: "getAlias", params: p }),
    putMetricAlarm: (p) => ({ kind: "putMetricAlarm", params: p }),
    createDeployment: (p) => ({ kind: "createDeployment", params: p }),
  };
}

// 모의 환경을 만든다. item은 GetCommand가 반환할 현재 아이템.
// options로 각 send 동작을 커스터마이즈한다(조건부 실패/예외 등).
function makeEnv(item, options = {}) {
  const calls = [];
  const state = { item: { ...item } };

  const mkClient = (name) => ({
    async send(cmd) {
      calls.push({ client: name, kind: cmd.kind, params: cmd.params });
      if (cmd.kind === "get") {
        return { Item: Object.keys(state.item).length ? state.item : undefined };
      }
      if (cmd.kind === "update") {
        // 조건부 락 획득 시뮬레이션: options.lockContended면 ConditionalCheckFailed.
        const isAcquire =
          cmd.params.ConditionExpression?.includes("attribute_not_exists(inFlightDeploymentId)");
        if (isAcquire && options.lockContended) {
          const err = new Error("conditional");
          err.name = "ConditionalCheckFailedException";
          throw err;
        }
        return {};
      }
      if (cmd.kind === "getAlias") {
        return { FunctionVersion: options.currentAliasVersion ?? "45" };
      }
      if (cmd.kind === "putMetricAlarm") {
        return {};
      }
      if (cmd.kind === "createDeployment") {
        if (options.deploymentLimitExceeded) {
          const err = new Error("limit");
          err.name = "DeploymentLimitExceededException";
          throw err;
        }
        return { deploymentId: options.newDeploymentId ?? "d-NEW" };
      }
      return {};
    },
  });

  const clients = {
    ddb: mkClient("ddb"),
    lambda: mkClient("lambda"),
    cloudwatch: mkClient("cloudwatch"),
    codedeploy: mkClient("codedeploy"),
  };

  const drainer = createDrainer({
    clients,
    commands: makeCommands(),
    tableName: "DeployQueue",
    deployConfig: CONFIG,
    lockTtlSeconds: 2700,
    now: () => 1_760_000_000,
  });

  return { drainer, calls };
}

// enqueue 이벤트(DDB Streams) 하나짜리. desiredVersion이 바뀐 것으로 만들어 자기 쓰기 필터를 통과시킨다.
function enqueueEvent(functionName, desiredVersion = "999") {
  return {
    Records: [
      {
        eventSource: "aws:dynamodb",
        eventName: "MODIFY",
        dynamodb: {
          OldImage: { PK: { S: `FN#${functionName}` } }, // desiredVersion 없음(과거)
          NewImage: {
            PK: { S: `FN#${functionName}` },
            desiredVersion: { S: String(desiredVersion) }, // 바뀜 → enqueue로 인정
          },
        },
      },
    ],
  };
}

// deployment-finished 이벤트(EventBridge). 실제 필드명은 deploymentGroup이다.
function finishedEvent(groupName, deploymentId, state = "SUCCESS") {
  return {
    source: "aws.codedeploy",
    "detail-type": "CodeDeploy Deployment State-change Notification",
    detail: { deploymentGroup: groupName, deploymentId, state },
  };
}

test("enqueue + 슬롯 빔 + desired>deployed: 락획득→알람갱신→GetAlias→CreateDeployment 순서로 배포한다", async () => {
  const { drainer, calls } = makeEnv(
    { desiredVersion: "48", deployedVersion: "45" },
    { currentAliasVersion: "45", newDeploymentId: "d-100" },
  );
  const { results } = await drainer.handle(enqueueEvent("urlshortener-url"));

  assert.equal(results[0].action, "DEPLOYED");
  assert.equal(results[0].deployed, true);
  assert.equal(results[0].deploymentId, "d-100");

  // 순서 검증: get → update(락획득) → putMetricAlarm → getAlias → createDeployment → update(배포ID 기록)
  const kinds = calls.map((c) => c.kind);
  assert.deepEqual(kinds, [
    "get",
    "update",
    "putMetricAlarm",
    "getAlias",
    "createDeployment",
    "update",
  ]);

  // 락획득 UpdateCommand의 조건식 확인.
  const acquire = calls.find(
    (c) => c.kind === "update" && c.params.ConditionExpression?.includes("attribute_not_exists"),
  );
  assert.match(acquire.params.ConditionExpression, /lockExpiresAt < :now/);
});

test("경쟁: 조건부 락 획득 실패(ConditionalCheckFailed)면 NOOP로 흡수한다", async () => {
  const { drainer, calls } = makeEnv(
    { desiredVersion: "48", deployedVersion: "45" },
    { lockContended: true },
  );
  const { results } = await drainer.handle(enqueueEvent("urlshortener-url"));
  assert.equal(results[0].action, "NOOP");
  assert.equal(results[0].reason, "lock-contended");
  // 배포 관련 호출이 없어야 한다.
  assert.equal(calls.some((c) => c.kind === "createDeployment"), false);
});

test("alias 모드(auth)는 PutMetricAlarm 없이 배포한다", async () => {
  const { drainer, calls } = makeEnv(
    { desiredVersion: "10", deployedVersion: "9" },
    { currentAliasVersion: "9" },
  );
  const { results } = await drainer.handle(enqueueEvent("urlshortener-auth"));
  assert.equal(results[0].action, "DEPLOYED");
  assert.equal(calls.some((c) => c.kind === "putMetricAlarm"), false);
});

test("DeploymentLimitExceeded는 멱등 흡수(락 롤백 후 미배포)한다", async () => {
  const { drainer, calls } = makeEnv(
    { desiredVersion: "48", deployedVersion: "45" },
    { deploymentLimitExceeded: true },
  );
  const { results } = await drainer.handle(enqueueEvent("urlshortener-url"));
  assert.equal(results[0].deployed, false);
  assert.equal(results[0].reason, "deployment-limit-exceeded");
  // 롤백 update(REMOVE)가 호출됐는지 확인.
  const rollback = calls.find(
    (c) => c.kind === "update" && c.params.UpdateExpression?.startsWith("REMOVE"),
  );
  assert.ok(rollback);
});

test("alias가 이미 타깃 버전이면 배포하지 않고 락 롤백한다", async () => {
  const { drainer } = makeEnv(
    { desiredVersion: "48", deployedVersion: "45" },
    { currentAliasVersion: "48" },
  );
  const { results } = await drainer.handle(enqueueEvent("urlshortener-url"));
  assert.equal(results[0].deployed, false);
  assert.equal(results[0].reason, "alias-already-at-target");
});

test("deployment-finished(일치) + desired<=deployed: 락만 해제(RELEASE)한다", async () => {
  const { drainer, calls } = makeEnv({
    desiredVersion: "48",
    deployedVersion: "48",
    inFlightDeploymentId: "d-DONE",
    lockExpiresAt: 1_760_000_000 + 1000,
  });
  const { results } = await drainer.handle(finishedEvent("urlshortener-url", "d-DONE"));
  assert.equal(results[0].action, "RELEASE");
  // deployedVersion 갱신 + 락 해제 update가 있어야 한다.
  const release = calls.find(
    (c) => c.kind === "update" && c.params.UpdateExpression?.includes("REMOVE inFlightDeploymentId"),
  );
  assert.ok(release);
  // 배포는 없어야 한다.
  assert.equal(calls.some((c) => c.kind === "createDeployment"), false);
});

test("deployment-finished(불일치 배포ID)는 NOOP(멱등)다", async () => {
  const { drainer, calls } = makeEnv({
    desiredVersion: "50",
    deployedVersion: "45",
    inFlightDeploymentId: "d-CURRENT",
    lockExpiresAt: 1_760_000_000 + 1000,
  });
  const { results } = await drainer.handle(finishedEvent("urlshortener-url", "d-OTHER"));
  assert.equal(results[0].action, "NOOP");
  assert.equal(calls.some((c) => c.kind === "createDeployment"), false);
});

test("deployment-finished(일치) + desired>deployed: 해제 후 다음 배포(RELEASE_THEN_DEPLOY)", async () => {
  const { drainer, calls } = makeEnv(
    {
      desiredVersion: "50",
      deployedVersion: "48",
      inFlightDeploymentId: "d-DONE",
      lockExpiresAt: 1_760_000_000 + 1000,
    },
    { currentAliasVersion: "48", newDeploymentId: "d-200" },
  );
  const { results } = await drainer.handle(finishedEvent("urlshortener-url", "d-DONE"));
  assert.equal(results[0].action, "DEPLOYED");
  assert.equal(results[0].deploymentId, "d-200");
  // createDeployment가 호출됐는지 확인.
  assert.ok(calls.some((c) => c.kind === "createDeployment"));
});

test("관리하지 않는 함수/그룹은 NOOP(no-config)다", async () => {
  const { drainer } = makeEnv({ desiredVersion: "1" });
  const { results } = await drainer.handle(enqueueEvent("unknown-fn"));
  assert.equal(results[0].action, "NOOP");
  assert.equal(results[0].reason, "no-config");
});

// --- 롤백 정책(a 방식): FAILURE/STOP ---

test("FAILURE: 락 해제 + deployedVersion 유지 + 자동 재배포 없음", async () => {
  const { drainer, calls } = makeEnv({
    desiredVersion: "50",
    deployedVersion: "45",
    inFlightDeploymentId: "d-FAIL",
    lockExpiresAt: 1_760_000_000 + 1000,
  });
  const { results } = await drainer.handle(
    finishedEvent("urlshortener-url", "d-FAIL", "FAILURE"),
  );
  assert.equal(results[0].action, "RELEASE");
  assert.equal(results[0].keptVersion, true);
  assert.equal(results[0].state, "FAILURE");

  // 자동 재배포(createDeployment)가 없어야 한다.
  assert.equal(calls.some((c) => c.kind === "createDeployment"), false);

  // 락 해제 update는 deployedVersion을 SET하지 않아야 한다(버전 유지). lastDeployState만 기록.
  const release = calls.find(
    (c) => c.kind === "update" && c.params.UpdateExpression?.includes("REMOVE inFlightDeploymentId"),
  );
  assert.ok(release);
  assert.equal(release.params.UpdateExpression.includes("deployedVersion"), false);
  assert.match(release.params.UpdateExpression, /lastDeployState/);
});

test("STOP: FAILURE와 동일(락 해제 + 버전 유지 + 재배포 없음)", async () => {
  const { drainer, calls } = makeEnv({
    desiredVersion: "50",
    deployedVersion: "45",
    inFlightDeploymentId: "d-STOP",
    lockExpiresAt: 1_760_000_000 + 1000,
  });
  const { results } = await drainer.handle(
    finishedEvent("urlshortener-url", "d-STOP", "STOP"),
  );
  assert.equal(results[0].action, "RELEASE");
  assert.equal(results[0].keptVersion, true);
  assert.equal(results[0].state, "STOP");
  assert.equal(calls.some((c) => c.kind === "createDeployment"), false);
});

test("FAILURE 후 재개: 락 해제된 상태에서 새 enqueue가 오면 배포된다", async () => {
  // FAILURE 처리 후 상태(락 해제, desiredVersion 보존, deployedVersion 유지)에서 enqueue가 온다.
  const { drainer, calls } = makeEnv(
    { desiredVersion: "50", deployedVersion: "45" }, // inFlight 없음(해제됨).
    { currentAliasVersion: "45", newDeploymentId: "d-300" },
  );
  const { results } = await drainer.handle(enqueueEvent("urlshortener-url"));
  assert.equal(results[0].action, "DEPLOYED");
  assert.equal(results[0].deploymentId, "d-300");
  assert.ok(calls.some((c) => c.kind === "createDeployment"));
});
