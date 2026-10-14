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

# --- Alias 관련 (enable_alias=true일 때 유효) ---

output "alias_name" {
  description = "생성된 Alias 이름이다. enable_alias=false면 null이다."
  value       = var.enable_alias ? aws_lambda_alias.this[0].name : null
}

output "alias_arn" {
  description = "Alias ARN(함수:alias 형태)이다. CodeDeploy appspec/권한 등에서 사용한다. enable_alias=false면 null이다."
  value       = var.enable_alias ? aws_lambda_alias.this[0].arn : null
}

output "alias_invoke_arn" {
  description = "Alias를 가리키는 invoke ARN이다. API Gateway 통합이 이 값을 쓰면 Alias를 통해 트래픽이 흐른다. enable_alias=false면 null이다."
  value       = var.enable_alias ? aws_lambda_alias.this[0].invoke_arn : null
}

# API Gateway 통합에 넘길 "효과적" invoke ARN이다.
# enable_alias=true면 Alias invoke ARN을, false면 함수 invoke ARN을 반환한다.
# 호출부가 분기 없이 이 값만 넘기면 되도록 편의 출력으로 제공한다.
output "integration_invoke_arn" {
  description = "API Gateway 통합용 invoke ARN. enable_alias이면 Alias를, 아니면 함수를 가리킨다."
  value       = var.enable_alias ? aws_lambda_alias.this[0].invoke_arn : aws_lambda_function.this.invoke_arn
}

# API Gateway 호출 권한(aws_lambda_permission)의 qualifier로 쓸 값이다.
# enable_alias=true면 alias 이름을, 아니면 null(비한정, $LATEST 포함)이다.
output "qualifier" {
  description = "Lambda 권한 qualifier. enable_alias이면 alias 이름, 아니면 null."
  value       = var.enable_alias ? aws_lambda_alias.this[0].name : null
}

output "role_arn" {
  description = "함수 실행 역할 ARN."
  value       = aws_iam_role.this.arn
}
