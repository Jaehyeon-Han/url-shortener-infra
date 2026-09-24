# Lambda 배포 아티팩트(zip)를 보관하는 S3 버킷이다.
# CI/CD가 빌드한 zip을 이 버킷에 업로드하고, Lambda 함수는 이 버킷을 코드 소스로 참조한다.

resource "aws_s3_bucket" "this" {
  bucket = "${var.name}-artifacts"
}

# 코드 버전 추적과 롤백을 위해 버저닝을 활성화한다.
# CI가 update-function-code로 갱신하거나 s3_object_version으로 특정 버전을 고정할 때 모두 유용하다.
resource "aws_s3_bucket_versioning" "this" {
  bucket = aws_s3_bucket.this.id

  versioning_configuration {
    status = "Enabled"
  }
}

# 아티팩트 버킷은 외부에 공개되면 안 되므로 퍼블릭 접근을 전면 차단한다.
resource "aws_s3_bucket_public_access_block" "this" {
  bucket = aws_s3_bucket.this.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# 저장 데이터를 기본 암호화(SSE-S3, AES256)한다.
resource "aws_s3_bucket_server_side_encryption_configuration" "this" {
  bucket = aws_s3_bucket.this.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}
