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