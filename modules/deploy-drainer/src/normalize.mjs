// 드레이너 입력 정규화 + 설정 역참조 — 순수 함수(부작용 없음).
//
// 두 이벤트 소스(DynamoDB Streams / EventBridge CodeDeploy 상태변경)를 공통 형태로
// 정규화하고, DEPLOY_CONFIG(env JSON)에서 함수별 배포 설정을 역참조한다.
// AWS 호출과 분리해 단위 테스트로 검증한다(index.test.mjs). 실제 부작용은 index.mjs가 한다.

// DeployQueue의 파티션키 포맷. 함수당 1행이다.
export function pkOf(functionName) {
  return `FN#${functionName}`;
}

// DEPLOY_CONFIG(env)를 파싱한다. 키는 pkOf(functionName)="FN#<function>" 형태다.
// 값: { function, alias, codedeploy_app, codedeploy_group, errors_alarm_mode,
//       errors_alarm_name?, notify_topic_arn?, error_namespace?, error_metric_name?,
//       alarm_threshold?, alarm_period? }
export function parseDeployConfig(raw) {
  if (!raw) {
    return {};
  }
  return typeof raw === "string" ? JSON.parse(raw) : raw;
}

// 함수명으로 설정을 역참조한다. 없으면 undefined.
export function lookupConfigByFunction(deployConfig, functionName) {
  return deployConfig[pkOf(functionName)];
}

// CodeDeploy 배포 그룹명으로 설정을 역참조한다. deployment-finished 이벤트는 함수명이 아니라
// deploymentGroupName을 주므로, DEPLOY_CONFIG를 훑어 codedeploy_group이 일치하는 항목을 찾는다.
export function lookupConfigByDeploymentGroup(deployConfig, deploymentGroupName) {
  for (const key of Object.keys(deployConfig)) {
    const cfg = deployConfig[key];
    if (cfg && cfg.codedeploy_group === deploymentGroupName) {
      return cfg;
    }
  }
  return undefined;
}

// DynamoDB Streams NewImage(마셜링된 형태)에서 문자열 속성값을 꺼낸다.
// NewImage/OldImage는 { desiredVersion: { S: "47" }, lockExpiresAt: { N: "1760..." } } 형태다.
function ddbStr(image, name) {
  const v = image?.[name];
  if (!v) return undefined;
  if (v.S !== undefined) return v.S;
  if (v.N !== undefined) return v.N;
  return undefined;
}

// 단일 이벤트 레코드를 공통 형태로 정규화한다.
//
// 반환(정규화된 작업 단위) 또는 null(관심 없는 레코드):
//   {
//     eventType: "enqueue" | "deployment-finished",
//     functionName?: string,            // enqueue: PK에서 역산
//     deploymentGroupName?: string,     // deployment-finished
//     finishedDeploymentId?: string,    // deployment-finished
//     state?: string,                   // deployment-finished (SUCCESS/FAILURE/STOP)
//   }
export function normalizeEvent(event) {
  // --- 트리거 A: DynamoDB Streams (enqueue) ---
  if (Array.isArray(event?.Records)) {
    const results = [];
    for (const rec of event.Records) {
      if (rec.eventSource !== "aws:dynamodb") {
        continue;
      }
      // enqueue(INSERT/MODIFY)만 관심 있다. REMOVE(TTL 만료 등)는 무시한다.
      if (rec.eventName !== "INSERT" && rec.eventName !== "MODIFY") {
        continue;
      }
      const image = rec.dynamodb?.NewImage;
      const oldImage = rec.dynamodb?.OldImage;
      const pk = ddbStr(image, "PK");
      if (!pk || !pk.startsWith("FN#")) {
        continue;
      }

      // 자기 쓰기 필터: enqueue는 "desiredVersion 변경"으로만 정의한다. 드레이너 자신의 쓰기
      // (락 획득/배포ID 기록/해제 등)는 desiredVersion을 바꾸지 않으므로 OldImage==NewImage가 되어
      // 걸러진다. 이것이 없으면 드레이너의 자기 쓰기가 Streams로 자신을 재호출하는 증폭 루프가 생긴다.
      // (INSERT는 OldImage가 없다 → desiredVersion이 있으면 새 큐 적재로 보고 통과시킨다.)
      const newDesired = ddbStr(image, "desiredVersion");
      const oldDesired = ddbStr(oldImage, "desiredVersion");
      if (newDesired === undefined) {
        // desiredVersion이 아직 없는 아이템(락만 있는 등) → enqueue가 아니다.
        continue;
      }
      if (rec.eventName === "MODIFY" && newDesired === oldDesired) {
        // desiredVersion이 안 바뀐 MODIFY = 드레이너 자기 쓰기. 스킵.
        continue;
      }

      const functionName = pk.slice("FN#".length);
      results.push({ eventType: "enqueue", functionName });
    }
    return results;
  }

  // --- 트리거 B: EventBridge CodeDeploy 상태변경 (deployment-finished) ---
  if (
    event?.source === "aws.codedeploy" &&
    event?.["detail-type"] === "CodeDeploy Deployment State-change Notification"
  ) {
    const detail = event.detail ?? {};
    return [
      {
        eventType: "deployment-finished",
        // CodeDeploy 상태변경 이벤트의 detail 필드는 deploymentGroup / deploymentId / application / state 이다.
        // (일부 레거시/문서가 deploymentGroupName을 쓰기도 해 안전하게 fallback을 둔다.)
        deploymentGroupName: detail.deploymentGroup ?? detail.deploymentGroupName,
        finishedDeploymentId: detail.deploymentId,
        state: detail.state,
      },
    ];
  }

  // 알 수 없는 이벤트는 작업 없음.
  return [];
}

