# 비동기 배포 드레이너 모듈이다.
#
# 배경: CodeDeploy는 배포 그룹당 활성 배포가 1개뿐이라, 배포가 겹치면 이후 CreateDeployment가
# DeploymentLimitExceededException으로 거부된다. 이를 해소하기 위해 배포 트리거를 CI에서 떼어
# 이벤트 기반 드레이너 Lambda로 옮긴다. CI는 DeployQueue에 desiredVersion만 적재(enqueue)하고
# 즉시 종료하며, 드레이너가 큐를 조건부 락으로 소비해 배포 그룹당 1개 제약을 지켜 순차 배포한다.
#
# 이 모듈이 소유하는 것(설계 async-deploy-drainer.md 8절):
#   - DeployQueue DynamoDB 테이블(Streams NEW_AND_OLD_IMAGES, TTL 속성 lockExpiresAt)
#   - 드레이너 Lambda(핸들러 코드 포함, archive_file로 자체 패키징 — CI 비의존)
#   - 트리거 A: DeployQueue Streams -> 드레이너 (이벤트 소스 매핑)
#   - 트리거 B: CodeDeploy 상태변경 EventBridge 규칙 -> 드레이너
#   - 드레이너 IAM 역할(최소 권한 인라인 정책)

locals {
  common_tags = merge({
    Project   = "urlshortener"
    ManagedBy = "terraform"
  }, var.tags)

  drainer_name = "${var.name}-deploy-drainer"
  queue_name   = "${var.name}-deploy-queue"

  # 최소 권한 ARN 구성용. deploy_config의 각 함수에서 codedeploy app/group, function을 모아
  # 대상 ARN 목록을 만든다.
  codedeploy_app_names   = distinct([for cfg in values(var.deploy_config) : cfg.codedeploy_app])
  codedeploy_group_names = distinct([for cfg in values(var.deploy_config) : cfg.codedeploy_group])
  function_names         = distinct([for cfg in values(var.deploy_config) : cfg.function])

  codedeploy_app_arns = [
    for app in local.codedeploy_app_names :
    "arn:aws:codedeploy:${data.aws_region.current.region}:${data.aws_caller_identity.current.account_id}:application:${app}"
  ]
  # 배포 그룹 ARN은 "deploymentgroup:<app>/<group>" 형태다. app==group(이 프로젝트 컨벤션)이라
  # deploy_config 각 항목에서 app/group 쌍으로 구성한다.
  codedeploy_group_arns = distinct([
    for cfg in values(var.deploy_config) :
    "arn:aws:codedeploy:${data.aws_region.current.region}:${data.aws_caller_identity.current.account_id}:deploymentgroup:${cfg.codedeploy_app}/${cfg.codedeploy_group}"
  ])
  # 배포 설정(deploymentconfig) ARN. CreateDeployment가 사전정의 config를 참조하므로 전체 허용.
  codedeploy_config_arn = "arn:aws:codedeploy:${data.aws_region.current.region}:${data.aws_caller_identity.current.account_id}:deploymentconfig:*"

  # lambda:GetAlias 대상: <function>:<alias> 까지 한정한다.
  lambda_alias_arns = distinct([
    for cfg in values(var.deploy_config) :
    "arn:aws:lambda:${data.aws_region.current.region}:${data.aws_caller_identity.current.account_id}:function:${cfg.function}:${try(cfg.alias, "live")}"
  ])
  # GetAlias는 함수 ARN(버전 비한정)에도 작동하므로 함수 ARN도 포함한다.
  lambda_function_arns = distinct([
    for cfg in values(var.deploy_config) :
    "arn:aws:lambda:${data.aws_region.current.region}:${data.aws_caller_identity.current.account_id}:function:${cfg.function}"
  ])
}

data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

# --- DeployQueue DynamoDB 테이블 (큐 + 분산 락 + 멱등 저장소) ---

