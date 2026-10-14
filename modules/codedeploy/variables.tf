variable "name" {
  description = "리소스 이름 접두사다 (예: urlshortener-url). CodeDeploy 앱/배포그룹/역할/SNS/알람 이름에 사용한다."
  type        = string
}

# --- 배포 대상 (Lambda Alias) ---

variable "lambda_function_name" {
  description = "트래픽 전환 대상 Lambda 함수 이름이다. Errors 알람 차원과 서비스 역할 권한에 사용한다."
  type        = string
}

variable "lambda_alias_name" {
  description = "CodeDeploy가 트래픽을 옮길 Lambda Alias 이름이다 (예: live). lambda 모듈의 alias_name과 일치해야 한다."
  type        = string
  default     = "live"
}

# --- 배포 전략 ---

variable "deployment_config_name" {
  description = <<-EOT
    CodeDeploy Lambda 배포 설정 이름이다. 사전 정의값을 사용한다.
    Canary: CodeDeployDefault.LambdaCanary10Percent30Minutes (10%를 30분 유지 후 전량 전환)
    즉시:   CodeDeployDefault.LambdaAllAtOnce
    선형:   CodeDeployDefault.LambdaLinear10PercentEvery1Minute 등
  EOT
  type        = string
  default     = "CodeDeployDefault.LambdaCanary10Percent30Minutes"
}

# --- 자동 롤백 알람 ---

variable "api_id" {
  description = "API Gateway(HTTP API v2)의 ID다. 5xx 상시 알람의 ApiId 차원에 사용한다."
  type        = string
}

variable "error_namespace" {
  description = <<-EOT
    자동 롤백 기준 "에러" 지표의 CloudWatch 네임스페이스다.
    기본은 "AWS/Lambda"(지표 Errors)다. 다만 핸들러가 try/catch로 예외를 삼키고 500을
    정상 리턴하는 구조라면 AWS/Lambda Errors가 0이라 롤백이 안 걸린다. 이 경우 핸들러가
    PutMetricData로 올리는 커스텀 네임스페이스(예: "UrlShortener/App")로 바꾼다.
    차원 구조(FunctionName + Resource + ExecutedVersion)는 네임스페이스와 무관하게 동일하다.
  EOT
  type        = string
  default     = "AWS/Lambda"
}

variable "error_metric_name" {
  description = "자동 롤백 기준 \"에러\" 지표명이다. 기본은 \"Errors\"다. 커스텀 메트릭이면 핸들러가 발행하는 지표명(예: \"HandlerErrors\")으로 바꾼다."
  type        = string
  default     = "Errors"
}

variable "errors_alarm_mode" {
  description = <<-EOT
    Lambda Errors 알람의 집계 차원 모드다. 자동 롤백의 정확도를 결정한다.
      - "executed_version": 신규 버전만 집계한다. 차원은 FunctionName + Resource(함수:alias) +
        ExecutedVersion(신버전 번호)이다. 버전 번호는 배포마다 바뀌므로 Terraform은 고정 이름의
        알람 "껍데기"만 만들고 dimensions/threshold/period 변화를 ignore_changes로 무시한다.
        CI가 배포 직전 PutMetricAlarm(upsert)으로 ExecutedVersion 차원을 신버전으로 갱신한다.
        Canary처럼 신/구가 공존하는 전환에서 신버전만 가드하려면 이 모드를 쓴다.
      - "alias": alias 경유 트래픽을 집계한다. 차원은 FunctionName + Resource(함수:alias)로 정적이다.
        전량 전환(AllAtOnce)이라 버전 분리가 불필요한 함수에 적합하다. CI 갱신이 필요 없다.
  EOT
  type        = string
  default     = "alias"

  validation {
    condition     = contains(["executed_version", "alias"], var.errors_alarm_mode)
    error_message = "errors_alarm_mode는 \"executed_version\" 또는 \"alias\"여야 한다."
  }
}

variable "alarm_period_seconds" {
  description = "롤백 알람 평가 주기(초)다."
  type        = number
  default     = 180
}

variable "alarm_threshold" {
  description = "롤백 알람 임계값이다. 주기당 지표 합(Sum)이 이 값 이상이면 ALARM이다."
  type        = number
  default     = 3
}

# --- SNS 알림 ---

variable "notification_emails" {
  description = <<-EOT
    배포 롤백/실패 및 알람을 통지받을 운영 담당자 이메일 목록이다.
    각 주소로 SNS 구독이 생성되며, 수신자는 확인(confirm) 메일의 링크를 눌러야 알림을 받는다.
    빈 목록이면 토픽만 만들고 구독은 생성하지 않는다(외부에서 구독 연결 가능).
  EOT
  type        = list(string)
  default     = []
}

variable "tags" {
  description = "리소스에 부가할 공통 태그다."
  type        = map(string)
  default     = {}
}
