# 인프라(Terraform) 레포의 GitHub Actions CI/CD가 AWS에 접근할 때 쓰는 OIDC 역할이다.
# bootstrap은 로컬 state로 1회 apply하므로, state 버킷과 함께 여기서 관리한다.
#
# 역할은 두 개로 나뉜다.
#   - plan 역할: PR에서 fmt/validate/plan을 돌린다. ReadOnlyAccess + state 버킷 R/W(잠금 파일).
#   - apply 역할: main 머지 후 apply를 돌린다. AdministratorAccess + state 버킷 R/W.
# 신뢰 정책의 sub를 각각 pull_request / environment:production으로 좁혀 오남용을 막는다.

variable "github_owner" {
  description = "GitHub 저장소 소유자(Organization 또는 사용자)."
  type        = string
  default     = "Jaehyeon-Han"
}

variable "github_repo" {
  description = "인프라(Terraform) 레포 이름."
  type        = string
  default     = "url-shortener-infra"
}

# 계정에 이미 존재하는 GitHub OIDC provider를 참조한다.
# OIDC provider는 계정당 하나만 존재할 수 있어 신규 생성하지 않고 data로 조회한다.
# url만 주면 account_id가 포함된 ARN은 자동으로 해석된다.
data "aws_iam_openid_connect_provider" "github" {
  url = "https://token.actions.githubusercontent.com"
}

# state 버킷(본체 + 객체)에 대한 읽기/쓰기 권한이다. plan/apply 두 역할이 공유한다.
# plan도 state를 읽고 S3 네이티브 잠금(.tflock) 파일을 생성/삭제하므로 쓰기가 필요하다.
data "aws_iam_policy_document" "tfstate_access" {
  statement {
    sid       = "StateBucketList"
    actions   = ["s3:ListBucket"]
    resources = [aws_s3_bucket.tfstate.arn]
  }

  statement {
    sid = "StateObjectRW"
    actions = [
      "s3:GetObject",
      "s3:PutObject",
      "s3:DeleteObject",
    ]
    resources = ["${aws_s3_bucket.tfstate.arn}/*"]
  }
}

# ── plan 역할 ──────────────────────────────────────────────────────────────

# PR 컨텍스트(pull_request)에서만 assume할 수 있도록 sub를 좁힌다.
data "aws_iam_policy_document" "plan_assume" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [data.aws_iam_openid_connect_provider.github.arn]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:sub"
      values   = ["repo:${var.github_owner}/${var.github_repo}:pull_request"]
    }
  }
}

resource "aws_iam_role" "plan" {
  name               = "${var.project}-ci-plan"
  description        = "GitHub Actions PR plan role (read-only + tfstate bucket R/W)."
  assume_role_policy = data.aws_iam_policy_document.plan_assume.json
}

# plan은 리소스 상태를 refresh해야 하므로 읽기 전용 관리형 정책을 부여한다.
resource "aws_iam_role_policy_attachment" "plan_readonly" {
  role       = aws_iam_role.plan.name
  policy_arn = "arn:aws:iam::aws:policy/ReadOnlyAccess"
}

# ReadOnlyAccess로는 state 잠금 파일 쓰기가 안 되므로 state 버킷 R/W를 별도로 붙인다.
resource "aws_iam_role_policy" "plan_tfstate" {
  name   = "tfstate-access"
  role   = aws_iam_role.plan.id
  policy = data.aws_iam_policy_document.tfstate_access.json
}

# ── apply 역할 ─────────────────────────────────────────────────────────────

# production 환경을 통과한 실행에서만 assume할 수 있도록 sub를 좁힌다.
# apply 잡에 environment: production이 걸려 있어, 승인 게이트를 통과해야 이 토큰이 발급된다.
data "aws_iam_policy_document" "apply_assume" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [data.aws_iam_openid_connect_provider.github.arn]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:sub"
      values   = ["repo:${var.github_owner}/${var.github_repo}:environment:production"]
    }
  }
}

resource "aws_iam_role" "apply" {
  name               = "${var.project}-ci-apply"
  description        = "GitHub Actions apply role (AdministratorAccess + tfstate bucket R/W)."
  assume_role_policy = data.aws_iam_policy_document.apply_assume.json
}

# 이 레포는 Cognito/Lambda/API Gateway/DynamoDB/IAM/ACM/CodeDeploy/EventBridge/SNS 등
# 광범위한 리소스와 다수의 IAM 역할을 생성하므로 사실상 광범위 권한이 필요하다.
# 신뢰 정책을 environment:production으로 좁혀 "승인된 apply 실행"만 assume하도록 제한한다.
resource "aws_iam_role_policy_attachment" "apply_admin" {
  role       = aws_iam_role.apply.name
  policy_arn = "arn:aws:iam::aws:policy/AdministratorAccess"
}

# AdministratorAccess가 state 버킷 접근을 포함하지만, 역할 간 일관성을 위해 명시해 둔다.
resource "aws_iam_role_policy" "apply_tfstate" {
  name   = "tfstate-access"
  role   = aws_iam_role.apply.id
  policy = data.aws_iam_policy_document.tfstate_access.json
}

# ── outputs ────────────────────────────────────────────────────────────────

output "ci_plan_role_arn" {
  description = "GitHub Actions PR plan 역할 ARN. GitHub Secret PLAN_ROLE_ARN에 넣는다."
  value       = aws_iam_role.plan.arn
}

output "ci_apply_role_arn" {
  description = "GitHub Actions apply 역할 ARN. GitHub Secret APPLY_ROLE_ARN에 넣는다."
  value       = aws_iam_role.apply.arn
}
