// ci-reference/handler-metric.mjs (참고용 — 코드(핸들러) 레포에 반영한다)
//
// 문제: url/auth 핸들러가 try/catch로 예외를 삼키고 500을 "정상 리턴"하므로,
//       AWS/Lambda의 Errors 지표가 0이 되어 CodeDeploy 자동 롤백이 걸리지 않는다.
//
// 해결: 핸들러가 5xx를 반환하기 직전(catch 블록)에 커스텀 메트릭을 직접 발행한다.
//       이 메트릭을 CodeDeploy 롤백 기준 알람이 바라본다.
//
// 설계(인프라와 합의된 계약):
//   - Namespace : "UrlShortener/App"
//   - MetricName: "HandlerErrors"
//   - Dimensions: FunctionName + Resource(함수:alias) + ExecutedVersion(실행 버전)
//     → AWS/Lambda Errors와 동일한 차원 구조라, 알람(ExecutedVersion 동적 갱신)과 그대로 맞물린다.
//
// 핵심: 실행 중인 "버전 번호"는 Lambda context.functionVersion으로 얻는다.
//       Canary 중 신버전으로 실행된 호출이면 그 신버전 번호가 들어온다.
//
// 권한: 함수의 "실행 역할(execution role)"에 cloudwatch:PutMetricData가 필요하다.
//       (CI 배포 역할이 아니라 Lambda가 런타임에 쓰는 역할이다.)

import {
  CloudWatchClient,
  PutMetricDataCommand,
} from "@aws-sdk/client-cloudwatch";

const cw = new CloudWatchClient({}); // 리전은 람다 환경에서 자동 주입된다.

const NAMESPACE = "UrlShortener/App";
const METRIC = "HandlerErrors";
const ALIAS = process.env.LIVE_ALIAS || "live";

// 핸들러가 5xx로 끝날 때 호출한다. functionName/version은 context에서 얻는다.
// 메트릭 발행 실패가 응답을 막지 않도록 반드시 try/catch로 감싼다.
export async function emitHandlerError(context) {
  try {
    const functionName = context.functionName;
    // Canary 중 실제 실행된 버전. $LATEST일 수도 있으나, alias 호출 경로에선 숫자 버전이 온다.
    const version = context.functionVersion;

    await cw.send(
      new PutMetricDataCommand({
        Namespace: NAMESPACE,
        MetricData: [
          {
            MetricName: METRIC,
            Value: 1,
            Unit: "Count",
            Dimensions: [
              { Name: "FunctionName", Value: functionName },
              { Name: "Resource", Value: `${functionName}:${ALIAS}` },
              { Name: "ExecutedVersion", Value: String(version) },
            ],
          },
        ],
      }),
    );
  } catch (e) {
    // 메트릭 발행 실패는 삼킨다(응답에 영향 주지 않음). 로깅만.
    console.error("failed to emit HandlerErrors metric:", e);
  }
}

// --- 핸들러 적용 예시 ---
//
// export const handler = async (event, context) => {
//   try {
//     return await route(event, context);
//   } catch (err) {
//     console.error("ERROR:", err);
//     await emitHandlerError(context);   // ← 500 리턴 직전에 커스텀 메트릭 발행
//     return {
//       statusCode: 500,
//       headers: { "content-type": "application/json" },
//       body: JSON.stringify({ error: "internal error" }),
//     };
//   }
// };
//
// 주의:
// - 커스텀 메트릭은 "에러일 때만" 발행되므로 평소엔 데이터 포인트가 없다.
//   알람은 treat_missing_data=notBreaching이라, 에러가 없으면 자동으로 OK다(정상).
// - 차원의 ExecutedVersion은 context.functionVersion에서 온다. alias(live)를 통해 호출되면
//   Canary 신버전으로 실행된 요청엔 신버전 번호가, 구버전엔 구버전 번호가 들어가 자연히 분리된다.
