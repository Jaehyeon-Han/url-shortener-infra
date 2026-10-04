variable "name" {
  description = "리소스 이름 접두사이자 테이블 이름이다 (예: urlshortener). 단일 테이블이므로 접미사 없이 그대로 테이블명으로 쓴다."
  type        = string
}

variable "point_in_time_recovery_enabled" {
  description = "PITR(Point-in-Time Recovery) 활성 여부다. 원시 클릭/카운터 보호를 위해 기본값은 true다."
  type        = bool
  default     = true
}

variable "stream_enabled" {
  description = "DynamoDB Streams 활성 여부다. 추후 Streams 기반 집계로 전환할 때 true로 바꾼다. 기본값은 false다."
  type        = bool
  default     = false
}

variable "stream_view_type" {
  description = "Streams 활성 시 스트림에 기록할 이미지 유형이다. stream_enabled=true일 때만 적용된다. 기본값은 NEW_IMAGE다."
  type        = string
  default     = "NEW_IMAGE"
}
