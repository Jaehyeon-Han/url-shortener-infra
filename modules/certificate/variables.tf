variable "name" {
  description = "리소스 이름 접두사 (예: urlshortener). 태그 등에 사용한다."
  type        = string
}

variable "domain_name" {
  description = "인증서를 발급할 루트 도메인이다. Porkbun에서 관리하는 도메인이어야 한다 (예: jhan.cc)."
  type        = string
}
