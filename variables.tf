variable "aws_region" {
  type = string
}

variable "name" {
  type    = string
  default = "urlshortener"
}

# TLS 인증서를 발급할 루트 도메인이다. Porkbun에서 구입/관리하는 도메인을 넣는다.
variable "domain_name" {
  description = "ACM 인증서를 발급할 루트 도메인 (예: jhan.cc)."
  type        = string
}

# Porkbun API 자격증명이다. 콘솔에서 발급하며 대상 도메인의 API Access를 켜야 한다.
# 민감값이므로 코드/문서에 남기지 않고 terraform.tfvars 또는 환경변수로 주입한다.
variable "porkbun_api_key" {
  description = "Porkbun API 키 (pk1_...)."
  type        = string
  sensitive   = true
}

variable "porkbun_secret_key" {
  description = "Porkbun 시크릿 키 (sk1_...)."
  type        = string
  sensitive   = true
}

# CodeDeploy 배포 롤백/실패 및 알람을 통지받을 운영 담당자 이메일 목록이다.
# 각 주소로 SNS 구독이 생성되며, 수신자는 확인(confirm) 메일 링크를 눌러야 알림을 받는다.
# 민감하지는 않으나 운영 정보이므로 terraform.tfvars 등 로컬 변수로 주입한다.
variable "deploy_notification_emails" {
  description = "CodeDeploy 롤백/실패 및 알람 통지를 받을 이메일 목록."
  type        = list(string)
  default     = []
}

# CI 워크플로의 매트릭스 핸들러 이름이다. lambda_deploy_map 출력의 최상위 키로 쓰인다.
# CI(affected.mjs)가 산출하는 핸들러 이름과 정확히 일치해야 한다.
# 함수 이름(urlshortener-url 등)과 다른, 핸들러 식별자(핸들러 파일 베이스명)다.
variable "url_handler_key" {
  description = "URL 함수에 대응하는 CI 핸들러 이름(예: urls)."
  type        = string
  default     = "urls"
}

variable "auth_handler_key" {
  description = "auth 함수에 대응하는 CI 핸들러 이름(예: auth)."
  type        = string
  default     = "auth"
}