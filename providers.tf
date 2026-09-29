provider "aws" {
  region = var.aws_region
}

# Porkbun DNS를 조작하는 서드파티 provider다. 자격증명은 민감 변수로 주입한다.
# 주의: plan/apply가 실제 Porkbun DNS 레코드를 생성/삭제한다.
provider "porkbun" {
  api_key    = var.porkbun_api_key
  secret_key = var.porkbun_secret_key
}