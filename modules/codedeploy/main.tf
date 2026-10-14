# Lambda Alias의 트래픽을 CodeDeploy로 안전하게 전환(Canary 등)하는 모듈이다.
# 배포 그룹은 CloudWatch 알람(Lambda Errors / API Gateway 5xx)이 ALARM이 되면
# 자동으로 롤백하며, 롤백/실패 이벤트와 알람을 SNS로 운영 담당자에게 통지한다.
#
# 실제 배포 트리거(create-deployment)와 appspec 생성은 CI/CD가 담당한다.
# 이 모듈은 CodeDeploy 앱/배포그룹/서비스역할/알람/SNS만 "준비"한다.

locals {
  common_tags = merge({
    Project   = "urlshortener"
    ManagedBy = "terraform"
  }, var.tags)
}

# --- SNS 토픽 (롤백/실패/알람 통지) ---

resource "aws_sns_topic" "notify" {
  name = "${var.name}-deploy-notify"
  tags = local.common_tags
}

# 운영 담당자 이메일을 구독으로 연결한다. 각 수신자는 확인 메일을 눌러야 활성화된다.
resource "aws_sns_topic_subscription" "email" {
  for_each = toset(var.notification_emails)

  topic_arn = aws_sns_topic.notify.arn
  protocol  = "email"
  endpoint  = each.value
}

# CloudWatch 알람이 이 토픽에 발행할 수 있도록 토픽 정책을 부여한다.
data "aws_iam_policy_document" "sns" {
  statement {
    sid       = "AllowCloudWatchAlarmsPublish"
    actions   = ["sns:Publish"]
    resources = [aws_sns_topic.notify.arn]

    principals {
      type        = "Service"
      identifiers = ["cloudwatch.amazonaws.com"]
    }
  }

  statement {
    sid       = "AllowCodeDeployPublish"
    actions   = ["sns:Publish"]
    resources = [aws_sns_topic.notify.arn]

    principals {
      type        = "Service"
      identifiers = ["codedeploy.amazonaws.com"]
    }
  }
}

resource "aws_sns_topic_policy" "notify" {
  arn    = aws_sns_topic.notify.arn
  policy = data.aws_iam_policy_document.sns.json
}

# --- CodeDeploy 서비스 역할 ---

data "aws_iam_policy_document" "assume" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["codedeploy.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "codedeploy" {
  name               = "${var.name}-codedeploy-role"
  assume_role_policy = data.aws_iam_policy_document.assume.json
  tags               = local.common_tags
}

# Lambda 트래픽 전환에 필요한 권한을 가진 AWS 관리형 정책을 부착한다.
# (alias 업데이트, 버전 조회, CloudWatch 알람 조회 등)
resource "aws_iam_role_policy_attachment" "codedeploy_lambda" {
  role       = aws_iam_role.codedeploy.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSCodeDeployRoleForLambda"
}

# --- CodeDeploy 애플리케이션 ---

resource "aws_codedeploy_app" "this" {
  name             = var.name
  compute_platform = "Lambda"
  tags             = local.common_tags
}

# --- CloudWatch 알람 2종 (자동 롤백 기준) ---

# --- CloudWatch 알람: Lambda Errors (자동 롤백 기준) ---

# 모드 "alias": alias 경유 트래픽의 에러를 집계한다(정적). AllAtOnce 함수에 적합.
# Resource 차원 = "<함수>:<alias>"로 좁혀 $LATEST 직접 호출 등은 제외한다.
resource "aws_cloudwatch_metric_alarm" "lambda_errors_alias" {
  count = var.errors_alarm_mode == "alias" ? 1 : 0

  alarm_name          = "${var.name}-lambda-errors"
  alarm_description   = "Lambda ${var.lambda_function_name}:${var.lambda_alias_name} 에러가 ${var.alarm_period_seconds}초 동안 ${var.alarm_threshold}건 이상이면 배포를 롤백한다."
  namespace           = var.error_namespace
  metric_name         = var.error_metric_name
  statistic           = "Sum"
  comparison_operator = "GreaterThanOrEqualToThreshold"
  threshold           = var.alarm_threshold
  period              = var.alarm_period_seconds
  evaluation_periods  = 1
  treat_missing_data  = "notBreaching"

  dimensions = {
    FunctionName = var.lambda_function_name
    Resource     = "${var.lambda_function_name}:${var.lambda_alias_name}"
  }

  alarm_actions = [aws_sns_topic.notify.arn]
  ok_actions    = [aws_sns_topic.notify.arn]

  tags = local.common_tags
}

