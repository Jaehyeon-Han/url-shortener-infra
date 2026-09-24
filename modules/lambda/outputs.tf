output "function_name" {
  description = "Lambda 함수 이름. CI의 update-function-code 대상이다."
  value       = aws_lambda_function.this.function_name
}

output "function_arn" {
  description = "Lambda 함수 ARN."
  value       = aws_lambda_function.this.arn
}

output "invoke_arn" {
  description = "함수 호출 ARN. API Gateway 통합에서 사용한다."
  value       = aws_lambda_function.this.invoke_arn
}

output "role_arn" {
  description = "함수 실행 역할 ARN."
  value       = aws_iam_role.this.arn
}
