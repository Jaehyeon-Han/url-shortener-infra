# UrlShortener 단일 테이블 (싱글 테이블 디자인)
#
# 복합 기본키 PK/SK + GSI1(소유자별 목록), GSI2(상태별 운영/악성 URL 대비).
# 하나의 테이블에 URL/소유자/통계 등 여러 엔티티를 담는다. 접근 패턴은
# PK/SK 조합과 두 GSI로 커버한다.
#
# 과금: on-demand(PAY_PER_REQUEST) — 트래픽 변동이 크고 핫패스가 리다이렉트라
#       용량 예측이 어려우므로 온디맨드가 운영 단순하다.
# PITR: 기본 활성(var.point_in_time_recovery_enabled) — 원시 클릭/카운터 보호.
# Streams: 기본 비활성. 추후 리다이렉트 동기 집계 -> Streams 집계로 전환할 때
#          var.stream_enabled=true 로만 바꾸면 되며(필요 시 stream_view_type 조정),
#          테이블 키/인덱스/아이템 스키마 변경은 필요 없다(README 전환 절차 참고).

resource "aws_dynamodb_table" "this" {
  name         = var.name
  billing_mode = "PAY_PER_REQUEST"

  # 테이블 기본키: PK(파티션) + SK(정렬).
  # 참고: provider가 key_schema 블록을 안내하지만, 현재 고정한 AWS provider(~> 6.0)
  #       버전에서는 테이블 레벨 key_schema를 아직 지원하지 않아 hash_key/range_key를 쓴다.
  #       (deprecation 경고가 뜨지만 현재 버전에서 유효한 유일한 방식이다.)
  hash_key  = "PK"
  range_key = "SK"

  # 키/인덱스에서 참조하는 키 속성만 정의한다(키가 아닌 속성은 정의하지 않는다).
  attribute {
    name = "PK"
    type = "S"
  }
  attribute {
    name = "SK"
    type = "S"
  }

  # GSI1: 소유자별 URL 목록 (최신순)
  attribute {
    name = "GSI1PK"
    type = "S"
  }
  attribute {
    name = "GSI1SK"
    type = "S"
  }

  # GSI2: 상태별 조회 (운영/악성 URL 워크플로 대비)
  attribute {
    name = "GSI2PK"
    type = "S"
  }
  attribute {
    name = "GSI2SK"
    type = "S"
  }

  global_secondary_index {
    name            = "GSI1"
    hash_key        = "GSI1PK"
    range_key       = "GSI1SK"
    projection_type = "ALL"
  }

  global_secondary_index {
    name            = "GSI2"
    hash_key        = "GSI2PK"
    range_key       = "GSI2SK"
    projection_type = "ALL"
  }

  point_in_time_recovery {
    enabled = var.point_in_time_recovery_enabled
  }

  # Streams는 기본 비활성이다. 활성화 시에만 view type이 의미를 가지므로,
  # 비활성일 때는 null로 둬서 불필요한 변경(diff)이 생기지 않게 한다.
  stream_enabled   = var.stream_enabled
  stream_view_type = var.stream_enabled ? var.stream_view_type : null

  tags = {
    Project   = var.name
    ManagedBy = "terraform"
  }
}
