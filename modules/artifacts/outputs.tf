output "bucket_id" {
  description = "아티팩트 S3 버킷 이름. Lambda 모듈의 artifact_bucket 입력으로 사용한다."
  value       = aws_s3_bucket.this.id
}

output "bucket_arn" {
  description = "아티팩트 S3 버킷 ARN. IAM 정책에서 대상 리소스로 사용한다."
  value       = aws_s3_bucket.this.arn
}
