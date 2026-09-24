# 재사용 가능한 Node.js(mjs) Lambda 함수 모듈이다.
# 실행 역할 + 기본 로그 권한 + (옵션)함수별 인라인 정책 + CloudWatch 로그 그룹 +
# 최초 생성 보장을 위한 플레이스홀더 zip 업로드 + 함수 리소스를 구성한다.
#
# 코드 갱신은 CI/CD가 update-function-code로 직접 수행하므로,
# Terraform은 코드 소스 관련 속성을 ignore_changes로 무시해 코드 CI/CD와 독립적으로 동작한다.

# --- IAM 실행 역할 ---

# Lambda 서비스가 이 역할을 맡을 수 있게 한다.
data "aws_iam_policy_document" "assume" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "this" {
  name               = "${var.name}-role"
  assume_role_policy = data.aws_iam_policy_document.assume.json
}

data "aws_iam_policy_document" "logs" {
  statement {
    actions = [
      "logs:CreateLogStream",
      "logs:PutLogEvents",
    ]
    resources = ["${aws_cloudwatch_log_group.this.arn}:*"]
  }
}

resource "aws_iam_role_policy" "logs" {
  name   = "${var.name}-logs"
  role   = aws_iam_role.this.id
  policy = data.aws_iam_policy_document.logs.json
}

# 호출 측이 넘긴 함수별 세밀 권한을 인라인으로 부착한다(선택).
resource "aws_iam_role_policy" "inline" {
  count  = var.inline_policy_json != null ? 1 : 0
  name   = "${var.name}-inline"
  role   = aws_iam_role.this.id
  policy = var.inline_policy_json
}

# --- CloudWatch 로그 그룹 ---

# 함수가 자동 생성하는 로그 그룹을 명시적으로 관리해 보존 기간을 통제한다.
resource "aws_cloudwatch_log_group" "this" {
  name              = "/aws/lambda/${var.name}"
  retention_in_days = var.log_retention_days
}

# --- 플레이스홀더 코드 ---

# handler 값("<zip 내부 경로>.<export명>")을 파싱한다.
#   예: "handlers/auth.handler" -> file="handlers/auth.mjs", export="handler"
# 마지막 점(.)을 기준으로 왼쪽은 확장자 없는 파일 경로, 오른쪽은 export 이름이다.
locals {
  handler_file_base = regex("^(.*)\\.[^.]+$", var.handler)[0] # "handlers/auth"
  handler_export    = regex("\\.([^.]+)$", var.handler)[0]    # "handler"
  placeholder_path  = "${local.handler_file_base}.mjs"        # "handlers/auth.mjs"
}

# 최초 생성 시점에는 CI가 아직 실제 코드를 올리지 않았을 수 있다.
# 함수 생성을 보장하기 위해, handler 변수가 가리키는 경로에 최소 핸들러가 담긴
# 플레이스홀더 zip을 같은 s3_key로 업로드한다. 이후 CI가 같은 키를 실제 코드로 덮어쓴다.
# handler 경로가 함수마다 달라도(예: handlers/auth.handler) 플레이스홀더가 항상 호출 가능하도록
# zip 내부 경로(filename)와 export 이름을 handler 값에 맞춰 동적으로 생성한다.
data "archive_file" "placeholder" {
  type        = "zip"
  output_path = "${path.module}/.placeholder_${replace(var.name, "/", "_")}.zip"

  source {
    filename = local.placeholder_path
    content  = <<-EOT
      // 최초 생성 보장을 위한 플레이스홀더 핸들러다.
      // 실제 코드는 CI/CD가 update-function-code로 이 함수를 덮어쓴다.
      // 실제 코드가 배포되기 전 호출되면 501(미구현)을 반환한다.
      export const ${local.handler_export} = async () => {
        return {
          statusCode: 501,
          headers: { "content-type": "application/json" },
          body: JSON.stringify({
            message: "Not Implemented: placeholder. CI/CD가 실제 코드를 아직 배포하지 않았다.",
          }),
        };
      };
    EOT
  }
}

resource "aws_s3_object" "placeholder" {
  bucket = var.artifact_bucket
  key    = var.s3_key
  source = data.archive_file.placeholder.output_path
  etag   = data.archive_file.placeholder.output_md5

  # CI가 같은 키에 실제 코드를 덮어쓰므로, 이후 Terraform이 되돌리지 않도록 무시한다.
  lifecycle {
    ignore_changes = [source, etag, version_id]
  }
}

# --- Lambda 함수 ---

resource "aws_lambda_function" "this" {
  function_name = var.name
  role          = aws_iam_role.this.arn

  runtime = var.runtime
  handler = var.handler

  memory_size = var.memory_size
  timeout     = var.timeout

  s3_bucket         = var.artifact_bucket
  s3_key            = var.s3_key
  s3_object_version = var.s3_object_version

  environment {
    variables = var.environment
  }

  # 로그 그룹과 역할 정책이 함수보다 먼저 준비되도록 한다.
  depends_on = [
    aws_cloudwatch_log_group.this,
    aws_iam_role_policy.logs,
    aws_s3_object.placeholder,
  ]

  # 코드 갱신은 CI/CD가 담당한다. Terraform이 코드 소스를 되돌리지 않도록 고정으로 무시한다.
  lifecycle {
    ignore_changes = [s3_key, s3_object_version, source_code_hash]
  }
}
