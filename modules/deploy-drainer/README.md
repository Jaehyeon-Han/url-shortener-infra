# deploy-drainer 모듈

비동기 배포 드레이너다. 배포 트리거를 CI에서 떼어 이벤트 기반 Lambda로 옮겨, 배포가 겹쳐도
CodeDeploy의 "배포 그룹당 활성 배포 1개" 제약에 걸려 실패하지 않도록 큐로 직렬화한다.

## 목적 / 배경

- CodeDeploy는 배포 그룹당 활성 배포가 1개뿐이라, 진행 중 배포가 있으면 새 `CreateDeployment`가
  `DeploymentLimitExceededException`으로 거부된다. 진행 중 배포를 자동으로 덮어쓰는 기능은 없다.
- 기존에는 CI(`deploy.mjs`)가 직접 `CreateDeployment`를 호출해 이 충돌을 처리할 수 없었다.
- 해법: CI는 `DeployQueue`에 "원하는 버전(desiredVersion)"만 적재(enqueue)하고 즉시 종료한다.
  드레이너 Lambda가 큐를 **조건부 락**으로 소비해 배포 그룹당 1개 제약을 지켜 순차(coalescing) 배포한다.
  유실 0 + 러너 대기 0 + 완전 비동기를 동시에 달성한다.

설계 전체(상태 머신·불변식·계약)는 리포 루트 `async-deploy-drainer.md`가 권위 있는 문서다.

## 구성 요소

- `aws_dynamodb_table.deploy_queue` — 함수당 1행(PK=`FN#<function>`). 한 행이 "큐(desiredVersion) +
  분산 락(inFlightDeploymentId) + 멱등 저장소" 세 역할을 한다. Streams(`NEW_AND_OLD_IMAGES`) 활성, TTL 속성
  `lockExpiresAt`(좀비 락 안전망).
- `aws_lambda_function.drainer` — 핸들러 코드를 `archive_file`로 자체 패키징(CI 비의존). `src/`의
  `decide.mjs`(순수 결정) + `normalize.mjs`(이벤트 정규화) + `drainer.mjs`(오케스트레이션, SDK 비의존)
  + `index.mjs`(실제 SDK 배선)로 구성된다.
- 트리거 A: `aws_lambda_event_source_mapping` — DeployQueue Streams → 드레이너(enqueue).
- 트리거 B: `aws_cloudwatch_event_rule`/`_target` + `aws_lambda_permission` — CodeDeploy 상태변경
  (SUCCESS/FAILURE/STOP) → 드레이너(dequeue). 이 트리거가 없으면 큐가 비워지지 않는다.
- 드레이너 IAM 역할 — 최소 권한 인라인 정책(codedeploy 배포, lambda:GetAlias, cloudwatch:PutMetricAlarm,
  DeployQueue item/stream, CloudWatch Logs).

## 알람 갱신 소유권

`executed_version` 모드(=url, Canary) 함수는 드레이너가 `CreateDeployment` 직전 `PutMetricAlarm`으로
신버전(ExecutedVersion) 기준 롤백 알람을 갱신한다. 이 소유권이 기존 CI에서 드레이너로 이전됐다.
`alias` 모드(=auth, AllAtOnce)는 알람 갱신이 없다(Terraform 정적 알람 사용).

## 롤백/중지 정책 (FAILURE·STOP)

`deployment-finished` 이벤트의 `state`를 구분해 처리한다.

- **SUCCESS**: 락 해제 + `deployedVersion ← 방금 끝난 버전`. 큐에 더 새 목표가 있으면 이어서 다음 배포.
- **FAILURE/STOP**: 락만 해제한다. **`deployedVersion`을 올리지 않고**(실패 버전을 성공으로 기록하지 않음)
  **자동 재배포도 하지 않는다**(dequeue 재개 금지). `desiredVersion`은 보존되므로, 이후 새 push(enqueue)가
  오면 그때 최신 버전으로 배포가 재개된다. 관측용으로 `lastDeployState`/`lastFailedVersion`을 아이템에 남긴다.
  STOP은 FAILURE와 동일하게 취급한다(사람 개입이든 알람이든 "성공 아님"이므로 안전 동작이 같다).

