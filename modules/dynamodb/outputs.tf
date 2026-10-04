output "table_name" {
  description = "DynamoDB 테이블 이름이다. URL/통계 Lambda의 환경변수로 주입한다."
  value       = aws_dynamodb_table.this.name
}

# IAM 정책에서 GSI까지 쿼리하려면 이 ARN과 함께 "<table_arn>/index/*" 를 대상 리소스로 넣어야 한다.
output "table_arn" {
  description = "DynamoDB 테이블 ARN이다. IAM 정책의 대상 리소스로 사용한다(GSI 쿼리 시 index/* 조합 필요)."
  value       = aws_dynamodb_table.this.arn
}

output "gsi1_name" {
  description = "GSI1(소유자별 목록) 인덱스 이름이다."
  value       = "GSI1"
}

output "gsi2_name" {
  description = "GSI2(상태별 조회) 인덱스 이름이다."
  value       = "GSI2"
}
