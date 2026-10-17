// 드레이너 Lambda 런타임 진입점 — 실제 AWS SDK 배선.
//
// 오케스트레이션(어떤 호출을 어떤 순서로 할지)은 drainer.mjs가 SDK 비의존으로 담당한다.
// 이 파일은 AWS SDK 클라이언트와 "명령 빌더"를 실제 구현으로 채워 createDrainer에 주입하고,
// 환경변수(DEPLOY_QUEUE_TABLE, DEPLOY_CONFIG, LOCK_TTL_SECONDS)를 읽어 설정한다.
// handler가 Lambda 진입점이다.

import { LambdaClient, GetAliasCommand } from "@aws-sdk/client-lambda";
import {
  CloudWatchClient,
  PutMetricAlarmCommand,
} from "@aws-sdk/client-cloudwatch";
import {
  CodeDeployClient,
  CreateDeploymentCommand,
} from "@aws-sdk/client-codedeploy";
import { DynamoDBClient } from "@aws-sdk/client-dynamodb";
import {
  DynamoDBDocumentClient,
  GetCommand,
  UpdateCommand,
} from "@aws-sdk/lib-dynamodb";

import { createDrainer } from "./drainer.mjs";
import { parseDeployConfig } from "./normalize.mjs";

function buildDefaultDrainer() {
  const region = process.env.AWS_REGION;
  const tableName = process.env.DEPLOY_QUEUE_TABLE;
  const deployConfig = parseDeployConfig(process.env.DEPLOY_CONFIG);
  const lockTtlSeconds = Number(process.env.LOCK_TTL_SECONDS ?? 2700);

  const ddbDoc = DynamoDBDocumentClient.from(new DynamoDBClient({ region }), {
    marshallOptions: { removeUndefinedValues: true },
  });

  return createDrainer({
    clients: {
      ddb: ddbDoc,
      lambda: new LambdaClient({ region }),
      cloudwatch: new CloudWatchClient({ region }),
      codedeploy: new CodeDeployClient({ region }),
    },
    commands: {
      get: (p) => new GetCommand(p),
      update: (p) => new UpdateCommand(p),
      getAlias: (p) => new GetAliasCommand(p),
      putMetricAlarm: (p) => new PutMetricAlarmCommand(p),
      createDeployment: (p) => new CreateDeploymentCommand(p),
    },
    tableName,
    deployConfig,
    lockTtlSeconds,
  });
}

let _drainer;
export const handler = async (event) => {
  if (!_drainer) {
    _drainer = buildDefaultDrainer();
  }
  return _drainer.handle(event);
};
