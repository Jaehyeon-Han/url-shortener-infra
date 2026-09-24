# lambda 모듈

재사용 가능한 Node.js(mjs) 기반 Lambda 함수 모듈이다. 함수명만 다르게 주입해 인증/단축/리다이렉트 등 여러 함수를 같은 방식으로 만든다.

## 구성 리소스

- IAM 실행 역할(`<name>-role`)과 assume role 정책
- 기본 CloudWatch Logs 권한(인라인 정책 `<name>-logs`, `CreateLogStream`/`PutLogEvents`)
- (선택) 호출 측이 넘긴 함수별 인라인 정책(`<name>-inline`)
- CloudWatch 로그 그룹(`/aws/lambda/<name>`, 보존 기간 지정)
- 플레이스홀더 zip 업로드(`aws_s3_object`)
- Lambda 함수(`aws_lambda_function`)

## 코드 배포 방식

코드 소스는 아티팩트 S3 버킷을 참조한다(`s3_bucket`/`s3_key`).

- **최초 생성**: 모듈이 최소 핸들러가 담긴 플레이스홀더 zip을 `s3_key`로 업로드해 함수 생성을 보장한다. 플레이스홀더는 501(미구현)을 반환한다. 플레이스홀더는 `handler` 값에 맞춰 **동적으로 생성**된다. 즉 `handler = "handlers/auth.handler"`면 zip 내부에 `handlers/auth.mjs`가 만들어지고 그 파일이 `handler`를 export하므로, 함수마다 핸들러 경로가 달라도 최초 상태에서 항상 호출 가능하다.
- **이후 갱신**: 별도 리포지토리의 CI/CD가 같은 `s3_key`에 실제 코드를 올리고 `update-function-code`로 함수를 갱신한다.
- **Terraform 독립성**: 함수는 `lifecycle { ignore_changes = [s3_key, s3_object_version, source_code_hash] }`를 **고정**으로 적용한다. 따라서 CI가 코드를 갱신해도 이후 `terraform apply`가 코드를 되돌리지 않는다. 플레이스홀더 객체도 `source`/`etag`/`version_id` 변경을 무시한다.

## IAM 정책 주입

함수별 세밀 권한은 호출 측이 `aws_iam_policy_document`로 만들어 `inline_policy_json`으로 넘긴다. 모듈이 이를 실행 역할에 인라인으로 부착한다. CloudWatch Logs 권한은 모듈이 항상 기본 부여한다. 로그 그룹은 모듈이 `aws_cloudwatch_log_group`으로 직접 생성하므로 `CreateLogGroup`은 부여하지 않고 `CreateLogStream`/`PutLogEvents`만 준다.

## Inputs

| 이름 | 설명 | 타입 | 기본값 | 필수 |
|---|---|---|---|---|
| `name` | 함수 이름. 리소스명·로그 그룹 경로에 사용한다. | `string` | - | 예 |
| `handler` | 핸들러 진입점. `<zip 내부 경로>.<export명>` 형식 (예: `handlers/auth.handler`). | `string` | - | 예 |
| `artifact_bucket` | 코드 zip이 저장된 아티팩트 버킷 이름. | `string` | - | 예 |
| `s3_key` | 아티팩트 버킷 내 코드 zip 키 (예: `auth/function.zip`). | `string` | - | 예 |
| `runtime` | Lambda 런타임. | `string` | `nodejs20.x` | 아니오 |
| `memory_size` | 메모리(MB). | `number` | `128` | 아니오 |
| `timeout` | 타임아웃(초). | `number` | `10` | 아니오 |
| `environment` | 환경 변수 맵. | `map(string)` | `{}` | 아니오 |
| `s3_object_version` | 참조할 S3 객체 버전 ID. `null`이면 최신 버전 참조(권장). 버저닝 버킷에서 특정 버전 고정/롤백 시에만 명시. | `string` | `null` | 아니오 |
| `inline_policy_json` | 실행 역할에 부착할 인라인 정책 JSON. | `string` | `null` | 아니오 |
| `log_retention_days` | 로그 보존 기간(일). | `number` | `14` | 아니오 |

## Outputs

| 이름 | 설명 |
|---|---|
| `function_name` | 함수 이름. CI의 `update-function-code` 대상이다. |
| `function_arn` | 함수 ARN. |
| `invoke_arn` | 호출 ARN. API Gateway 통합에서 사용한다. |
| `role_arn` | 실행 역할 ARN. |
