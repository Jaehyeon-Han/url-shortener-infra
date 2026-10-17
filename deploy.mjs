// scripts/deploy.mjs (코드(핸들러) 레포에 둔다)
//
// 역할(비동기 배포 큐 적재): 패키징된 함수 zip을 S3에 올린 뒤, 함수 코드를 갱신하고
//   새 버전을 publish한 다음, DynamoDB "DeployQueue" 테이블에 "원하는 버전(desiredVersion)"을
//   기록(enqueue)한다. 그리고 즉시 종료한다. CI는 러너를 점유한 채 배포 완료를 기다리지 않는다.
//
// 실제 CodeDeploy 배포(dequeue)는 별도 Terraform 레포가 소유하는 "드레이너 Lambda"가 수행한다.
//   - CodeDeploy는 배포 그룹당 활성 배포가 1개뿐이라, 동시 배포 충돌을 큐로 직렬화해야 한다.
//   - 드레이너는 DeployQueue를 조건부 락으로 소비하며 배포 그룹당 1개 제약을 지킨다.
//   - 트래픽 전환/알람 감시/자동 롤백/알람 갱신(executed_version)은 전부 드레이너·CodeDeploy가 담당한다.
//   - 설계 전체는 docs/async-deploy-drainer.md 참조(Terraform 레포 구현의 권위 있는 계약서).
//
// 왜 enqueue만 하나:
//   url(Canary) 배포 1회가 ~30분이라 CI가 블로킹 대기하면 러너 분을 과소비한다. 또 진행 중
//   배포가 있으면 CreateDeployment가 DeploymentLimitExceededException으로 거부되므로, CI에서
//   직접 트리거하면 충돌을 처리할 수 없다. 큐에 최신 버전만 적재(coalescing)하면 유실 없이
//   드레이너가 순차 배포한다. 각 머지가 자기 코드를 이미 publish하므로 최신 버전은 누적 코드를
//   포함한다 → 중간 버전 건너뜀은 코드 유실이 아니다.
//
// 사용: node scripts/deploy.mjs <handler>
//
// 환경변수:
//   DEPLOY_QUEUE_TABLE  DeployQueue DynamoDB 테이블명(필수). 드레이너와 공유한다.
//   DEPLOY_MAP          핸들러->배포 설정 매핑(JSON). 아래 형태(축소됨).
//   BUCKET              아티팩트 S3 버킷 이름(필수).
//   AWS_REGION          리전(SDK 기본 체인에서 읽어도 됨).
//
// DEPLOY_MAP 예시(축소: CI는 function/alias만 알면 된다. codedeploy_app/group, errors_alarm_* 등
// 배포/알람 설정은 전부 드레이너(Terraform 레포)로 이동했다):
// {
//   "urls": { "function": "urlshortener-url", "alias": "live" },
//   "auth": { "function": "urlshortener-auth", "alias": "live" }
// }

import {
  LambdaClient,
  UpdateFunctionCodeCommand,
  waitUntilFunctionUpdatedV2,
} from "@aws-sdk/client-lambda";
import { DynamoDBClient } from "@aws-sdk/client-dynamodb";
import { DynamoDBDocumentClient, UpdateCommand } from "@aws-sdk/lib-dynamodb";

const handler = process.argv[2];
if (!handler) {
  console.error("usage: node scripts/deploy.mjs <handler>");
  process.exit(1);
}

const deployMap = JSON.parse(process.env.DEPLOY_MAP || "{}");
const cfg = deployMap[handler];
if (!cfg) {
  console.error(`no deploy mapping for handler "${handler}"`);
  process.exit(1);
}

const bucket = process.env.BUCKET;
if (!bucket) {
  console.error("BUCKET env is required");
  process.exit(1);
}

const queueTable = process.env.DEPLOY_QUEUE_TABLE;
if (!queueTable) {
  console.error("DEPLOY_QUEUE_TABLE env is required");
  process.exit(1);
}

const region = process.env.AWS_REGION;
const lambda = new LambdaClient({ region });
const ddbDoc = DynamoDBDocumentClient.from(new DynamoDBClient({ region }), {
  marshallOptions: { removeUndefinedValues: true },
});

const functionName = cfg.function;
if (!functionName) {
  console.error(`DEPLOY_MAP["${handler}"].function is required`);
  process.exit(1);
}
const s3Key = `${handler}/function.zip`;

// 1) 코드 업로드 + 버전 publish.
//    각 머지는 자기 코드를 S3 키(<handler>/function.zip)로 올리고 Lambda 버전으로 박는다.
//    반환 Version이 이후 드레이너가 배포할 TargetVersion이 된다.
async function publishVersion() {
  const res = await lambda.send(
    new UpdateFunctionCodeCommand({
      FunctionName: functionName,
      S3Bucket: bucket,
      S3Key: s3Key,
      Publish: true,
    }),
  );
  await waitUntilFunctionUpdatedV2(
    { client: lambda, maxWaitTime: 120 },
    { FunctionName: functionName },
  );
  console.log(`published ${functionName} version ${res.Version}`);
  return res.Version;
}

// 2) DeployQueue에 desiredVersion을 enqueue(coalescing: 최신으로 덮어씀).
//    드레이너가 소유하는 속성(inFlightDeploymentId/deployedVersion/lockExpiresAt)은 건드리지 않는다.
//    (리포 간 계약: docs/async-deploy-drainer.md 9절)
async function enqueueDesiredVersion(version) {
  await ddbDoc.send(
    new UpdateCommand({
      TableName: queueTable,
      Key: { PK: `FN#${functionName}` },
      UpdateExpression:
        "SET desiredVersion = :v, updatedAt = :t",
      ExpressionAttributeValues: {
        ":v": String(version),
        ":t": new Date().toISOString(),
      },
    }),
  );
  console.log(
    `enqueued ${functionName} desiredVersion=${version} to ${queueTable}. ` +
      `드레이너가 배포 그룹 슬롯이 비면 CreateDeployment를 수행한다.`,
  );
}

const version = await publishVersion();
await enqueueDesiredVersion(version);
