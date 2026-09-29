terraform {
  required_version = ">= 1.10.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
    # ACM DNS 검증 CNAME을 Porkbun DNS에 생성한다.
    # provider 설정은 루트에서 정의해 이 모듈로 전달한다.
    porkbun = {
      source = "jianyuan/porkbun"
    }
  }
}
