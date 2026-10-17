// 이벤트 정규화 + 설정 역참조 순수 함수 단위 테스트다.
// 실행: node --test "modules/deploy-drainer/src/*.test.mjs"

import { test } from "node:test";
import assert from "node:assert/strict";
import {
  pkOf,
  parseDeployConfig,
  lookupConfigByFunction,
  lookupConfigByDeploymentGroup,
  normalizeEvent,
  buildPutMetricAlarmParams,
  buildAppSpecContent,
} from "./normalize.mjs";

const CONFIG = {
  "FN#urlshortener-url": {
    function: "urlshortener-url",
    alias: "live",
    codedeploy_app: "urlshortener-url",
    codedeploy_group: "urlshortener-url",
    errors_alarm_mode: "executed_version",
    errors_alarm_name: "urlshortener-url-lambda-errors",
    notify_topic_arn: "arn:aws:sns:ap-northeast-2:123:urlshortener-url-deploy-notify",
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

test("pkOf: 함수명을 FN# 접두 파티션키로 만든다", () => {
  assert.equal(pkOf("urlshortener-url"), "FN#urlshortener-url");
});

test("parseDeployConfig: JSON 문자열과 객체 모두 처리한다", () => {
  assert.deepEqual(parseDeployConfig(JSON.stringify(CONFIG)), CONFIG);
  assert.deepEqual(parseDeployConfig(CONFIG), CONFIG);
  assert.deepEqual(parseDeployConfig(undefined), {});
});

test("lookupConfigByFunction: 함수명으로 설정을 찾는다", () => {
  assert.equal(
    lookupConfigByFunction(CONFIG, "urlshortener-url").errors_alarm_mode,
    "executed_version",
  );
  assert.equal(lookupConfigByFunction(CONFIG, "nope"), undefined);
});

test("lookupConfigByDeploymentGroup: 배포 그룹명으로 설정을 찾는다", () => {
  assert.equal(
    lookupConfigByDeploymentGroup(CONFIG, "urlshortener-auth").function,
    "urlshortener-auth",
  );
  assert.equal(lookupConfigByDeploymentGroup(CONFIG, "nope"), undefined);
});

test("normalizeEvent: DynamoDB Streams INSERT/MODIFY를 enqueue로 정규화한다", () => {
  const event = {
    Records: [
      {
        eventSource: "aws:dynamodb",
        eventName: "MODIFY",
        dynamodb: {
          NewImage: {
            PK: { S: "FN#urlshortener-url" },
            desiredVersion: { S: "47" },
          },
        },
      },
    ],
  };
  const tasks = normalizeEvent(event);
  assert.equal(tasks.length, 1);
  assert.equal(tasks[0].eventType, "enqueue");
  assert.equal(tasks[0].functionName, "urlshortener-url");
});

test("normalizeEvent: REMOVE 레코드와 비-DDB 소스는 무시한다", () => {
  const event = {
    Records: [
      { eventSource: "aws:dynamodb", eventName: "REMOVE", dynamodb: { NewImage: null } },
      { eventSource: "aws:sqs", eventName: "INSERT" },
    ],
  };
  assert.deepEqual(normalizeEvent(event), []);
});

test("normalizeEvent: 자기 쓰기(desiredVersion 불변 MODIFY)는 스킵한다", () => {
  // 드레이너가 락을 획득/해제하면 desiredVersion은 그대로이고 다른 속성만 바뀐다 → enqueue 아님.
  const event = {
    Records: [
      {
        eventSource: "aws:dynamodb",
        eventName: "MODIFY",
        dynamodb: {
          OldImage: {
            PK: { S: "FN#urlshortener-url" },
            desiredVersion: { S: "47" },
          },
          NewImage: {
            PK: { S: "FN#urlshortener-url" },
            desiredVersion: { S: "47" }, // 안 바뀜.
            inFlightDeploymentId: { S: "d-1" }, // 드레이너가 락만 걺.
          },
        },
      },
    ],
  };
  assert.deepEqual(normalizeEvent(event), []);
});

test("normalizeEvent: desiredVersion이 바뀐 MODIFY는 enqueue다", () => {
  const event = {
    Records: [
      {
        eventSource: "aws:dynamodb",
        eventName: "MODIFY",
        dynamodb: {
          OldImage: { PK: { S: "FN#urlshortener-url" }, desiredVersion: { S: "47" } },
          NewImage: { PK: { S: "FN#urlshortener-url" }, desiredVersion: { S: "48" } },
        },
      },
    ],
  };
  const tasks = normalizeEvent(event);
  assert.equal(tasks.length, 1);
  assert.equal(tasks[0].eventType, "enqueue");
});

test("normalizeEvent: desiredVersion 없는 아이템 쓰기는 스킵한다", () => {
  // 락만 있고 아직 desiredVersion이 없는 초기 쓰기 등은 enqueue가 아니다.
  const event = {
    Records: [
      {
        eventSource: "aws:dynamodb",
        eventName: "INSERT",
        dynamodb: { NewImage: { PK: { S: "FN#urlshortener-url" }, inFlightDeploymentId: { S: "d-1" } } },
      },
    ],
  };
  assert.deepEqual(normalizeEvent(event), []);
});

test("normalizeEvent: EventBridge CodeDeploy 상태변경을 deployment-finished로 정규화한다", () => {
  const event = {
    source: "aws.codedeploy",
    "detail-type": "CodeDeploy Deployment State-change Notification",
    detail: {
      deploymentId: "d-ABC123",
      deploymentGroup: "urlshortener-url", // 실제 필드명은 deploymentGroup이다.
      application: "urlshortener-url",
      state: "SUCCESS",
    },
  };
  const tasks = normalizeEvent(event);
  assert.equal(tasks.length, 1);
  assert.equal(tasks[0].eventType, "deployment-finished");
  assert.equal(tasks[0].finishedDeploymentId, "d-ABC123");
  assert.equal(tasks[0].deploymentGroupName, "urlshortener-url");
  assert.equal(tasks[0].state, "SUCCESS");
});

test("normalizeEvent: 알 수 없는 이벤트는 빈 배열이다", () => {
  assert.deepEqual(normalizeEvent({ foo: "bar" }), []);
});

test("buildPutMetricAlarmParams: 신버전 ExecutedVersion 차원으로 구성한다", () => {
  const params = buildPutMetricAlarmParams(CONFIG["FN#urlshortener-url"], "48");
  assert.equal(params.AlarmName, "urlshortener-url-lambda-errors");
  assert.equal(params.Namespace, "UrlShortener/App");
  assert.equal(params.MetricName, "HandlerErrors");
  assert.equal(params.Threshold, 3);
  assert.equal(params.Period, 180);
  const execDim = params.Dimensions.find((d) => d.Name === "ExecutedVersion");
  assert.equal(execDim.Value, "48");
  const resDim = params.Dimensions.find((d) => d.Name === "Resource");
  assert.equal(resDim.Value, "urlshortener-url:live");
});

test("buildPutMetricAlarmParams: 필수 필드 없으면 던진다", () => {
  assert.throws(() =>
    buildPutMetricAlarmParams({ function: "x", errors_alarm_mode: "executed_version" }, "1"),
  );
});

test("buildAppSpecContent: CurrentVersion→TargetVersion appspec JSON을 만든다", () => {
  const content = buildAppSpecContent({
    functionName: "urlshortener-url",
    alias: "live",
    currentVersion: "45",
    targetVersion: "48",
  });
  const parsed = JSON.parse(content);
  assert.equal(parsed.version, 0.0);
  const props = parsed.Resources[0]["urlshortener-url"].Properties;
  assert.equal(props.CurrentVersion, "45");
  assert.equal(props.TargetVersion, "48");
  assert.equal(props.Alias, "live");
});
