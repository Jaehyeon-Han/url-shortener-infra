# codedeploy 모듈

Lambda Alias의 트래픽을 AWS CodeDeploy로 안전하게 전환하는 모듈이다.
Canary 전략으로 신규 버전에 점진적으로 트래픽을 흘리고, CloudWatch 알람이
ALARM이 되면 자동으로 이전 버전으로 롤백한다. 롤백/실패 이벤트와 알람은
SNS로 운영 담당자에게 통지한다.

실제 배포 트리거(`create-deployment`)와 appspec 생성은 **CI/CD가 담당**한다.
이 모듈은 CodeDeploy 앱/배포그룹/서비스역할/알람/SNS만 "준비"한다.

## 구성 리소스

- `aws_codedeploy_app` — compute_platform `Lambda` 애플리케이션.
- `aws_codedeploy_deployment_group` — 배포 설정(기본 Canary 10%/30분),
  알람 기반 자동 롤백(`DEPLOYMENT_STOP_ON_ALARM`), SNS 트리거.
- `aws_iam_role` + `AWSCodeDeployRoleForLambda` 관리형 정책 — CodeDeploy 서비스 역할.
- 에러 롤백 알람(`${name}-lambda-errors`) — 자동 롤백 기준. 지표는 `error_namespace`/`error_metric_name`이
  결정한다(기본 `AWS/Lambda`/`Errors`). `errors_alarm_mode`에 따라 차원이 둘 중 하나:
  - `alias`: 차원 `FunctionName` + `Resource(함수:alias)` 정적. CI 갱신 불필요.
  - `executed_version`: 고정 이름 "껍데기"만 만들고 차원/임계값/네임스페이스/지표명은 `ignore_changes`로 무시한다.
    CI가 배포 직전 `PutMetricAlarm`으로 `ExecutedVersion=신버전` 차원으로 갱신한다.
- API Gateway 5xx 알람(`${name}-apigw-5xx`) — `AWS/ApiGateway` `5xx`, 차원 `ApiId`.
  **자동 롤백 기준이 아니다**(버전 차원이 없어 Canary 중 신/구가 섞임). 상시 운영 알람으로 SNS 통지만 한다.
- `aws_sns_topic` + email 구독 + 토픽 정책 — 롤백/실패/알람 통지(CloudWatch·CodeDeploy publish 허용).

알람은 `period=180s`, `threshold=3`, `evaluation_periods=1`, `Sum`,
`GreaterThanOrEqualToThreshold`, `treat_missing_data=notBreaching`가 기본값이다.
즉 "3분 동안 에러가 3건 이상"이면 ALARM이다. 자동 롤백은 이 에러 알람만 기준으로 한다.

## 에러 지표 선택 (커스텀 메트릭)

롤백 알람이 보는 지표는 `error_namespace`/`error_metric_name`으로 바꿀 수 있다.

- 기본값은 `AWS/Lambda`의 `Errors`다. 핸들러의 예외가 함수 밖으로 전파되어 호출이 실패로
  끝나는 경우에 적합하다.
- 그러나 핸들러가 **try/catch로 예외를 삼키고 500을 정상 리턴**하면 `AWS/Lambda Errors`는
  0이라 롤백이 안 걸린다. 이 경우 핸들러가 `PutMetricData`로 올리는 커스텀 지표
  (예: 네임스페이스 `UrlShortener/App`, 지표 `HandlerErrors`)로 바꾼다. 차원 구조
  (`FunctionName` + `Resource` + `ExecutedVersion`)는 네임스페이스와 무관하게 동일하므로
  ExecutedVersion 동적 알람 로직을 그대로 쓴다.
- 커스텀 메트릭을 쓰려면 함수 **실행 역할**에 `cloudwatch:PutMetricData`가 필요하다
  (`modules/lambda`의 `metrics_namespace`로 부여). 핸들러 발행 구현은 `ci-reference/handler-metric.mjs` 참고.

## 알람 모드와 Canary 신버전 가드

Canary는 신/구 버전이 동시에 트래픽을 받는다. 그런데 CloudWatch 지표를 `FunctionName`
하나로만 집계하면 신/구가 합산돼, 신버전 문제가 소수 트래픽(10%)에서 희석되거나(미탐)
구버전 에러에 신버전이 말려 롤백될 수 있다(오탐).

그래서 `executed_version` 모드는 Lambda Errors 알람을 신버전만 보도록
`FunctionName` + `Resource(함수:alias)` + `ExecutedVersion(신버전 번호)` 차원으로 좁힌다.
버전 번호는 배포마다 바뀌는 런타임 값이라 Terraform이 정적으로 못 넣으므로,
Terraform은 고정 이름 알람과 SNS 연결·배포그룹 등록만 보장하고, CI가 배포 직전
`PutMetricAlarm`(upsert, 전체 덮어쓰기)으로 차원을 갱신한다. 이때 SNS 액션과 임계값도
함께 다시 지정해야 한다(덮어쓰기이므로).

