# 검증까지 완료된 인증서의 ARN이다.
# aws_acm_certificate_validation을 참조하므로, 이 값이 나오면 인증서가 검증(ISSUED)된 상태임을 보장한다.
output "certificate_arn" {
  description = "검증 완료된 ACM 인증서 ARN. API Gateway/ALB 등에 연결할 때 사용한다."
  value       = aws_acm_certificate_validation.this.certificate_arn
}

output "domain_name" {
  description = "인증서가 발급된 도메인."
  value       = aws_acm_certificate.this.domain_name
}
