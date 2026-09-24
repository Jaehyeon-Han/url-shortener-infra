# Terraform 컨벤션

## 모듈 구조

- 재사용 리소스는 `modules/<name>/` 아래에 둔다.
- 각 모듈은 다음 파일로 구성한다.
  - `main.tf` — 리소스 정의
  - `variables.tf` — 입력 변수
  - `outputs.tf` — 출력값
  - `README.md` — 목적/Inputs/Outputs 요약(한국어)
- 리소스 이름 접두사는 `var.name`으로 주입받아 `${var.name}-*` 형태로 만든다.

## 버전 고정

- `required_version >= 1.10.0`을 유지한다.
- AWS provider는 `~> 6.0`으로 고정한다. 임의로 상한을 올리지 않는다.

## 스택 분리

이 프로젝트는 독립된 두 스택으로 나뉘며, 각각 별도 state를 가진다.

- `bootstrap/` — state 저장용 S3 버킷을 만든다. **로컬 state**로 최초 1회만 apply한다.
- 루트 스택 — 실제 서비스 인프라. **S3 원격 backend**를 사용한다.

## State 규칙

- 루트 스택은 S3 backend + `use_lockfile`(S3 네이티브 잠금)을 사용한다. DynamoDB 잠금 테이블은 쓰지 않는다.
- backend 버킷명에는 account_id가 포함되므로 **코드에 하드코딩하지 않는다**.
  `terraform init -backend-config=<파일>`로 주입한다.
- state 파일(`*.tfstate`)은 절대 커밋하지 않는다.

## 안전 설정 유지

- bootstrap의 state 버킷은 `prevent_destroy = true`를 유지한다.
- Cognito User Pool은 `deletion_protection`을 유지한다(운영 기본 true).
- 위 보호 설정을 해제하는 변경은 사용자 확인 후에만 수행한다.

## 코드 품질

- 코드 변경 후 `terraform fmt`와 `terraform validate`를 실행한다.

## 알려진 TODO

- Cognito 이메일 발송이 `COGNITO_DEFAULT`(일 50건 한도)다. 운영 전 SES로 교체한다.
