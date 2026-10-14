output "app_name" {
  description = "CodeDeploy 애플리케이션 이름이다. CI의 create-deployment --application-name에 사용한다."
  value       = aws_codedeploy_app.this.name
}

output "deployment_group_name" {
  description = "CodeDeploy 배포 그룹 이름이다. CI의 create-deployment --deployment-group-name에 사용한다."
  value       = aws_codedeploy_deployment_group.this.deployment_group_name
}

output "deployment_config_name" {
  description = "적용된 배포 설정 이름(전략)이다."
  value       = aws_codedeploy_deployment_group.this.deployment_config_name
}

output "service_role_arn" {
  description = "CodeDeploy 서비스 역할 ARN이다."
  value       = aws_iam_role.codedeploy.arn
}

output "sns_topic_arn" {
  description = "배포 롤백/실패 및 알람 통지를 발행하는 SNS 토픽 ARN이다."
  value       = aws_sns_topic.notify.arn
}

output "errors_alarm_name" {
  description = "자동 롤백 기준인 Lambda Errors 알람 이름이다. executed_version 모드면 CI가 이 이름으로 PutMetricAlarm(upsert)해 신버전 차원을 갱신한다."
  value       = local.errors_alarm_name
}

output "errors_alarm_mode" {
  description = "Lambda Errors 알람의 집계 차원 모드다(executed_version | alias)."
  value       = var.errors_alarm_mode
}

output "error_namespace" {
  description = "자동 롤백 기준 에러 지표의 네임스페이스다. CI가 PutMetricAlarm할 때 동일 값을 써야 한다."
  value       = var.error_namespace
}

output "error_metric_name" {
  description = "자동 롤백 기준 에러 지표명이다. CI가 PutMetricAlarm할 때 동일 값을 써야 한다."
  value       = var.error_metric_name
}

output "api_5xx_alarm_name" {
  description = "상시 운영용 API Gateway 5xx 알람 이름이다(자동 롤백 기준 아님, SNS 통지만)."
  value       = aws_cloudwatch_metric_alarm.api_5xx.alarm_name
}

output "alarm_threshold" {
  description = "롤백 알람 임계값이다. CI가 PutMetricAlarm으로 알람을 덮어쓸 때 동일 값을 써야 한다."
  value       = var.alarm_threshold
}

output "alarm_period_seconds" {
  description = "롤백 알람 평가 주기(초)다. CI가 PutMetricAlarm으로 알람을 덮어쓸 때 동일 값을 써야 한다."
  value       = var.alarm_period_seconds
}
