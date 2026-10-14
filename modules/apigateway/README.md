# apigateway 모듈

## 목적

Lambda 앞단에 두는 HTTP API(v2)를 구성한다.
외부 HTTP 요청을 payload v2 형식으로 Lambda에 프록시하고, 명시적으로 등록한 라우트만 노출한다.
커스텀 도메인(예: `auth.jhan.cc`, `short.jhan.cc`)과 TLS를 연결하고, 해당 도메인을 API Gateway로 향하게 하는 CNAME을 Porkbun DNS에 생성한다.

이 모듈은 재사용을 전제로 하며, `route_keys`/`protected_route_keys`/CORS/도메인 값을 주입해 여러 API에 쓴다.
현재 루트에서 auth API(공개 전용)와 URL API(공개 리다이렉트 + JWT 보호 라우트)를 모두 이 모듈로 배선한다.

## 구성 리소스

- `aws_apigatewayv2_api` — HTTP API 본체. CORS를 설정한다.
- `aws_apigatewayv2_integration` — Lambda AWS_PROXY 통합(payload v2).
- `aws_apigatewayv2_route` (공개) — `route_keys`의 각 항목마다 하나씩 생성하는 명시적 라우트.
- `aws_apigatewayv2_authorizer` (선택) — `jwt_issuer`가 주어질 때만 생성하는 Cognito JWT authorizer.
- `aws_apigatewayv2_route.protected` (보호) — `protected_route_keys`의 각 항목에 JWT authorizer를 붙인 라우트.
- `aws_lambda_permission` — API Gateway가 Lambda를 호출하도록 하는 리소스 기반 권한.
- `aws_cloudwatch_log_group` + `aws_apigatewayv2_stage` — `$default` 스테이지와 JSON 액세스 로그.
- `aws_apigatewayv2_domain_name` + `aws_apigatewayv2_api_mapping` — 커스텀 도메인과 스테이지 매핑.
- `porkbun_dns_record` — 커스텀 도메인을 API Gateway regional target으로 가리키는 CNAME.

## 동작 방식

1. HTTP API와 Lambda 통합을 만들고, `route_keys`의 각 `"METHOD /path"`를 통합에 연결한다.
   목록에 없는 경로는 API Gateway가 404를 반환한다.
2. `aws_lambda_permission`으로 API Gateway의 호출을 허용한다. 이 권한이 없으면 호출이 403으로 거부된다.
3. `$default` 스테이지를 auto_deploy로 두고, 요청 단위 액세스 로그를 JSON으로 CloudWatch에 남긴다.
4. 커스텀 도메인을 만들어 인증서를 연결하고 스테이지에 매핑한다.
5. 커스텀 도메인이 가리키는 regional target 도메인으로 Porkbun에 CNAME을 만든다.
   - Porkbun의 `subdomain`은 루트 도메인을 제외한 부분만 요구하므로, `domain_name`에서 `.<porkbun_domain>`을 제거해 넘긴다 (예: `auth.jhan.cc` → `auth`).

## 공개 라우트 vs 보호 라우트 (JWT authorizer)

라우트는 두 종류로 나뉜다.

- **공개 라우트(`route_keys`)**: authorizer 없이 그대로 노출한다. auth API처럼 전부 공개면 이 변수만 쓰면 된다(기본값은 auth 6개 라우트).
- **보호 라우트(`protected_route_keys`)**: Cognito JWT authorizer로 보호한다. `jwt_issuer`가 설정되어야 하며, 각 라우트는 `Authorization` 헤더의 JWT를 검증한 뒤 Lambda로 전달한다. 핸들러는 `requestContext.authorizer.jwt.claims.sub`로 소유자를 식별한다.

`jwt_issuer`가 `null`(기본값)이면 authorizer와 보호 라우트를 **생성하지 않는다**. 따라서 auth 배선처럼 공개 전용으로 쓸 때는 기존과 동일하게 동작한다(하위호환).

- `jwt_issuer`는 스킴을 포함한 전체 URL이어야 한다. Cognito는 `"https://${module.cognito.issuer_url}"` 형태로 넘긴다(`issuer_url`은 스킴이 없으므로 `https://`를 접두).
- `jwt_audiences`에는 Cognito App Client ID를 넣는다.

