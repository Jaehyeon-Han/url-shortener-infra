variable "name" {
  description = "리소스 이름 접두사 (예: urlshortener). 태그 등에 사용한다."
  type        = string
}

variable "domain_name" {
  description = "인증서를 발급할 루트 도메인이다. Porkbun에서 관리하는 도메인이어야 한다 (예: jhan.cc)."
  type        = string
}

# 인증서가 함께 커버할 추가 도메인(SAN) 목록이다.
# 모듈은 서브도메인을 조립하지 않으며, 호출 측이 완전한 도메인 문자열을 넘긴다 (예: ["auth.jhan.cc"]).
# 각 SAN도 domain_validation_options에 포함되어 검증 CNAME이 자동으로 추가된다.
variable "subject_alternative_names" {
  description = "인증서에 포함할 추가 도메인(SAN) 목록이다. 완전한 도메인 문자열을 넘긴다 (예: [\"auth.jhan.cc\"])."
  type        = list(string)
  default     = []
}