// executed_version 모드에서 신버전 기준 롤백 알람을 구성하는 PutMetricAlarm 파라미터를 만든다.
// (ci-reference/deploy.mjs의 updateExecutedVersionAlarm 로직을 이식한 순수 버전.)
// 반드시 CreateDeployment "직전"에 호출해야 한다(CodeDeploy가 배포 중 이 알람을 감시).
export function buildPutMetricAlarmParams(cfg, newVersion) {
  const threshold = Number(cfg.alarm_threshold ?? 3);
  const period = Number(cfg.alarm_period ?? 180);
  if (
    !cfg.errors_alarm_name ||
    !cfg.notify_topic_arn ||
    !cfg.error_namespace ||
    !cfg.error_metric_name
  ) {
    throw new Error(
      `executed_version 모드에는 errors_alarm_name, notify_topic_arn, error_namespace, error_metric_name이 필요하다 (function=${cfg.function})`,
    );
  }
  return {
    AlarmName: cfg.errors_alarm_name,
    AlarmDescription: `신규 버전(ExecutedVersion=${newVersion}) 에러 기준 자동 롤백 알람이다.`,
    Namespace: cfg.error_namespace,
    MetricName: cfg.error_metric_name,
    Statistic: "Sum",
    ComparisonOperator: "GreaterThanOrEqualToThreshold",
    Threshold: threshold,
    Period: period,
    EvaluationPeriods: 1,
    TreatMissingData: "notBreaching",
    // 신버전만 집계: alias 경유 + 실제 실행된 버전이 신버전인 호출.
    Dimensions: [
      { Name: "FunctionName", Value: cfg.function },
      { Name: "Resource", Value: `${cfg.function}:${cfg.alias || "live"}` },
      { Name: "ExecutedVersion", Value: String(newVersion) },
    ],
    AlarmActions: [cfg.notify_topic_arn],
    OKActions: [cfg.notify_topic_arn],
  };
}

// CodeDeploy appspec(AppSpecContent) 문자열을 만든다. CurrentVersion→TargetVersion 전환.
export function buildAppSpecContent({ functionName, alias, currentVersion, targetVersion }) {
  const appspec = {
    version: 0.0,
    Resources: [
      {
        [functionName]: {
          Type: "AWS::Lambda::Function",
          Properties: {
            Name: functionName,
            Alias: alias || "live",
            CurrentVersion: currentVersion,
            TargetVersion: targetVersion,
          },
        },
      },
    ],
  };
  return JSON.stringify(appspec);
}
