variable "name" {
  description = "리소스 이름 접두사다 (예: urlshortener). DeployQueue 테이블/드레이너 함수/역할/로그그룹/트리거 이름에 '<name>-*' 형태로 쓴다."
  type        = string
}

variable "deploy_config" {
  description = <<-EOT
    드레이너가 배포를 수행하기 위한 함수별 설정 맵이다. 키는 "FN#<function>" 형태이며(DeployQueue PK와 동일),
    값은 아래 필드를 가진다. 루트에서 lambda/codedeploy 모듈의 output을 모아 조립해 주입한다.
    드레이너 Lambda에는 이 맵이 DEPLOY_CONFIG 환경변수(JSON)로 전달된다.

    공통:
      function           Lambda 함수명
      alias              배포 alias (기본 live)
      codedeploy_app     CodeDeploy 애플리케이션명
      codedeploy_group   CodeDeploy 배포 그룹명 (deployment-finished 이벤트의 역참조 키)
      errors_alarm_mode  "executed_version" | "alias"

    executed_version 모드(=url, Canary)에서만 필요(드레이너가 CreateDeployment 직전 PutMetricAlarm로 갱신):
      errors_alarm_name  갱신 대상 알람명
      notify_topic_arn   SNS 통지 토픽 ARN
      error_namespace    커스텀 메트릭 네임스페이스
      error_metric_name  커스텀 지표명
      alarm_threshold    임계값(기본 3)
      alarm_period       평가 주기 초(기본 180)
  EOT
  # 함수마다 필요한 키가 달라(alias 모드는 알람 키 생략) 객체 형태가 균일하지 않다.
  # map(any)는 모든 원소 타입이 같아야 해 이 경우 타입 에러가 나므로, any로 받아 유연하게 조립한다.
  # 모듈은 이 값을 jsonencode해 DEPLOY_CONFIG env로 넘기고, values()/for로 ARN을 구성한다
  # (values()는 객체에도 동작한다).
  type = any
}

variable "lock_ttl_seconds" {
  description = <<-EOT
    락(inFlightDeploymentId) TTL(초)이다. 배포 최대시간(url Canary ~30분) + 여유로 약 45분(2700초)을 기본으로 둔다.
    드레이너가 CreateDeployment 후 죽어 dequeue 이벤트를 못 받으면 락이 영구 점유되는데, 이 TTL이 만료되면
    다음 드레이너(또는 enqueue 이벤트)가 좀비 락을 탈취해 재평가한다. EventBridge 이벤트 유실 대비 안전망이다.
  EOT
  type        = number
  default     = 2700
}

variable "log_retention_days" {
  description = "드레이너 Lambda의 CloudWatch 로그 보존 기간(일)이다."
  type        = number
  default     = 14
}

variable "memory_size" {
  description = "드레이너 Lambda 메모리(MB)다. AWS SDK 호출 위주라 128로 충분하다."
  type        = number
  default     = 128
}

variable "timeout" {
  description = "드레이너 Lambda 타임아웃(초)다. GetAlias/CreateDeployment 등 몇 번의 API 호출만 하므로 넉넉히 둔다."
  type        = number
  default     = 60
}

variable "runtime" {
  description = "드레이너 Lambda 런타임이다. 기존 함수와 동일한 Node.js 런타임을 쓴다."
  type        = string
  default     = "nodejs24.x"
}

variable "stream_batch_size" {
  description = "DeployQueue Streams 이벤트 소스 매핑(트리거 A)의 배치 크기다. enqueue는 저빈도라 작게 둔다."
  type        = number
  default     = 1
}

variable "tags" {
  description = "리소스에 부가할 공통 태그다."
  type        = map(string)
  default     = {}
}
