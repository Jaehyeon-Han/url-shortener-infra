# dynamodb 모듈

URL 단축 서비스의 데이터를 담는 **단일 테이블(싱글 테이블 디자인)** 을 만드는 모듈이다.

하나의 DynamoDB 테이블에 URL, 소유자, 통계 등 여러 엔티티를 복합 기본키(PK/SK)로 담고,
두 개의 GSI로 추가 접근 패턴을 커버한다.

## 키 스키마

| 키 | 속성 | 용도 |
|---|---|---|
| 기본키 | `PK`(해시) + `SK`(레인지) | 엔티티 식별 및 아이템 조회 |
| GSI1 | `GSI1PK`(해시) + `GSI1SK`(레인지) | 소유자별 URL 목록(최신순) |
| GSI2 | `GSI2PK`(해시) + `GSI2SK`(레인지) | 상태별 조회(운영/악성 URL 워크플로 대비) |

두 GSI 모두 `projection_type = ALL`이라 인덱스 조회만으로 전체 속성을 읽을 수 있다.

## 설계 근거

- **과금(PAY_PER_REQUEST / 온디맨드)**: 트래픽 변동이 크고 핫패스가 리다이렉트라
  용량 예측이 어렵다. 온디맨드가 운영이 단순하고 스파이크에 강하다.
- **PITR(Point-in-Time Recovery)**: 기본 활성이다. 원시 클릭/카운터 데이터를
  실수/악성 변경으로부터 보호한다.
- **Streams**: 기본 비활성이다. 지금은 리다이렉트 시 동기적으로 집계한다.

## Streams 전환 절차

추후 집계를 Streams 기반(비동기)으로 바꿀 때는 **아이템/키/인덱스 스키마 변경 없이**
변수만 조정하면 된다.

1. 모듈 호출에 `stream_enabled = true`를 넣는다.
2. 필요하면 `stream_view_type`을 조정한다(기본 `NEW_IMAGE`).
3. `terraform apply`한다. 테이블 교체(재생성)는 발생하지 않는다.

비활성 상태에서는 `stream_view_type`이 `null`로 처리되어 불필요한 diff가 생기지 않는다.

## Inputs

| 이름 | 설명 | 타입 | 기본값 | 필수 |
|---|---|---|---|---|
| `name` | 리소스 이름 접두사이자 테이블 이름(예: `urlshortener`). | `string` | — | 예 |
| `point_in_time_recovery_enabled` | PITR 활성 여부. | `bool` | `true` | 아니오 |
| `stream_enabled` | DynamoDB Streams 활성 여부. | `bool` | `false` | 아니오 |
| `stream_view_type` | Streams 활성 시 기록 이미지 유형(`stream_enabled=true`일 때만 적용). | `string` | `"NEW_IMAGE"` | 아니오 |

## Outputs

| 이름 | 설명 |
|---|---|
| `table_name` | 테이블 이름. URL/통계 Lambda의 환경변수로 주입한다. |
| `table_arn` | 테이블 ARN. IAM 정책 대상 리소스로 사용한다(GSI 쿼리 시 `<table_arn>/index/*` 조합 필요). |
| `gsi1_name` | GSI1(소유자별 목록) 인덱스 이름. |
| `gsi2_name` | GSI2(상태별 조회) 인덱스 이름. |

## 향후 배선 TODO

- 단축/리다이렉트/통계 Lambda 추가 시 `table_name`을 환경변수로 주입한다.
- 해당 Lambda 실행 역할 IAM 정책에 `table_arn`과 `table_arn + "/index/*"`를 대상으로 추가한다.
