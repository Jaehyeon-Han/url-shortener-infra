variable "name" {
  description = "함수 이름. 리소스 이름과 로그 그룹 경로에 사용한다 (예: urlshortener-auth)."
  type        = string
}

variable "runtime" {
  description = "Lambda 런타임. Node.js 기반이다."
  type        = string
  default     = "nodejs24.x"
}

variable "handler" {
  description = "핸들러 진입점. \"<zip 내부 경로>.<export명>\" 형식이다 (예: index.handler, handlers/auth.handler). 파일은 .mjs로 가정한다."
  type        = string

  validation {
    # 반드시 "<파일경로>.<export명>" 형태여야 플레이스홀더 경로/이름을 파싱할 수 있다.
    condition     = can(regex("^.+\\.[^.]+$", var.handler))
    error_message = "handler는 \"<파일경로>.<export명>\" 형식이어야 한다 (예: handlers/auth.handler)."
  }
}

variable "memory_size" {
  description = "함수 메모리(MB)."
  type        = number
  default     = 128
}

variable "timeout" {
  description = "함수 타임아웃(초)."
  type        = number
  default     = 10
}

variable "environment" {
  description = "함수에 주입할 환경 변수 맵."
  type        = map(string)
  default     = {}
}

variable "artifact_bucket" {
  description = "코드 zip이 저장된 아티팩트 S3 버킷 이름. artifacts 모듈의 bucket_id를 넘긴다."
  type        = string
}

variable "s3_key" {
  description = "아티팩트 버킷 내 코드 zip의 키 (예: auth/function.zip). 플레이스홀더 zip도 이 키로 업로드된다."
  type        = string
}

variable "s3_object_version" {
  description = <<-EOT
    참조할 S3 객체 버전 ID(선택, 기본 null).
    null이면 해당 s3_key의 최신 버전을 참조한다. CI가 같은 key를 덮어쓰는 방식에서는 null이 단순하며 권장값이다.
    아티팩트 버킷은 버저닝이 켜져 있으므로, 특정 코드 버전으로 고정/롤백해야 할 때만 버전 ID를 명시한다.
    최초 코드 반영은 CI의 update-function-code가 담당하며, 함수는 ignore_changes로 이 속성 변화를 무시한다.
  EOT
  type        = string
  default     = null
}

variable "inline_policy_json" {
  description = "함수 실행 역할에 인라인으로 부착할 IAM 정책 JSON(선택). 호출 측에서 aws_iam_policy_document.json 등을 넘긴다."
  type        = string
  default     = null
}

variable "log_retention_days" {
  description = "CloudWatch 로그 보존 기간(일)."
  type        = number
  default     = 14
}
