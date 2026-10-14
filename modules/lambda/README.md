# lambda 모듈

재사용 가능한 Node.js(mjs) 기반 Lambda 함수 모듈이다. 함수명만 다르게 주입해 인증/단축/리다이렉트 등 여러 함수를 같은 방식으로 만든다.

## 구성 리소스

- IAM 실행 역할(`<name>-role`)과 assume role 정책
- 기본 CloudWatch Logs 권한(인라인 정책 `<name>-logs`, `CreateLogStream`/`PutLogEvents`)
- (선택) 호출 측이 넘긴 함수별 인라인 정책(`<name>-inline`)
- CloudWatch 로그 그룹(`/aws/lambda/<name>`, 보존 기간 지정)
- 플레이스홀더 zip 업로드(`aws_s3_object`)
- Lambda 함수(`aws_lambda_function`)
- (선택) 이동 가능한 Alias(`aws_lambda_alias`, `enable_alias=true`일 때)

## Alias 기반 트래픽 전환 (enable_alias)

`enable_alias=true`면 이동 가능한 Alias(`alias_name`, 기본 `live`)를 만든다.
API Gateway는 함수가 아니라 이 Alias를 호출하므로(호출부가 `integration_invoke_arn`을
통합 URI로, `qualifier`를 권한 qualifier로 넘긴다), CI/CodeDeploy가 Alias의 트래픽을
신규 버전으로 옮겨 Canary/AllAtOnce 전환을 수행할 수 있다.

- **최초 상태**: Terraform이 함수를 `publish`해 최초 숫자 버전을 만들고, Alias가 그 버전을
  가리키게 한다. CodeDeploy는 `$LATEST`로 트래픽 전환을 못 하므로 Alias는 반드시 숫자 버전을
  가리켜야 한다. 코드 소스(`s3_key` 등)는 `ignore_changes`라 Terraform이 만드는 버전은 사실상
  최초 1개뿐이고, 이후 버전 publish는 CI(`update-function-code --publish`)가 담당한다.
- **전환**: 이후 CI가 publish한 버전으로 CodeDeploy가 Alias를 옮긴다
  (Canary/AllAtOnce는 배포 그룹의 `deployment_config_name`이 결정).
- **drift 회피**: Alias는 `lifecycle { ignore_changes = [function_version] }`를 적용해,
  운영 중 전환 결과를 `terraform apply`가 되돌리지 않는다.

`enable_alias=false`(기본)면 Alias를 만들지 않고 함수 `invoke_arn`을 그대로 노출한다(하위 호환).

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
| `runtime` | Lambda 런타임. | `string` | `nodejs24.x` | 아니오 |
| `memory_size` | 메모리(MB). | `number` | `128` | 아니오 |
| `timeout` | 타임아웃(초). | `number` | `10` | 아니오 |
| `environment` | 환경 변수 맵. | `map(string)` | `{}` | 아니오 |
| `s3_object_version` | 참조할 S3 객체 버전 ID. `null`이면 최신 버전 참조(권장). 버저닝 버킷에서 특정 버전 고정/롤백 시에만 명시. | `string` | `null` | 아니오 |
| `inline_policy_json` | 실행 역할에 부착할 인라인 정책 JSON. | `string` | `null` | 아니오 |
| `log_retention_days` | 로그 보존 기간(일). | `number` | `14` | 아니오 |
| `enable_alias` | 이동 가능한 Alias를 만들지 여부. 트래픽 전환 배포(Canary/AllAtOnce)에 필요. | `bool` | `false` | 아니오 |
| `alias_name` | 생성할 Alias 이름. `enable_alias=true`일 때만 의미. | `string` | `live` | 아니오 |
| `metrics_namespace` | 설정 시 실행 역할에 해당 네임스페이스 한정 `cloudwatch:PutMetricData` 권한 부여. 핸들러가 커스텀 에러 지표를 발행할 때 사용. | `string` | `null` | 아니오 |

## Outputs

| 이름 | 설명 |
|---|---|
| `function_name` | 함수 이름. CI의 `update-function-code` 대상이다. |
| `function_arn` | 함수 ARN. |
| `invoke_arn` | 함수 호출 ARN. |
| `alias_name` | Alias 이름. `enable_alias=false`면 `null`. |
| `alias_arn` | Alias ARN(함수:alias). `enable_alias=false`면 `null`. |
| `alias_invoke_arn` | Alias를 가리키는 invoke ARN. `enable_alias=false`면 `null`. |
| `integration_invoke_arn` | API Gateway 통합용 invoke ARN. `enable_alias`이면 Alias를, 아니면 함수를 가리킨다. |
| `qualifier` | Lambda 권한 qualifier. `enable_alias`이면 alias 이름, 아니면 `null`. |
| `role_arn` | 실행 역할 ARN. |
