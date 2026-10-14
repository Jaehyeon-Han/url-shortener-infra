variable "name" {
  description = "리소스 이름 접두사다 (예: urlshortener-auth). API/스테이지/로그 그룹 이름에 사용한다."
  type        = string
}

# --- Lambda 통합 대상 ---

variable "lambda_invoke_arn" {
  description = "통합할 Lambda 함수의 invoke ARN이다. lambda 모듈의 invoke_arn 출력을 넘긴다."
  type        = string
}

variable "lambda_function_name" {
  description = "호출 권한(aws_lambda_permission)을 부여할 Lambda 함수 이름이다. lambda 모듈의 function_name 출력을 넘긴다."
  type        = string
}

variable "lambda_qualifier" {
  description = <<-EOT
    Lambda 호출 권한을 한정할 qualifier다(별칭 이름 또는 버전).
    Alias를 통해 호출하는 경우 lambda 모듈의 alias_name(예: live)을 넘긴다.
    null(기본)이면 비한정으로 권한을 부여한다($LATEST 직접 호출 구조와 하위 호환).
    주의: integration_uri(lambda_invoke_arn)가 Alias를 가리키면 이 값도 해당 alias로
    맞춰야 호출 권한이 일치해 403이 발생하지 않는다.
  EOT
  type        = string
  default     = null
}

# --- 라우트 ---

variable "route_keys" {
  description = "API에 등록할 라우트 키 목록이다 (\"METHOD /path\" 형식). 각 라우트는 동일한 Lambda 통합으로 연결된다. authorizer 없이 공개로 노출된다."
  type        = list(string)
  default = [
    "POST /auth/signup",
    "POST /auth/confirm",
    "POST /auth/resend",
    "POST /auth/login",
    "POST /auth/refresh",
    "POST /auth/logout",
  ]
}

# --- JWT authorizer (선택) ---

variable "jwt_issuer" {
  description = "JWT authorizer의 issuer URL이다(스킴 https:// 포함). null이면 authorizer를 만들지 않는다(기본 공개 API). Cognito는 \"https://<user_pool_endpoint>\"다."
  type        = string
  default     = null
}

variable "jwt_audiences" {
  description = "JWT authorizer가 허용할 audience 목록이다. Cognito App Client ID를 넣는다. jwt_issuer가 설정될 때만 의미가 있다."
  type        = list(string)
  default     = []
}

variable "protected_route_keys" {
  description = "JWT authorizer를 적용할 보호 라우트 키 목록이다 (\"METHOD /path\" 형식). jwt_issuer가 설정되어야 하며, 각 라우트는 Authorization 헤더의 JWT 검증을 거친다."
  type        = list(string)
  default     = []
}

# --- CORS ---

variable "cors_allow_origins" {
  description = "CORS 허용 Origin 목록이다. 기본은 모든 Origin 허용(\"*\")이다. 운영에서는 프런트엔드 도메인으로 좁힌다."
  type        = list(string)
  default     = ["*"]
}

variable "cors_allow_methods" {
  description = "CORS 허용 HTTP 메서드 목록이다."
  type        = list(string)
  default     = ["POST", "OPTIONS"]
}

variable "cors_allow_headers" {
  description = "CORS 허용 요청 헤더 목록이다."
  type        = list(string)
  default     = ["content-type", "authorization"]
}

# --- 스테이지 / 로그 ---

variable "log_retention_days" {
  description = "API Gateway 액세스 로그 그룹의 보존 기간(일)이다."
  type        = number
  default     = 14
}

# --- 커스텀 도메인 ---

variable "domain_name" {
  description = "커스텀 도메인 전체 이름이다 (예: auth.jhan.cc). certificate가 이 도메인을 커버해야 한다."
  type        = string
}

variable "certificate_arn" {
  description = "커스텀 도메인에 연결할, 검증 완료된 ACM 인증서 ARN이다. certificate 모듈의 certificate_arn을 넘긴다."
  type        = string
}

variable "porkbun_domain" {
  description = "Porkbun에서 관리하는 루트 도메인이다 (예: jhan.cc). CNAME subdomain 계산에 사용한다."
  type        = string
}
