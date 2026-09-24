# URL Shortener Serverless AWS - 프로젝트 구조 문서

Terraform으로 AWS 기반 URL 단축 서비스 인프라를 관리하는 프로젝트다. 이 문서는 전체 구조와 실행 절차를 정리하여 이후 작업에 참고하기 위한 것이다.

## 개요

| 항목 | 값 |
|---|---|
| IaC 도구 | Terraform (`>= 1.10.0`) |
| Provider | `hashicorp/aws` (`~> 6.0`) |
| 리전 | `ap-northeast-2` (Seoul) |
| 프로젝트 접두사 | `urlshortener` |
| 현재 State 저장 방식 | S3 원격 backend (bootstrap 버킷). 잠금은 S3 네이티브 잠금(`use_lockfile`) |

## 디렉토리 구조

```
UrlShortener_Serverless_AWS/
├── README.md                 # 프로젝트 개요 (구성 요소 목록)
├── PROJECT_STRUCTURE.md      # (이 문서) 전체 구조/실행 가이드
├── terraform.tf              # Terraform/provider 버전 요구사항 + S3 backend 설정
├── providers.tf              # AWS provider 설정 (region)
├── variables.tf              # 루트 변수 (aws_region, name)
├── main.tf                   # 루트 모듈 - cognito 모듈 호출
├── backend.hcl.example       # S3 backend 설정 템플릿
├── .gitignore                # Terraform 로컬 산출물 및 민감 설정 파일 제외
│
├── bootstrap/                # [초기 1회] Terraform state 저장용 S3 버킷 생성
│   └── main.tf               # S3 버킷 + 버전관리 + 암호화 + public access block
│
└── modules/
    └── cognito/              # 사용자 인증용 Cognito User Pool + App Client
        ├── main.tf
        ├── variables.tf
        ├── outputs.tf
        └── README.md
```

## 스택 구성

이 프로젝트는 독립적으로 관리되는 두 개의 Terraform 스택으로 나뉜다.

### 1. bootstrap 스택 (`bootstrap/`)

Terraform state를 저장하기 위한 S3 버킷을 생성한다. 로컬 state로 **최초 1회만** apply한다.

생성 리소스:
- `aws_s3_bucket.tfstate` — 버킷명: `urlshortener-tfstate-<account_id>`
  - `prevent_destroy = true` (실수로 삭제 방지)
- `aws_s3_bucket_versioning` — 버전 관리 활성화
- `aws_s3_bucket_server_side_encryption_configuration` — AES256 암호화
- `aws_s3_bucket_public_access_block` — 모든 public access 차단

변수:
| 이름 | 기본값 | 설명 |
|---|---|---|
| `region` | `ap-northeast-2` | 리전 |
| `project` | `urlshortener` | 프로젝트 접두사 (버킷명/태그에 사용) |

출력:
| 이름 | 설명 |
|---|---|
| `tfstate_bucket` | 루트 스택 backend 설정에 사용할 버킷명 |

기본 태그: `Project = urlshortener`, `ManagedBy = terraform`

### 2. 루트 스택 (프로젝트 루트)

실제 서비스 인프라를 정의한다. 현재는 cognito 모듈만 호출한다.

- `terraform.tf` — `required_version >= 1.10.0`, aws provider `~> 6.0`
- `providers.tf` — `region = var.aws_region`
- `variables.tf`:
  | 이름 | 기본값 | 설명 |
  |---|---|---|
  | `aws_region` | (필수) | AWS 리전 |
  | `name` | `urlshortener` | 리소스 이름 접두사 |
- `main.tf` — `module "cognito"` 호출, `name = var.name` 전달

> 참고: 루트 스택은 S3 원격 backend를 사용한다. 버킷명은 account_id를 포함하므로 코드에 하드코딩하지 않고 `terraform init -backend-config=...`로 주입한다. 자세한 절차는 아래 "실행 절차"를 참고한다.

## 모듈: cognito

URL 단축 서비스의 인증용 Cognito User Pool과 App Client(public, secret 없음)를 생성한다.

