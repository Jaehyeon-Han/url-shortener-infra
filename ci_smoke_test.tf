# CI/CD 파이프라인 스모크 테스트용 임시 리소스다.
# 운영 리소스와 완전히 분리된 독립 IAM role이며, 어떤 정책도 붙이지 않고
# 어디에도 attach하지 않는다. 사용처가 없어 생성/삭제가 운영에 전혀 영향을 주지 않는다.
# plan/apply 동작 확인이 끝나면 이 파일을 삭제한다(= destroy 1건).

# 신뢰 정책: EC2 서비스 principal만 둔다. 연결된 권한이 0이라 실제로 쓸 수 없는 빈 role이다.
data "aws_iam_policy_document" "ci_smoke_assume" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "ci_smoke_test" {
  name               = "${var.name}-ci-smoke-test"
  description        = "Temporary no-op role to smoke-test the Terraform CI/CD pipeline."
  assume_role_policy = data.aws_iam_policy_document.ci_smoke_assume.json

  tags = {
    Purpose = "ci-smoke-test"
  }
}
