# 아티팩트 버킷 이름이다. CI는 이 버킷에 코드 zip을 업로드한다.
output "artifact_bucket" {
  description = "Lambda 코드 zip을 업로드하는 아티팩트 S3 버킷 이름."
  value       = module.artifacts.bucket_id
}

# URL/통계 데이터를 담는 DynamoDB 단일 테이블 이름이다. Lambda 환경변수로 주입한다.
output "url_shortener_table_name" {
  description = "URL/통계 단일 테이블 이름."
  value       = module.dynamodb.table_name
}

# 위 테이블의 ARN이다. Lambda 실행 역할 IAM 정책 대상으로 사용한다(GSI 쿼리 시 index/* 조합 필요).
output "url_shortener_table_arn" {
  description = "URL/통계 단일 테이블 ARN."
  value       = module.dynamodb.table_arn
}

# 인증 Lambda 함수 이름이다. CI는 이 이름으로 update-function-code를 호출한다.
output "auth_function_name" {
  description = "인증 Lambda 함수 이름."
  value       = module.lambda_auth.function_name
}

# URL 단축/통계/리다이렉트 Lambda 함수 이름이다. CI는 이 이름으로 update-function-code를 호출한다.
output "url_function_name" {
  description = "URL 단축/통계/리다이렉트 Lambda 함수 이름."
  value       = module.lambda_url.function_name
}

# 검증 완료된 TLS 인증서 ARN이다. API Gateway/ALB 등에 연결할 때 사용한다.
output "certificate_arn" {
  description = "검증 완료된 ACM 인증서 ARN."
  value       = module.certificate.certificate_arn
}

# 인증 API의 커스텀 도메인 호출 URL이다 (예: https://auth.jhan.cc).
output "auth_api_url" {
  description = "인증 API 커스텀 도메인 호출 URL."
  value       = module.apigateway.custom_domain_url
}

# 인증 API의 기본 실행 엔드포인트(execute-api URL)다. 커스텀 도메인 전파 전/디버깅에 쓴다.
output "auth_api_endpoint" {
  description = "인증 API 기본 실행 엔드포인트(execute-api URL)."
  value       = module.apigateway.api_endpoint
}

# URL API의 커스텀 도메인 호출 URL이다 (예: https://short.jhan.cc).
output "url_api_url" {
  description = "URL API 커스텀 도메인 호출 URL."
  value       = module.apigateway_url.custom_domain_url
}

# URL API의 기본 실행 엔드포인트(execute-api URL)다. 커스텀 도메인 전파 전/디버깅에 쓴다.
output "url_api_endpoint" {
  description = "URL API 기본 실행 엔드포인트(execute-api URL)."
  value       = module.apigateway_url.api_endpoint
}

# --- 배포(Alias/CodeDeploy) ---

# URL 함수의 트래픽을 가리키는 Alias 이름이다. CI/CodeDeploy 전환 대상으로 쓴다.
output "url_alias_name" {
  description = "URL 함수 Alias 이름(live)."
  value       = module.lambda_url.alias_name
}

# auth 함수의 Alias 이름이다. CI가 CodeDeploy(AllAtOnce)로 이 alias를 전환한다.
output "auth_alias_name" {
  description = "auth 함수 Alias 이름(live)."
  value       = module.lambda_auth.alias_name
}

# URL 함수의 CodeDeploy 애플리케이션 이름이다. CI의 create-deployment에 사용한다.
output "url_codedeploy_app_name" {
  description = "URL 함수 CodeDeploy 애플리케이션 이름."
  value       = module.codedeploy_url.app_name
}

# URL 함수의 CodeDeploy 배포 그룹 이름이다. CI의 create-deployment에 사용한다.
output "url_codedeploy_deployment_group_name" {
  description = "URL 함수 CodeDeploy 배포 그룹 이름."
  value       = module.codedeploy_url.deployment_group_name
}

# auth 함수의 CodeDeploy 애플리케이션 이름이다. CI의 create-deployment에 사용한다.
output "auth_codedeploy_app_name" {
  description = "auth 함수 CodeDeploy 애플리케이션 이름."
  value       = module.codedeploy_auth.app_name
}

# auth 함수의 CodeDeploy 배포 그룹 이름이다. CI의 create-deployment에 사용한다.
output "auth_codedeploy_deployment_group_name" {
  description = "auth 함수 CodeDeploy 배포 그룹 이름."
  value       = module.codedeploy_auth.deployment_group_name
}

# URL 함수 배포 롤백/실패 및 알람을 통지하는 SNS 토픽 ARN이다.
output "url_deploy_notify_topic_arn" {
  description = "URL 함수 CodeDeploy 롤백/실패 및 알람 통지 SNS 토픽 ARN."
  value       = module.codedeploy_url.sns_topic_arn
}

# auth 함수 배포 롤백/실패 및 알람을 통지하는 SNS 토픽 ARN이다.
output "auth_deploy_notify_topic_arn" {
  description = "auth 함수 CodeDeploy 롤백/실패 및 알람 통지 SNS 토픽 ARN."
  value       = module.codedeploy_auth.sns_topic_arn
}

# URL 함수의 자동 롤백 기준 Lambda Errors 알람 이름이다.
# url은 executed_version 모드이므로, CI가 배포 직전 이 이름으로 PutMetricAlarm(upsert)해
# 신버전(ExecutedVersion) 차원으로 갱신한다.
output "url_errors_alarm_name" {
  description = "URL 함수 자동 롤백 기준 Lambda Errors 알람 이름(CI가 PutMetricAlarm으로 신버전 차원 갱신)."
  value       = module.codedeploy_url.errors_alarm_name
}

# CI의 LAMBDA_DEPLOY_MAP(GitHub Actions variable)에 그대로 넣을 JSON이다.
# `terraform output -raw lambda_deploy_map`으로 뽑아 복사한다.
# 최상위 키는 CI 매트릭스 핸들러 이름(url_handler_key/auth_handler_key)이다.
# - url: executed_version 모드이므로 errors_alarm_name/notify_topic_arn/임계값을 포함한다.
# - auth: alias 모드이므로 알람 갱신 관련 키는 생략한다(CI가 요구하지 않음).
output "lambda_deploy_map" {
  description = "CI LAMBDA_DEPLOY_MAP variable에 넣을 핸들러->배포 설정 매핑 JSON."
  value = jsonencode({
    (var.url_handler_key) = {
      function          = module.lambda_url.function_name
      alias             = module.lambda_url.alias_name
      codedeploy_app    = module.codedeploy_url.app_name
      codedeploy_group  = module.codedeploy_url.deployment_group_name
      errors_alarm_mode = module.codedeploy_url.errors_alarm_mode
      errors_alarm_name = module.codedeploy_url.errors_alarm_name
      error_namespace   = module.codedeploy_url.error_namespace
      error_metric_name = module.codedeploy_url.error_metric_name
      notify_topic_arn  = module.codedeploy_url.sns_topic_arn
      alarm_threshold   = module.codedeploy_url.alarm_threshold
      alarm_period      = module.codedeploy_url.alarm_period_seconds
    }
    (var.auth_handler_key) = {
      function          = module.lambda_auth.function_name
      alias             = module.lambda_auth.alias_name
      codedeploy_app    = module.codedeploy_auth.app_name
      codedeploy_group  = module.codedeploy_auth.deployment_group_name
      errors_alarm_mode = module.codedeploy_auth.errors_alarm_mode
    }
  })
}
