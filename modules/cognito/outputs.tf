output "user_pool_id" {
  description = "Cognito User Pool ID"
  value       = aws_cognito_user_pool.this.id
}

output "user_pool_arn" {
  description = "Cognito User Pool ARN"
  value       = aws_cognito_user_pool.this.arn
}

output "user_pool_client_id" {
  description = "App Client ID. API Gateway JWT Authorizer 의 audience 로 사용"
  value       = aws_cognito_user_pool_client.this.id
}

output "issuer_url" {
  description = "토큰 발급자(iss) URL. API Gateway JWT Authorizer 의 issuer 로 사용"
  value       = aws_cognito_user_pool.this.endpoint
}
