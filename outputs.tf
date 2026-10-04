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
