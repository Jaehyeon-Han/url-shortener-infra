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


## CI/CD (GitHub Actions)

인프라(Terraform) 레포의 루트 스택을 GitHub Actions로 검증/배포한다. 두 워크플로로 구성된다.

- `.github/workflows/plan.yml` — PR(→main)에서 `fmt -check` / `validate` / `plan`을 돌리고,
  plan 결과를 PR 코멘트로 작성/갱신한다(upsert). 읽기 전용 **plan 역할**을 OIDC로 assume한다.
- `.github/workflows/apply.yml` — main 머지(push) 시 `apply`를 돌린다. `production` 환경의
  **수동 승인 게이트**를 통과해야 실행된다. **apply 역할**을 OIDC로 assume한다.

### 인증(OIDC)

- 장기 액세스 키를 쓰지 않고 GitHub OIDC로 IAM 역할을 assume한다.
- OIDC provider는 계정당 하나만 존재하므로 `bootstrap/oidc.tf`에서 **신규 생성하지 않고
  `data`로 참조**한다. plan/apply 역할만 bootstrap이 생성한다.
- 역할 신뢰 정책의 `sub`로 사용처를 좁힌다.
  - plan 역할: `repo:<owner>/<repo>:pull_request` (ReadOnlyAccess + state 버킷 R/W).
  - apply 역할: `repo:<owner>/<repo>:environment:production` (AdministratorAccess + state 버킷 R/W).
- 역할 생성: `bootstrap`을 로컬 state로 apply한 뒤, 출력에서 ARN을 얻는다.
  ```bash
  cd bootstrap
  terraform apply            # IAM 역할 생성(사용자 확인 후 실행)
  terraform output -raw ci_plan_role_arn   # GitHub Secret PLAN_ROLE_ARN
  terraform output -raw ci_apply_role_arn  # GitHub Secret APPLY_ROLE_ARN
  ```
  소유자/레포명이 기본값(`Jaehyeon-Han`/`url-shortener-infra`)과 다르면
  `github_owner`/`github_repo` 변수로 덮어쓴다.

### GitHub 저장소 설정(수동)

워크플로 YAML로 자동화되지 않는 설정은 레포 **Settings**에서 직접 한다.

**Secrets** (Settings → Secrets and variables → Actions → Secrets):

| 이름 | 값 |
|---|---|
| `PLAN_ROLE_ARN` | bootstrap 출력 `ci_plan_role_arn` |
| `APPLY_ROLE_ARN` | bootstrap 출력 `ci_apply_role_arn` |
| `BACKEND_BUCKET` | state 버킷명(bootstrap 출력 `tfstate_bucket`). `init -backend-config`로 주입된다 |
| `TF_VAR_domain_name` | 루트 도메인 |
| `TF_VAR_porkbun_api_key` | Porkbun API 키(`pk1_...`) |
| `TF_VAR_porkbun_secret_key` | Porkbun 시크릿 키(`sk1_...`) |
| `TF_VAR_deploy_notification_emails` | (선택) `["a@x.com","b@y.com"]` 형태의 JSON 문자열. 생략하면 빈 목록 |

**Variables** (Settings → Secrets and variables → Actions → Variables):

| 이름 | 값 |
|---|---|
| `AWS_REGION` | 리전(예: `ap-northeast-2`). OIDC assume와 `TF_VAR_aws_region`에 함께 쓰인다 |

**Environment**(Settings → Environments):

- `production` 환경을 만들고 **Required reviewers**에 승인자를 추가한다.
- 이 설정이 있어야 apply 잡이 "승인 대기(pending)"로 멈춘다. 지정 리뷰어가 Actions 실행
  화면의 **Review deployments**에서 승인해야 `apply`가 실행된다. 거부하면 잡이 실패한다.
- apply 역할 신뢰 정책이 `environment:production`으로 좁혀져 있어, 이 환경을 거치지 않은
  실행은 apply 역할을 assume할 수 없다.

### 민감값/보안 메모

- 실제 ARN·버킷명·도메인·Porkbun 키 등은 **문서/코드에 남기지 않고** GitHub Secrets/Variables로만 관리한다.
- `*.tfvars`를 만들지 않고 `TF_VAR_*` 환경변수로 주입한다.
- fork에서 온 PR에는 GitHub가 secrets를 노출하지 않으므로, plan은 **같은 레포 브랜치 PR**에서만
  정상 동작한다(의도된 동작).
- `porkbun` provider는 plan/apply가 실제 Porkbun DNS를 read/write한다. plan 단계에서도
  DNS read가 발생하므로 plan 역할은 AWS 읽기 전용이되 Porkbun 자격증명은 주입된다.


### 트러블슈팅(실전 메모)

파이프라인을 처음 세울 때 실제로 겪은 두 가지다.

**1) OIDC subject(`sub`)에 숫자 ID가 포함된다.**

- 증상: plan 잡에서 `Not authorized to perform sts:AssumeRoleWithWebIdentity`로 assume 실패.
- 원인: 레포 OIDC 설정이 subject claim을 immutable 숫자 ID 포함 형태로 커스터마이즈하면,
  실제 토큰 `sub`가 `repo:<owner>@<ownerId>/<repo>@<repoId>:pull_request`처럼 발급된다.
  신뢰 정책이 `repo:<owner>/<repo>:...`(ID 없음)로 돼 있으면 `StringEquals`가 불일치한다.
- 확인: PR 잡에서 OIDC 토큰을 디코드해 `sub`를 로그로 찍어 확인한다(일회성 디버그 스텝).
- 해결: `bootstrap/oidc.tf`의 `github_owner_id`/`github_repo_id` 변수에 실제 숫자 ID를 넣어
  신뢰 정책 `sub`를 토큰과 정확히 일치시킨다. 숫자 ID는 민감정보가 아니다(GitHub API로 조회 가능).
  신뢰 정책만 바뀌므로 `bootstrap` 재apply해도 역할 ARN은 그대로다(Secret 재설정 불필요).

**2) `list` 타입 변수는 빈 Secret이면 plan/apply가 깨진다.**

- 증상: `Error: Missing expression ... Expected the start of an expression, but found the end of the file`.
- 원인: `deploy_notification_emails`는 `list(string)`이라 `TF_VAR_*` 값이 HCL 표현식으로
  해석된다. Secret이 비어 빈 문자열이 주입되면 유효한 표현식이 아니라 파싱에 실패한다.
- 해결: 워크플로에서 `${{ secrets.TF_VAR_deploy_notification_emails || '[]' }}`로 빈 값일 때
  유효한 빈 리스트 `[]`를 주입한다. (plan.yml/apply.yml 모두 적용돼 있다.)
