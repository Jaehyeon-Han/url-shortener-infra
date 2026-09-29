# 아티팩트 버킷 이름이다. CI는 이 버킷에 코드 zip을 업로드한다.
output "artifact_bucket" {
  description = "Lambda 코드 zip을 업로드하는 아티팩트 S3 버킷 이름."
  value       = module.artifacts.bucket_id
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
