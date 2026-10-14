// scripts/deploy.mjs (참고용 — 코드(핸들러) 레포에 둔다)
//
// 역할: 패키징된 함수 zip을 S3에 올리고, 버전을 publish한 뒤,
//       (executed_version 모드 함수에 한해) 신버전 기준 롤백 알람을 갱신하고,
//       CodeDeploy 배포를 "트리거만" 한다(비블로킹).
//
// 트래픽 전환/알람 감시/자동 롤백은 AWS CodeDeploy가 수행하고,
// 롤백/실패·알람은 SNS로 통지된다. CI는 블로킹하지 않는다.
//
// 에러 지표에 대하여(중요):
//   핸들러가 try/catch로 예외를 삼키고 500을 정상 리턴하면 AWS/Lambda Errors가 0이라
//   롤백이 안 걸린다. 그래서 핸들러가 PutMetricData로 커스텀 메트릭을 발행하고
//   (ci-reference/handler-metric.mjs 참고), 롤백 알람은 그 커스텀 네임스페이스/지표를 본다.
//   아래 PutMetricAlarm도 Namespace/MetricName을 DEPLOY_MAP의 error_namespace/error_metric_name에서 읽는다.
//
// 알람 전략(errors_alarm_mode)
//   - "executed_version"(url, Canary): 신버전만 보도록 알람을 좁혀야 한다. 버전 번호는 배포마다
//     바뀌므로 Terraform의 "고정 이름" 알람을 이 스크립트가 PutMetricAlarm(upsert)으로
//     ExecutedVersion=신버전 차원으로 갱신한 뒤 배포한다. PutMetricAlarm은 통째로 덮어쓰므로
//     SNS 액션/임계값/네임스페이스/지표명도 함께 다시 지정한다.
//   - "alias"(auth, AllAtOnce): 알람 갱신 없이 Terraform 정적 알람을 그대로 쓴다.
//
// 사용: node scripts/deploy.mjs <handler>
//
// 환경변수:
//   DEPLOY_MAP  핸들러->배포 설정 매핑(JSON). 아래 형태.
//   BUCKET      아티팩트 S3 버킷 이름.
//   AWS_REGION  리전(SDK 기본 체인에서 읽어도 됨).
//
// DEPLOY_MAP 예시:
// {
//   "urls": { "function":"urlshortener-url","alias":"live",
//             "codedeploy_app":"urlshortener-url","codedeploy_group":"urlshortener-url",
//             "errors_alarm_mode":"executed_version",
//             "errors_alarm_name":"urlshortener-url-lambda-errors",
//             "error_namespace":"UrlShortener/App", "error_metric_name":"HandlerErrors",
//             "notify_topic_arn":"arn:aws:sns:ap-northeast-2:<acct>:urlshortener-url-deploy-notify",
//             "alarm_threshold":3, "alarm_period":180 },
//   "auth": { "function":"urlshortener-auth","alias":"live",
//             "codedeploy_app":"urlshortener-auth","codedeploy_group":"urlshortener-auth",
//             "errors_alarm_mode":"alias" }
// }

import {
  LambdaClient,
  UpdateFunctionCodeCommand,
  GetAliasCommand,
  waitUntilFunctionUpdatedV2,
} from "@aws-sdk/client-lambda";
import {
  CloudWatchClient,
  PutMetricAlarmCommand,
} from "@aws-sdk/client-cloudwatch";
import {
  CodeDeployClient,
  CreateDeploymentCommand,
} from "@aws-sdk/client-codedeploy";

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

const region = process.env.AWS_REGION;
const lambda = new LambdaClient({ region });
const cloudwatch = new CloudWatchClient({ region });
const codedeploy = new CodeDeployClient({ region });

const functionName = cfg.function;
const alias = cfg.alias || "live";
const s3Key = `${handler}/function.zip`;

// 1) 코드 업로드 + 버전 publish
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

// 2) (executed_version 모드) 신버전 기준으로 롤백 알람을 갱신한다.
//    PutMetricAlarm은 upsert이자 전체 덮어쓰기이므로 네임스페이스/지표명/SNS 액션/임계값을 모두 지정한다.
async function updateExecutedVersionAlarm(newVersion) {
  const alarmName = cfg.errors_alarm_name;
  const topicArn = cfg.notify_topic_arn;
  const namespace = cfg.error_namespace;
  const metricName = cfg.error_metric_name;
  if (!alarmName || !topicArn || !namespace || !metricName) {
    throw new Error(
      `executed_version 모드에는 errors_alarm_name, notify_topic_arn, error_namespace, error_metric_name이 필요하다 (handler=${handler})`,
    );
  }
  const threshold = Number(cfg.alarm_threshold ?? 3);
  const period = Number(cfg.alarm_period ?? 180);

  await cloudwatch.send(
    new PutMetricAlarmCommand({
      AlarmName: alarmName,
      AlarmDescription: `신규 버전(ExecutedVersion=${newVersion}) 에러 기준 자동 롤백 알람.`,
      Namespace: namespace,
      MetricName: metricName,
      Statistic: "Sum",
      ComparisonOperator: "GreaterThanOrEqualToThreshold",
      Threshold: threshold,
      Period: period,
      EvaluationPeriods: 1,
      TreatMissingData: "notBreaching",
      // 신버전만 집계: alias 경유 + 실제 실행된 버전이 신버전인 호출.
      Dimensions: [
        { Name: "FunctionName", Value: functionName },
        { Name: "Resource", Value: `${functionName}:${alias}` },
        { Name: "ExecutedVersion", Value: String(newVersion) },
      ],
      AlarmActions: [topicArn],
      OKActions: [topicArn],
    }),
  );
  console.log(
    `alarm ${alarmName} updated -> ${namespace}/${metricName} ExecutedVersion=${newVersion} (threshold ${threshold}/${period}s)`,
  );
}

// 3) CodeDeploy 배포 트리거(비블로킹). Canary/AllAtOnce는 배포 그룹 설정이 결정한다.
async function deploy(newVersion) {
  const cur = await lambda.send(
    new GetAliasCommand({ FunctionName: functionName, Name: alias }),
  );
  const currentVersion = cur.FunctionVersion;
  if (currentVersion === newVersion) {
    console.log(`alias already at ${newVersion}; nothing to shift.`);
    return;
  }

  const appspec = {
    version: 0.0,
    Resources: [
      {
        [functionName]: {
          Type: "AWS::Lambda::Function",
          Properties: {
            Name: functionName,
            Alias: alias,
            CurrentVersion: currentVersion,
            TargetVersion: newVersion,
          },
        },
      },
    ],
  };

  const res = await codedeploy.send(
    new CreateDeploymentCommand({
      applicationName: cfg.codedeploy_app,
      deploymentGroupName: cfg.codedeploy_group,
      revision: {
        revisionType: "AppSpecContent",
        appSpecContent: { content: JSON.stringify(appspec) },
      },
    }),
  );
  console.log(
    `codedeploy deployment started: ${res.deploymentId} ` +
      `(${currentVersion} -> ${newVersion}). 전환/롤백은 CodeDeploy가 수행하고 SNS로 통지된다.`,
  );
}

const version = await publishVersion();

// executed_version 모드면 배포 "전에" 알람을 신버전 기준으로 갱신한다.
// (CodeDeploy가 배포 중 이 알람을 감시하므로 반드시 create-deployment 이전에 갱신해야 한다.)
if (cfg.errors_alarm_mode === "executed_version") {
  await updateExecutedVersionAlarm(version);
}

await deploy(version);
