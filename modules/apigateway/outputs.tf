output "api_id" {
  description = "HTTP API의 ID다."
  value       = aws_apigatewayv2_api.this.id
}

output "api_endpoint" {
  description = "API Gateway가 제공하는 기본 실행 엔드포인트(execute-api URL)다."
  value       = aws_apigatewayv2_api.this.api_endpoint
}

output "execution_arn" {
  description = "API 실행 ARN이다. Lambda 권한의 source_arn 계산 등에 사용한다."
  value       = aws_apigatewayv2_api.this.execution_arn
}

output "stage_invoke_url" {
  description = "$default 스테이지의 호출 URL이다."
  value       = aws_apigatewayv2_stage.default.invoke_url
}

output "custom_domain_url" {
  description = "커스텀 도메인 기준 호출 URL이다 (예: https://auth.jhan.cc)."
  value       = "https://${var.domain_name}"
}

output "custom_domain_target" {
  description = "커스텀 도메인이 가리키는 API Gateway regional target 도메인이다. CNAME 대상값이다."
  value       = aws_apigatewayv2_domain_name.this.domain_name_configuration[0].target_domain_name
}