주요 설정:
- 로그인 ID는 email (`username_attributes = ["email"]`), 대소문자 구분 없음
- 이메일 자동 인증 (`auto_verified_attributes = ["email"]`), 인증 코드 방식
- 필수 스키마 속성: `name`(2~30자), `email`(1~100자) — **생성 후 변경 불가** (변경 시 User Pool 재생성)
- 비밀번호 정책: 최소 8자, 소문자/숫자/기호 필수, 대문자 불필요
- 계정 복구: verified_email
- MFA: OFF
- 이메일 발송: `COGNITO_DEFAULT` (일 50건 한도) — **실서비스 전 SES로 교체 필요**
- App Client: secret 없음, `ALLOW_REFRESH_TOKEN_AUTH` + `ALLOW_USER_PASSWORD_AUTH`

변수:
| 이름 | 기본값 | 설명 |
|---|---|---|
| `name` | (필수) | 리소스 이름 접두사 |
| `deletion_protection` | `true` | User Pool 삭제 방지. 운영에서는 true |
| `access_token_validity_hours` | `1` | Access 토큰 유효기간(시간) |
| `id_token_validity_hours` | `1` | ID 토큰 유효기간(시간) |
| `refresh_token_validity_days` | `30` | Refresh 토큰 유효기간(일) |

출력:
| 이름 | 설명 |
|---|---|
| `user_pool_id` | Cognito User Pool ID |
| `user_pool_arn` | Cognito User Pool ARN |
| `user_pool_client_id` | App Client ID (API Gateway JWT Authorizer의 audience) |
| `issuer_url` | 토큰 발급자(iss) URL (API Gateway JWT Authorizer의 issuer) |

## 실행 절차

### 사전 요구사항
- Terraform `>= 1.10.0`
- AWS 자격 증명 구성 (`aws configure` 또는 환경변수)

### 1단계: bootstrap (최초 1회)

```bash
cd bootstrap
terraform init
terraform apply
# 출력된 tfstate_bucket 값을 기록해 둔다
```

### 2단계: 루트 스택 배포

루트 스택은 State를 bootstrap이 만든 S3 버킷에 저장한다. 버킷명에는 account_id가 포함되므로
`terraform.tf`에 하드코딩하지 않고 `-backend-config`로 주입한다.

```bash
# 프로젝트 루트에서
# (1) backend 설정 파일 준비 - 최초 1회 (템플릿을 복사해 bucket 값 입력)
#     bucket 값은 bootstrap 출력값을 사용한다:
#       cd bootstrap && terraform output -raw tfstate_bucket

# (2) backend 설정과 함께 초기화
terraform init -backend-config=<로컬 backend 설정 파일>

terraform plan
terraform apply
```

버킷명 등 환경별 backend 값은 `backend.hcl.example` 템플릿을 참고해 로컬 설정 파일로 관리한다. 실제 값이 담긴 설정 파일은 저장소에 커밋하지 않는다.

리전 등 변수 값은 별도 로컬 변수 파일에서 주입하며, 값은 이 문서에 기록하지 않는다.

### 삭제

```bash
# 루트 스택 먼저
terraform destroy

# bootstrap의 S3 버킷은 prevent_destroy = true 이므로
# 삭제하려면 해당 lifecycle 설정을 먼저 제거해야 한다.
```

## 알려진 이슈 / TODO

- **~~루트 스택 backend 미구성~~ (완료)**: 루트 스택이 S3 원격 backend를 사용하도록 구성했다. 버킷명은 `-backend-config`로 주입하며, 잠금은 S3 네이티브 잠금(`use_lockfile`)을 사용한다. 기존 로컬 state가 남아 있다면 `-migrate-state` 플래그로 원격 backend에 이전한다.
- **이메일 발송**: `COGNITO_DEFAULT` 사용 중. 운영 전 SES 연동 필요.
- **미구현 구성 요소**: README상 URL 단축기 서비스이나 현재 Cognito(인증)만 존재. Lambda, API Gateway, DynamoDB 등 핵심 기능 모듈은 아직 없음.

## 참고

- 로컬 변수 파일 및 backend 설정 파일 등 민감 정보가 담긴 파일은 Git에 커밋되지 않는다(`.gitignore`). 다른 환경에서 실행 시 리전 등 값을 별도로 지정해야 한다.
- bootstrap과 루트 스택은 각각 독립된 state를 가지므로 별도 디렉토리에서 init/apply 해야 한다.
