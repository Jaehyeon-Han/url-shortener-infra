terraform {
  required_version = ">= 1.10.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
    # 드레이너 핸들러 소스(src/*.mjs)를 zip으로 패키징하는 데 사용한다.
    archive = {
      source  = "hashicorp/archive"
      version = "~> 2.0"
    }
  }
}