API Gateway 5xx에는 Lambda 버전 차원이 없어 이 분리가 불가능하다. 따라서 롤백 기준에서
빼고 상시 운영 알람으로만 둔다.

## Inputs

| 이름 | 타입 | 기본값 | 설명 |
|---|---|---|---|
| `name` | string | (필수) | 리소스 이름 접두사 (예: `urlshortener-url`). |
| `lambda_function_name` | string | (필수) | 전환 대상 Lambda 함수 이름. Errors 알람 차원에 사용. |
| `lambda_alias_name` | string | `live` | CodeDeploy가 트래픽을 옮길 Alias 이름. lambda 모듈 `alias_name`과 일치해야 한다. |
| `deployment_config_name` | string | `CodeDeployDefault.LambdaCanary10Percent30Minutes` | 배포 전략. AllAtOnce/Linear 등으로 교체 가능. |
| `errors_alarm_mode` | string | `alias` | Lambda Errors 알람 집계 차원. `executed_version`(신버전만, CI 갱신) 또는 `alias`(정적). |
| `error_namespace` | string | `AWS/Lambda` | 롤백 기준 에러 지표의 네임스페이스. 커스텀 메트릭이면 `UrlShortener/App` 등. |
| `error_metric_name` | string | `Errors` | 롤백 기준 에러 지표명. 커스텀이면 `HandlerErrors` 등. |
| `api_id` | string | (필수) | HTTP API v2 ID. 상시 5xx 알람의 `ApiId` 차원. |
| `alarm_period_seconds` | number | `180` | 알람 평가 주기(초). |
| `alarm_threshold` | number | `3` | 주기당 지표 합(Sum) 임계값. |
| `notification_emails` | list(string) | `[]` | 롤백/실패/알람 통지 이메일. 각 주소로 SNS 구독 생성(확인 메일 필요). |
| `tags` | map(string) | `{}` | 공통 태그. |

## Outputs

| 이름 | 설명 |
|---|---|
| `app_name` | CodeDeploy 애플리케이션 이름 (CI `--application-name`). |
| `deployment_group_name` | 배포 그룹 이름 (CI `--deployment-group-name`). |
| `deployment_config_name` | 적용된 배포 설정 이름. |
| `service_role_arn` | CodeDeploy 서비스 역할 ARN. |
| `sns_topic_arn` | 통지 SNS 토픽 ARN. |
| `errors_alarm_name` | 자동 롤백 기준 Lambda Errors 알람 이름. `executed_version` 모드면 CI가 이 이름으로 `PutMetricAlarm`한다. |
| `errors_alarm_mode` | 적용된 알람 모드(`executed_version` \| `alias`). |
| `api_5xx_alarm_name` | 상시 운영 5xx 알람 이름(롤백 기준 아님). |

## CI/CD 연동

이 모듈이 만든 앱/배포그룹을 CI가 다음 흐름으로 사용한다.

1. `update-function-code --publish` → 신규 버전 번호 획득.
2. (`executed_version` 모드만) `errors_alarm_name` 알람을 `PutMetricAlarm`으로
   `ExecutedVersion=신버전` 차원으로 갱신한다. SNS 액션(`sns_topic_arn`)·임계값도 함께 지정.
3. `get-alias`로 현재(live) 버전 조회 → appspec(현재→신규) 생성.
4. `create-deployment`로 배포 시작(비블로킹). Canary/AllAtOnce는 배포 그룹 설정이 결정.

전환 결과(성공/롤백) 가시성은 CI 대기가 아니라 **SNS 알림**으로 받는다.

## 주의

- 같은 함수에 CodeDeploy 배포가 진행 중(Canary 30분)이면 새 `create-deployment`는
  거부된다. 운영상 "배포 중 재배포" 정책(대기/스킵)을 CI에서 정해둔다.
- CI 배포 역할(OIDC)에는 `lambda:UpdateFunctionCode/PublishVersion/GetAlias`,
  `cloudwatch:PutMetricAlarm`(executed_version 모드 알람 갱신용),
  `codedeploy:CreateDeployment/GetDeployment/GetDeploymentConfig`,
  CodeDeploy 서비스 역할 대상 `iam:PassRole`, S3 업로드 권한이 필요하다.
- `executed_version` 알람은 Terraform이 차원/임계값을 `ignore_changes`로 무시하므로,
  CI가 한 번도 갱신하지 않은 초기 상태에서는 alias 차원(초기값)으로 동작한다.