> CodeDeploy의 알람 기반 자동 롤백은 원 배포를 **FAILURE**로 보고한다(STOP 아님). STOP은 주로
> 운영자의 수동 중지다. 둘 다 성공이 아니므로 동일하게 "버전 동결 + 재배포 금지"로 다룬다.
>
> 주의: FAILURE 후 그 함수에 다시는 push가 없으면 마지막 목표(`desiredVersion`)는 미배포로 남는다.
> 이는 "실패했으니 사람이 고쳐서 다시 올릴 때까지 기다린다"는 의도된 동작이며, FAILURE는 SNS로 통지된다.

## 단위 테스트

핵심 로직은 AWS 호출과 분리된 순수 함수로 두고 `node:test`로 불변식을 증명한다.

```bash
node --test "modules/deploy-drainer/src/*.test.mjs"
```

- `decide.test.mjs` — 네 불변식(멱등성/경쟁/수렴/dequeue).
- `normalize.test.mjs` — 이벤트 정규화 + 설정 역참조 + 알람/appspec 파라미터 구성.
- `drainer.test.mjs` — 오케스트레이션 순서(락획득→알람→GetAlias→CreateDeployment) + 경쟁/멱등 흡수.

## Inputs

| 이름 | 타입 | 기본값 | 설명 |
|---|---|---|---|
| `name` | string | — | 리소스 이름 접두사(예: `urlshortener`). `${name}-deploy-queue`/`${name}-deploy-drainer`. |
| `deploy_config` | any | — | `FN#<function>`→배포 설정 맵. 루트에서 lambda/codedeploy output을 조립해 주입. `DEPLOY_CONFIG` env(JSON). |
| `lock_ttl_seconds` | number | `2700` | 락 TTL(초). 배포 최대시간 + 여유(약 45분). 좀비 락 안전망. |
| `log_retention_days` | number | `14` | 드레이너 로그 보존 기간(일). |
| `memory_size` | number | `128` | 드레이너 메모리(MB). |
| `timeout` | number | `60` | 드레이너 타임아웃(초). |
| `runtime` | string | `nodejs24.x` | 드레이너 런타임. |
| `stream_batch_size` | number | `1` | 트리거 A 배치 크기. enqueue는 저빈도라 작게 둔다. |
| `tags` | map(string) | `{}` | 공통 태그. |

`deploy_config` 각 항목의 필드: `function`, `alias`, `codedeploy_app`, `codedeploy_group`,
`errors_alarm_mode`. `executed_version` 모드는 추가로 `errors_alarm_name`, `notify_topic_arn`,
`error_namespace`, `error_metric_name`, `alarm_threshold`, `alarm_period`.

## Outputs

| 이름 | 설명 |
|---|---|
| `deploy_queue_table_name` | DeployQueue 테이블 이름(CI `DEPLOY_QUEUE_TABLE`). |
| `deploy_queue_table_arn` | DeployQueue 테이블 ARN(CI OIDC 역할 `dynamodb:UpdateItem` 대상). |
| `deploy_queue_stream_arn` | DeployQueue Streams ARN(트리거 A). |
| `drainer_function_name` | 드레이너 Lambda 함수 이름. |
| `drainer_function_arn` | 드레이너 Lambda 함수 ARN. |
| `drainer_role_arn` | 드레이너 실행 역할 ARN. |

## 리포 간 계약 (CI 레포가 적용)

이 레포는 CI 레포를 소유하지 않는다. 비동기 전환에 맞춰 CI 레포에서 아래를 적용한다(설계 9절).

- CI(`deploy.mjs`)는 S3 업로드 + 버전 publish 후 DeployQueue에 `desiredVersion`만 enqueue한다
  (`UpdateItem Key={PK:"FN#<function>"} SET desiredVersion, desiredS3VersionId, updatedAt`).
  `inFlightDeploymentId`/`deployedVersion`/`lockExpiresAt`은 건드리지 않는다.
- CI OIDC 배포 역할에서 `codedeploy:*`·`cloudwatch:PutMetricAlarm`·`lambda:GetAlias`를 제거하고
  `dynamodb:UpdateItem`(DeployQueue 한정)을 추가한다. `s3:PutObject`·`lambda:UpdateFunctionCode`는 유지.
