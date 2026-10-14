# ci-reference

이 디렉토리는 **참고용**이다. 이 레포는 인프라(Terraform) 레포이고,
핸들러 코드와 CI 스크립트는 별도 **코드 레포**에 있다. 인프라와 CI의 계약을
한곳에 문서화해, 코드 레포에 복사·반영하는 것을 전제로 한다.

## 파일

- `deploy.mjs` — 코드 레포의 `scripts/deploy.mjs`가 될 참조 구현. zip을 S3에 올리고
  버전을 publish한 뒤, (executed_version 모드면) 롤백 알람을 신버전으로 갱신하고
  CodeDeploy 배포를 트리거한다(비블로킹).
- `handler-metric.mjs` — 핸들러가 catch에서 커스텀 에러 지표를 발행하는 참조 구현.
  핸들러가 try/catch로 500을 정상 리턴해 AWS/Lambda Errors가 0이 되는 문제를 푼다.
- `cicd.yml` — GitHub Actions 워크플로의 "배포 경로" 스텝 참조본.

## 왜 커스텀 메트릭인가

url/auth 핸들러는 예외를 try/catch로 잡아 500을 **정상 리턴**한다. 그러면 Lambda 런타임은
"성공"으로 집계해 `AWS/Lambda` `Errors` 지표가 0이 되고, 그 지표를 보는 CodeDeploy 롤백
알람은 영원히 울리지 않는다. 그래서 핸들러가 catch에서 `PutMetricData`로 커스텀 지표를
직접 발행하고, 롤백 알람은 그 지표를 본다.

- 네임스페이스: `UrlShortener/App`
- 지표명: `HandlerErrors`
- 차원: `FunctionName` + `Resource`(함수:alias) + `ExecutedVersion`(실행 버전)
  → `AWS/Lambda Errors`와 동일 차원 구조라 ExecutedVersion 동적 알람과 그대로 맞물린다.
- 발행 시점: 핸들러 catch(5xx 리턴 직전). 에러일 때만 발행되므로 평소엔 데이터가 없고,
  알람은 `treat_missing_data=notBreaching`이라 에러 없으면 OK다.

## 인프라 ↔ CI 계약

Terraform 루트 출력을 CI 변수에 매핑한다. 손으로 조립하지 말고 아래로 한 번에 뽑는다.

```bash
terraform output -raw lambda_deploy_map
```

결과를 GitHub 레포 Settings → Secrets and variables → Actions → **Variables**의
`LAMBDA_DEPLOY_MAP`에 붙여넣는다(secret 아님 — 민감값 없음, CI 로그에 출력됨).

`lambda_deploy_map`이 만드는 JSON(요지):

```json
{
  "urls": { "function": "urlshortener-url", "alias": "live",
            "codedeploy_app": "urlshortener-url", "codedeploy_group": "urlshortener-url",
            "errors_alarm_mode": "executed_version",
            "errors_alarm_name": "urlshortener-url-lambda-errors",
            "error_namespace": "UrlShortener/App", "error_metric_name": "HandlerErrors",
            "notify_topic_arn": "arn:aws:sns:...:urlshortener-url-deploy-notify",
            "alarm_threshold": 3, "alarm_period": 180 },
  "auth": { "function": "urlshortener-auth", "alias": "live",
            "codedeploy_app": "urlshortener-auth", "codedeploy_group": "urlshortener-auth",
            "errors_alarm_mode": "alias" }
}
```

## 권한은 "두 역할"로 나뉜다

| 역할 | 누가 쓰나 | 필요 권한 | 관리 위치 |
|---|---|---|---|
| CI 배포 역할 | GitHub OIDC assume → deploy.mjs | `lambda:UpdateFunctionCode/PublishVersion/GetAlias`, `cloudwatch:PutMetricAlarm`, `codedeploy:CreateDeployment/GetDeployment/GetDeploymentConfig`, `iam:PassRole`, `s3:PutObject` | 코드 레포 OIDC 역할(이 레포 밖) |
| 함수 실행 역할 | Lambda 런타임 → 핸들러 PutMetricData | `cloudwatch:PutMetricData`(네임스페이스 `UrlShortener/App` 한정) | **이 레포 `modules/lambda`**(`metrics_namespace`로 부여) |

- CI 배포 역할엔 `lambda:UpdateAlias`를 주지 않는다(alias 전환은 CodeDeploy 서비스 역할이 수행).
- 함수 실행 역할의 PutMetricData는 `modules/lambda`가 `metrics_namespace` 설정 시 자동 부여한다.

## 전략 요약

- **url**: Canary 10%/30분. 롤백 기준은 커스텀 지표(`UrlShortener/App HandlerErrors`,
  ExecutedVersion=신버전) 알람. CI가 배포 직전 PutMetricAlarm으로 신버전 갱신. URL API 5xx는 상시 SNS 알람.
- **auth**: AllAtOnce. 롤백 기준은 커스텀 지표(alias 차원) 정적 알람. auth API 5xx는 상시 SNS 알람.
- CI는 두 함수 모두 publish → create-deployment 트리거만 하고 블로킹하지 않는다.
