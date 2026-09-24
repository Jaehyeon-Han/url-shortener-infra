terraform {
  required_version = ">= 1.10.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
    # 플레이스홀더 zip 생성에 사용한다.
    archive = {
      source  = "hashicorp/archive"
      version = "~> 2.0"
    }
  }
}
