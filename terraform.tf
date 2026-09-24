terraform {
  required_version = ">= 1.10.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
    # lambda 모듈이 플레이스홀더 zip을 만들 때 사용한다.
    archive = {
      source  = "hashicorp/archive"
      version = "~> 2.0"
    }
  }

  # State는 bootstrap 스택이 만든 S3 버킷에 저장한다.
  # 버킷명에는 account_id가 포함되므로 하드코딩하지 않고 init 시 -backend-config로 주입한다.
  #   terraform init -backend-config="bucket=<bootstrap의 tfstate_bucket 출력값>"
  # 또는 backend.hcl 파일 사용:
  #   terraform init -backend-config=backend.hcl
  # 잠금은 DynamoDB 대신 S3 네이티브 잠금(use_lockfile)을 사용한다. (Terraform 1.10+)
  backend "s3" {
    key          = "root/terraform.tfstate"
    region       = "ap-northeast-2"
    encrypt      = true
    use_lockfile = true
  }
}