# 함수(=배포 그룹)당 한 행으로 상태를 관리한다. PK="FN#<function>".
# Streams(NEW_AND_OLD_IMAGES)를 켜 enqueue 트리거(A)로 쓰고, lockExpiresAt을 TTL 속성으로 지정해
# 좀비 락을 자동 정리(그리고 다음 드레이너가 탈취)한다.
resource "aws_dynamodb_table" "deploy_queue" {
  name         = local.queue_name
  billing_mode = "PAY_PER_REQUEST"

  hash_key = "PK"

  attribute {
    name = "PK"
    type = "S"
  }

  # 락 TTL. lockExpiresAt(epoch 초)이 지나면 DynamoDB가 항목을 정리할 수 있다.
  # 단, 드레이너의 좀비 락 탈취는 lockExpiresAt < now 조건부 쓰기로 즉시 처리하므로
  # TTL 삭제 타이밍에 의존하지 않는다(TTL은 보조적 청소 역할).
  ttl {
    attribute_name = "lockExpiresAt"
    enabled        = true
  }

  # enqueue 트리거(A)용 Streams. 드레이너가 NewImage에서 PK/desiredVersion을 읽는다.
  # NEW_AND_OLD_IMAGES로 둬서, 드레이너 자신의 쓰기(락 획득/배포ID 기록/해제 등 desiredVersion을
  # 바꾸지 않는 MODIFY)를 OldImage.desiredVersion == NewImage.desiredVersion 비교로 걸러낸다.
  # 이렇게 하지 않으면 드레이너의 자기 쓰기가 Streams로 자신을 재호출하는 증폭 루프가 생긴다.
  stream_enabled   = true
  stream_view_type = "NEW_AND_OLD_IMAGES"

  tags = local.common_tags
}

# --- 드레이너 Lambda 코드 패키징 (archive_file) ---

# src/의 핸들러 소스를 zip으로 묶는다. 테스트 파일(*.test.mjs)은 제외한다.
# CI 비의존: 이 모듈이 코드를 소유하고 Terraform이 직접 배포한다.
data "archive_file" "drainer" {
  type        = "zip"
  output_path = "${path.module}/.drainer.zip"

  source {
    content  = file("${path.module}/src/index.mjs")
    filename = "index.mjs"
  }
  source {
    content  = file("${path.module}/src/drainer.mjs")
    filename = "drainer.mjs"
  }
  source {
    content  = file("${path.module}/src/decide.mjs")
    filename = "decide.mjs"
  }
  source {
    content  = file("${path.module}/src/normalize.mjs")
    filename = "normalize.mjs"
  }
}

# --- 드레이너 IAM 실행 역할 ---

data "aws_iam_policy_document" "assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "drainer" {
  name               = "${local.drainer_name}-role"
  assume_role_policy = data.aws_iam_policy_document.assume.json
  tags               = local.common_tags
}

# 드레이너 최소 권한 인라인 정책(설계 8절).
data "aws_iam_policy_document" "drainer" {
  # CloudWatch Logs 기본.
  statement {
    sid = "Logs"
    actions = [
      "logs:CreateLogStream",
      "logs:PutLogEvents",
    ]
    resources = ["${aws_cloudwatch_log_group.drainer.arn}:*"]
  }

  # DeployQueue 읽기/쓰기(테이블 본체 한정).
  statement {
    sid = "DeployQueueItem"
    actions = [
      "dynamodb:GetItem",
      "dynamodb:UpdateItem",
    ]
    resources = [aws_dynamodb_table.deploy_queue.arn]
  }

  # DeployQueue Streams 읽기(트리거 A). 이벤트 소스 매핑이 폴링한다.
  statement {
    sid = "DeployQueueStream"
    actions = [
      "dynamodb:GetRecords",
      "dynamodb:GetShardIterator",
      "dynamodb:DescribeStream",
      "dynamodb:ListStreams",
    ]
    resources = [
      aws_dynamodb_table.deploy_queue.stream_arn,
      "${aws_dynamodb_table.deploy_queue.arn}/stream/*",
    ]
  }

  # CodeDeploy 배포 트리거/조회(관리 대상 app/group 한정).
  # CreateDeployment는 AppSpecContent 리비전을 등록하므로 RegisterApplicationRevision도 함께 필요하다
  # (application 리소스 대상). 두 액션 모두 아래 app/group ARN 묶음으로 커버한다.
  statement {
    sid = "CodeDeployDeploy"
    actions = [
      "codedeploy:CreateDeployment",
      "codedeploy:RegisterApplicationRevision",
      "codedeploy:GetDeployment",
      "codedeploy:ListDeployments",
    ]
    resources = concat(local.codedeploy_app_arns, local.codedeploy_group_arns)
  }

  # CreateDeployment가 참조하는 사전정의 배포 설정(deploymentconfig).
  statement {
    sid       = "CodeDeployConfig"
    actions   = ["codedeploy:GetDeploymentConfig"]
    resources = [local.codedeploy_config_arn]
  }

  # alias 현재 버전 조회(appspec 구성용).
  statement {
    sid       = "LambdaGetAlias"
    actions   = ["lambda:GetAlias"]
    resources = concat(local.lambda_function_arns, local.lambda_alias_arns)
  }

  # executed_version 모드 롤백 알람 갱신. PutMetricAlarm은 리소스 레벨 제한이 약해 *로 둔다.
  statement {
    sid       = "PutMetricAlarm"
    actions   = ["cloudwatch:PutMetricAlarm"]
    resources = ["*"]
  }
}

