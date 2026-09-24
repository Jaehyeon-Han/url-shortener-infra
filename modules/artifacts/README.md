# artifacts 모듈

Lambda 배포 아티팩트(zip)를 보관하는 S3 버킷을 만드는 모듈이다.

CI/CD가 빌드한 함수 zip을 이 버킷에 업로드하고, Lambda 함수는 이 버킷을 코드 소스(`s3_bucket`)로 참조한다.

## 특징

- 버킷명은 `<name>-artifacts`로 만든다.
- 버저닝을 활성화한다. 코드 버전 추적/롤백과 `s3_object_version` 고정에 사용한다.
- 퍼블릭 접근을 전면 차단한다.
- 저장 데이터를 SSE-S3(AES256)로 기본 암호화한다.

## Inputs

| 이름 | 설명 | 타입 | 필수 |
|---|---|---|---|
| `name` | 리소스 이름 접두사. 버킷명은 `<name>-artifacts`가 된다. | `string` | 예 |

## Outputs

| 이름 | 설명 |
|---|---|
| `bucket_id` | 아티팩트 버킷 이름. Lambda 모듈의 `artifact_bucket` 입력으로 사용한다. |
| `bucket_arn` | 아티팩트 버킷 ARN. IAM 정책의 대상 리소스로 사용한다. |