## 주의

- `certificate_arn`이 가리키는 인증서가 `domain_name`을 커버해야 한다(SAN 포함). 그렇지 않으면 TLS 검증이 실패한다.
- `porkbun` provider는 서드파티(비공식)이며, `plan`/`apply`가 **실제 Porkbun DNS를 변경**한다.
  provider 설정(자격증명)은 루트에서 정의해 `providers = { porkbun = porkbun }`로 이 모듈에 전달한다.
- 커스텀 도메인은 CNAME 전파 전까지 조회되지 않는다. 전파 전에는 `api_endpoint`(execute-api URL)로 접근한다.
- **Lambda Alias 연동**: Alias를 통해 호출하려면 호출부가 `lambda_invoke_arn`에
  **alias-qualified invoke ARN**(lambda 모듈의 `integration_invoke_arn`)을 넘기고,
  `lambda_qualifier`에 alias 이름(lambda 모듈의 `qualifier`)을 넘겨야 한다.
  둘 중 하나만 alias를 가리키면 호출 권한이 불일치해 403이 발생한다.

## Inputs

| 이름 | 설명 | 타입 | 기본값 | 필수 |
|---|---|---|---|---|
| `name` | 리소스 이름 접두사 (예: `urlshortener-auth`). | `string` | — | 예 |
| `lambda_invoke_arn` | 통합할 Lambda의 invoke ARN. lambda 모듈의 `invoke_arn`. | `string` | — | 예 |
| `lambda_function_name` | 호출 권한을 부여할 Lambda 함수 이름. lambda 모듈의 `function_name`. | `string` | — | 예 |
| `lambda_qualifier` | 호출 권한을 한정할 qualifier(alias 이름/버전). Alias 호출 시 lambda 모듈의 `qualifier`를 넘긴다. `null`이면 비한정($LATEST). | `string` | `null` | 아니오 |
| `route_keys` | 등록할 공개 라우트 키 목록 (`"METHOD /path"`). authorizer 없이 노출. | `list(string)` | auth 6개 라우트 | 아니오 |
| `protected_route_keys` | JWT authorizer를 적용할 보호 라우트 키 목록. `jwt_issuer` 필요. | `list(string)` | `[]` | 아니오 |
| `jwt_issuer` | JWT authorizer issuer URL(https:// 포함). `null`이면 authorizer 미생성. | `string` | `null` | 아니오 |
| `jwt_audiences` | JWT authorizer 허용 audience 목록(Cognito App Client ID). | `list(string)` | `[]` | 아니오 |
| `cors_allow_origins` | CORS 허용 Origin 목록. | `list(string)` | `["*"]` | 아니오 |
| `cors_allow_methods` | CORS 허용 메서드 목록. | `list(string)` | `["POST","OPTIONS"]` | 아니오 |
| `cors_allow_headers` | CORS 허용 헤더 목록. | `list(string)` | `["content-type","authorization"]` | 아니오 |
| `log_retention_days` | 액세스 로그 보존 기간(일). | `number` | `14` | 아니오 |
| `domain_name` | 커스텀 도메인 전체 이름 (예: `auth.jhan.cc`). | `string` | — | 예 |
| `certificate_arn` | 커스텀 도메인에 연결할 검증 완료 ACM 인증서 ARN. | `string` | — | 예 |
| `porkbun_domain` | Porkbun에서 관리하는 루트 도메인 (예: `jhan.cc`). | `string` | — | 예 |

## Outputs

| 이름 | 설명 |
|---|---|
| `api_id` | HTTP API ID. |
| `api_endpoint` | 기본 실행 엔드포인트(execute-api URL). |
| `execution_arn` | API 실행 ARN. |
| `stage_invoke_url` | `$default` 스테이지 호출 URL. |
| `custom_domain_url` | 커스텀 도메인 호출 URL (예: `https://auth.jhan.cc`). |
| `custom_domain_target` | 커스텀 도메인이 가리키는 regional target 도메인(CNAME 대상값). |