resource "aws_iam_role_policy" "drainer" {
  name   = "${local.drainer_name}-inline"
  role   = aws_iam_role.drainer.id
  policy = data.aws_iam_policy_document.drainer.json
}

# --- CloudWatch 로그 그룹 ---

resource "aws_cloudwatch_log_group" "drainer" {
  name              = "/aws/lambda/${local.drainer_name}"
  retention_in_days = var.log_retention_days
  tags              = local.common_tags
}

# --- 드레이너 Lambda 함수 ---

resource "aws_lambda_function" "drainer" {
  function_name = local.drainer_name
  role          = aws_iam_role.drainer.arn

  runtime = var.runtime
  handler = "index.handler"

  filename         = data.archive_file.drainer.output_path
  source_code_hash = data.archive_file.drainer.output_base64sha256

  memory_size = var.memory_size
  timeout     = var.timeout

  environment {
    variables = {
      DEPLOY_QUEUE_TABLE = aws_dynamodb_table.deploy_queue.name
      DEPLOY_CONFIG      = jsonencode(var.deploy_config)
      LOCK_TTL_SECONDS   = tostring(var.lock_ttl_seconds)
    }
  }

  depends_on = [
    aws_cloudwatch_log_group.drainer,
    aws_iam_role_policy.drainer,
  ]

  tags = local.common_tags
}

# --- 트리거 A: DeployQueue Streams -> 드레이너 (enqueue) ---

# CI가 desiredVersion을 DDB에 쓰면 Streams가 드레이너를 깨운다.
# CI는 DDB 쓰기만 하면 되어 느슨하게 결합된다.
resource "aws_lambda_event_source_mapping" "deploy_queue_stream" {
  event_source_arn  = aws_dynamodb_table.deploy_queue.stream_arn
  function_name     = aws_lambda_function.drainer.arn
  starting_position = "LATEST"
  batch_size        = var.stream_batch_size

  # enqueue는 멱등 처리되므로 재시도를 보수적으로 둔다. 레코드 하나가 막아도 큐 진행을 방해하지
  # 않도록 실패 레코드는 폐기한다(다음 enqueue/EventBridge 이벤트가 상태를 재평가한다).
  maximum_retry_attempts         = 2
  bisect_batch_on_function_error = false
}

# --- 트리거 B: CodeDeploy 상태변경 EventBridge -> 드레이너 (dequeue) ---

# 앞 배포가 끝나면(SUCCESS/FAILURE/STOP) 드레이너를 깨워 다음 목표를 배포하게 한다.
# 이 트리거가 없으면 큐가 영영 비워지지 않는다(dequeue의 심장).
resource "aws_cloudwatch_event_rule" "codedeploy_state" {
  name        = "${local.drainer_name}-codedeploy-state"
  description = "CodeDeploy 배포 종료(SUCCESS/FAILURE/STOP) 시 드레이너를 깨워 다음 배포를 수행한다."

  event_pattern = jsonencode({
    source      = ["aws.codedeploy"]
    detail-type = ["CodeDeploy Deployment State-change Notification"]
    detail = {
      state = ["SUCCESS", "FAILURE", "STOP"]
      # 관리 대상 배포 그룹으로 한정한다. 이렇게 하지 않으면 계정의 모든 CodeDeploy 상태변경에
      # 드레이너가 반응해 불필요한 호출이 늘어난다. (CodeDeploy 상태변경 이벤트의 detail 필드명은
      # application / deploymentGroup 이다.)
      deploymentGroup = local.codedeploy_group_names
    }
  })

  tags = local.common_tags
}

resource "aws_cloudwatch_event_target" "drainer" {
  rule      = aws_cloudwatch_event_rule.codedeploy_state.name
  target_id = "drainer"
  arn       = aws_lambda_function.drainer.arn
}

# EventBridge가 드레이너를 호출할 수 있게 허용한다.
resource "aws_lambda_permission" "allow_eventbridge" {
  statement_id  = "AllowEventBridgeInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.drainer.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.codedeploy_state.arn
}
