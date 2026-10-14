# 프로젝트 개요

AWS 기반 서버리스 URL 단축 서비스의 인프라를 Terraform으로 관리하는 프로젝트다.

## 기술 스택

| 항목 | 값 |
|---|---|
| IaC 도구 | Terraform (`>= 1.10.0`) |
| Provider | `hashicorp/aws` (`~> 6.0`) |
| 리전 | `ap-northeast-2` (Seoul) |
| 프로젝트 접두사 | `urlshortener` |
| State 저장 | S3 원격 backend, 잠금은 S3 네이티브 잠금(`use_lockfile`) |

## 네이밍 규칙

- 리소스 이름은 접두사를 붙인다. 모듈 내부에서는 `${var.name}-*` 형식을 사용한다.
  - 예: `${var.name}-users`, `${var.name}-client`
- 루트/bootstrap의 이름 접두사 변수 기본값은 `urlshortener`다.
- 기본 태그: `Project = urlshortener`, `ManagedBy = terraform`.

## 현재 구현 상태

- 구현됨: `bootstrap`(state용 S3 버킷), `modules/cognito`(사용자 인증), `modules/artifacts`(Lambda 코드 zip 보관 버킷), `modules/lambda`(재사용 Node.js Lambda 모듈, 루트에 `auth`/`url` 함수 배선, `enable_alias`로 `live` Alias 지원), `modules/certificate`(루트 도메인 TLS 인증서 발급 + `auth.<domain>`/`short.<domain>` SAN + Porkbun DNS 검증 자동화), `modules/apigateway`(HTTP API v2 재사용 모듈 — auth API(`auth.<domain>`, 공개)와 URL API(`short.<domain>`, 공개 리다이렉트 + Cognito JWT 보호 라우트) 배선, Alias 호출을 위한 `lambda_qualifier` 지원, Porkbun CNAME), `modules/dynamodb`(URL/통계 단일 테이블, PK/SK + GSI1/GSI2, 온디맨드, PITR 활성), `modules/codedeploy`(URL Lambda의 CodeDeploy Canary 배포 — 앱/배포그룹/서비스역할 + Lambda Errors·API Gateway 5xx 알람 자동 롤백 + SNS 통지).
- 배포 전략: 두 함수 모두 `live` Alias로 호출되며 전환은 CodeDeploy로 통일한다. `url`은 CodeDeploy Canary(10%/30분), `auth`는 CodeDeploy AllAtOnce다. 핸들러가 try/catch로 500을 정상 리턴해 `AWS/Lambda Errors`가 0이 되므로, 자동 롤백 기준은 핸들러가 `PutMetricData`로 올리는 커스텀 지표(`UrlShortener/App` `HandlerErrors`)다. `url`은 Canary 신버전만 가드하도록 이 지표를 ExecutedVersion(신버전) 차원으로 좁혀 CI가 배포 직전 갱신하고, `auth`는 alias 차원 정적 알람을 쓴다. 커스텀 메트릭 발행 권한은 함수 실행 역할의 `cloudwatch:PutMetricData`(`modules/lambda`의 `metrics_namespace`)로 부여한다. API Gateway 5xx는 버전 차원이 없어 롤백 기준에서 빼고 상시 SNS 알람으로 둔다. 버전 publish·배포 트리거·url 알람 갱신은 CI 담당이다.
- 데이터 저장소: URL/통계는 `modules/dynamodb` 단일 테이블(싱글 테이블 디자인)을 채택한다. Aurora Serverless는 쓰지 않는다.
- URL Lambda(`url`): 단축/목록/통계/비활성/리다이렉트 핸들러를 `modules/lambda`로 배선했다. `modules/dynamodb`의 `table_name`을 `TABLE_NAME` env로, `table_arn`(+`index/*`)을 IAM 대상으로 주입한다. 코드 소스는 `url/function.zip` 키이며 handler는 `src/handlers/urls.handler`다. 앞단 API는 `short.<domain>` 커스텀 도메인으로, 공개 `GET /{code}`(리다이렉트)와 보호 `/urls*`(Cognito JWT authorizer)로 구성한다.
- 미구현: 핸들러 실제 코드는 별도 레포 CI가 `update-function-code`로 배포한다. 악성 URL 상태 전이(PENDING/BLOCKED) 워크플로는 테이블/GSI2만 준비됐고 로직은 미구현이다.

## 문서 규칙

- 문서와 주석은 한국어 서술체(`~다`)로 작성한다.
- 각 모듈의 상세(목적/Inputs/Outputs)는 해당 `modules/<name>/README.md`를 참고한다.
- 배포/삭제 절차와 안전 규칙은 `.kiro/steering/workflow.md`, 컨벤션은 `.kiro/steering/terraform-conventions.md`를 참고한다.
