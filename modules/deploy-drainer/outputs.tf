output "deploy_queue_table_name" {
  description = "DeployQueue 테이블 이름이다. CI가 enqueue(UpdateItem) 대상으로 쓸 DEPLOY_QUEUE_TABLE 값이다."
  value       = aws_dynamodb_table.deploy_queue.name
}

output "deploy_queue_table_arn" {
  description = "DeployQueue 테이블 ARN이다. CI OIDC 역할에 dynamodb:UpdateItem 권한을 이 ARN으로 한정해 부여할 때 쓴다."
  value       = aws_dynamodb_table.deploy_queue.arn
}

output "deploy_queue_stream_arn" {
  description = "DeployQueue Streams ARN이다(트리거 A의 이벤트 소스)."
  value       = aws_dynamodb_table.deploy_queue.stream_arn
}

output "drainer_function_name" {
  description = "드레이너 Lambda 함수 이름이다."
  value       = aws_lambda_function.drainer.function_name
}

output "drainer_function_arn" {
  description = "드레이너 Lambda 함수 ARN이다."
  value       = aws_lambda_function.drainer.arn
}

output "drainer_role_arn" {
  description = "드레이너 Lambda 실행 역할 ARN이다."
  value       = aws_iam_role.drainer.arn
}
