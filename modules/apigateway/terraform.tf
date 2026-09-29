terraform {
  required_version = ">= 1.10.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
    # 커스텀 도메인(auth.<domain>)을 API Gateway regional target으로 가리키는 CNAME을
    # Porkbun DNS에 생성한다. provider 설정은 루트에서 정의해 이 모듈로 전달한다.
    porkbun = {
      source = "jianyuan/porkbun"
    }
  }
}