# 모드 "executed_version": 신규 버전만 집계하는 동적 알람의 "껍데기"다.
# Terraform은 고정 이름과 SNS 연결·초기 임계값만 보장하고, 실제 가드 차원
# (ExecutedVersion=신버전)과 임계값/주기는 CI가 배포 직전 PutMetricAlarm으로 갱신한다.
# 따라서 CI 갱신이 Terraform과 충돌하지 않도록 관련 속성을 ignore_changes로 무시한다.
#
# 초기 차원은 alias Resource로 둔다. 아직 배포가 없을 때(또는 CI 갱신 전)에도
# 유효한 지표를 가리켜 INSUFFICIENT_DATA로만 머물지 않게 하기 위함이다.
resource "aws_cloudwatch_metric_alarm" "lambda_errors_executed_version" {
  count = var.errors_alarm_mode == "executed_version" ? 1 : 0

  alarm_name          = "${var.name}-lambda-errors"
  alarm_description   = "신규 버전(ExecutedVersion) 에러 기준 자동 롤백 알람이다. 차원/임계값은 CI가 배포 직전 갱신한다."
  namespace           = var.error_namespace
  metric_name         = var.error_metric_name
  statistic           = "Sum"
  comparison_operator = "GreaterThanOrEqualToThreshold"
  threshold           = var.alarm_threshold
  period              = var.alarm_period_seconds
  evaluation_periods  = 1
  treat_missing_data  = "notBreaching"

  # 초기값(배포 전/CI 갱신 전 유효). CI가 ExecutedVersion 차원을 추가해 덮어쓴다.
  dimensions = {
    FunctionName = var.lambda_function_name
    Resource     = "${var.lambda_function_name}:${var.lambda_alias_name}"
  }

  alarm_actions = [aws_sns_topic.notify.arn]
  ok_actions    = [aws_sns_topic.notify.arn]

  tags = local.common_tags

  # CI(PutMetricAlarm)가 매 배포 때 차원/임계값/주기를 신버전 기준으로 덮어쓴다.
  # Terraform이 이를 되돌리지 않도록 무시한다. 알람 이름/SNS 연결은 Terraform이 계속 소유한다.
  lifecycle {
    ignore_changes = [
      dimensions,
      threshold,
      period,
      evaluation_periods,
      comparison_operator,
      statistic,
      namespace,
      metric_name,
      alarm_description,
    ]
  }
}

locals {
  # 활성화된 Lambda Errors 알람 이름(모드에 따라 하나만 존재).
  errors_alarm_name = coalesce(
    one(aws_cloudwatch_metric_alarm.lambda_errors_alias[*].alarm_name),
    one(aws_cloudwatch_metric_alarm.lambda_errors_executed_version[*].alarm_name),
  )
}

# --- CloudWatch 알람: API Gateway 5xx (상시 운영 알람, 롤백 기준 아님) ---

# HTTP API v2는 AWS/ApiGateway 네임스페이스의 "5xx" 지표를 ApiId 차원으로 낸다.
# 이 지표에는 Lambda 버전 차원이 없어 Canary 중 신/구 버전 5xx가 합산되므로,
# 자동 롤백 기준(배포그룹 alarm_configuration)에서는 제외한다.
# 대신 상시 운영 알람으로 두고 ALARM 시 SNS로 통지만 한다.
resource "aws_cloudwatch_metric_alarm" "api_5xx" {
  alarm_name          = "${var.name}-apigw-5xx"
  alarm_description   = "API ${var.api_id} 5xx가 ${var.alarm_period_seconds}초 동안 ${var.alarm_threshold}건 이상이면 운영 담당자에게 통지한다(자동 롤백 기준 아님)."
  namespace           = "AWS/ApiGateway"
  metric_name         = "5xx"
  statistic           = "Sum"
  comparison_operator = "GreaterThanOrEqualToThreshold"
  threshold           = var.alarm_threshold
  period              = var.alarm_period_seconds
  evaluation_periods  = 1
  treat_missing_data  = "notBreaching"

  dimensions = {
    ApiId = var.api_id
  }

  alarm_actions = [aws_sns_topic.notify.arn]
  ok_actions    = [aws_sns_topic.notify.arn]

  tags = local.common_tags
}

# --- CodeDeploy 배포 그룹 ---

resource "aws_codedeploy_deployment_group" "this" {
  app_name               = aws_codedeploy_app.this.name
  deployment_group_name  = var.name
  service_role_arn       = aws_iam_role.codedeploy.arn
  deployment_config_name = var.deployment_config_name

  # Lambda는 blue/green + 트래픽 제어 방식으로 전환한다.
  deployment_style {
    deployment_option = "WITH_TRAFFIC_CONTROL"
    deployment_type   = "BLUE_GREEN"
  }

  # 자동 롤백 기준 알람을 등록한다. Lambda Errors 알람만 등록한다.
  # (API Gateway 5xx는 버전 차원이 없어 Canary 중 신/구가 섞이므로 롤백 기준에서 제외하고
  #  상시 SNS 통지용으로만 둔다.)
  alarm_configuration {
    enabled = true
    alarms  = [local.errors_alarm_name]
  }

  # 알람으로 배포가 중단되면 자동 롤백한다.
  auto_rollback_configuration {
    enabled = true
    events  = ["DEPLOYMENT_STOP_ON_ALARM"]
  }

  # 롤백/실패 이벤트를 SNS로 운영 담당자에게 통지한다.
  trigger_configuration {
    trigger_name       = "${var.name}-deploy-events"
    trigger_target_arn = aws_sns_topic.notify.arn
    trigger_events = [
      "DeploymentFailure",
      "DeploymentRollback",
    ]
  }

  tags = local.common_tags
}
