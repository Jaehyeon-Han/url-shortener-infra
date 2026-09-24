# 배포 워크플로 및 안전 규칙

## 배포 순서

1. **bootstrap (최초 1회)** — `bootstrap/`에서 로컬 state로 실행한다.
   ```bash
   cd bootstrap
   terraform init
   terraform apply
   # 출력된 tfstate_bucket 값을 기록한다
   ```
2. **루트 스택** — 기록한 버킷명을 backend로 주입해 초기화한 뒤 배포한다.
   ```bash
   terraform init -backend-config=<로컬 backend 설정 파일>
   terraform plan
   terraform apply
   ```
- backend 값은 `backend.hcl.example` 템플릿을 복사해 로컬 파일로 관리한다.
- 리전 등 변수 값은 별도 로컬 변수 파일로 주입하며, 문서/코드에 실제 값을 기록하지 않는다.

## 커밋 / 민감 파일 규칙

다음 파일은 민감 정보를 포함하므로 **커밋하지 않는다**(`.gitignore`로 제외됨).

- `backend.hcl` (버킷명에 account_id 포함) — 예시 템플릿 `backend.hcl.example`만 커밋한다.
- `*.tfvars`
- `*.tfstate`, `*.tfstate.*`
- `.terraform/`, `crash.log`, `override.tf`, `override.tf.json`

커밋 전 위 파일이 스테이징되지 않았는지 확인한다. 커밋은 사용자가 명시적으로 요청할 때만 만든다.

## 파괴적 작업 사전 확인

다음 작업은 되돌리기 어렵거나 운영에 영향을 주므로 **실행 전 사용자에게 확인**한다.

- `terraform destroy`
- `terraform init -migrate-state`
- `prevent_destroy` / `deletion_protection` 해제
- S3 버킷/state 삭제

## destroy 순서

- 루트 스택을 먼저 `terraform destroy`한다.
- bootstrap의 S3 버킷은 `prevent_destroy = true`이므로, 삭제하려면 해당 lifecycle 설정을 먼저 제거해야 한다.
