variable "name" {
  description = "리소스 이름 접두사 (예: urlshortener)"
  type        = string
}

variable "deletion_protection" {
  description = "User Pool 삭제 방지. 운영에서는 true."
  type        = bool
  default     = true
}

variable "access_token_validity_hours" {
  description = "Access 토큰 유효기간(시간)"
  type        = number
  default     = 1
}

variable "id_token_validity_hours" {
  description = "ID 토큰 유효기간(시간)"
  type        = number
  default     = 1
}

variable "refresh_token_validity_days" {
  description = "Refresh 토큰 유효기간(일)"
  type        = number
  default     = 30
}
