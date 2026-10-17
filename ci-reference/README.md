# ci-reference

이 디렉토리는 **참고용**이다. 이 레포는 인프라(Terraform) 레포이고,
핸들러 코드와 CI 스크립트는 별도 **코드 레포**에 있다. 인프라와 CI의 계약을
한곳에 문서화해, 코드 레포에 복사·반영하는 것을 전제로 한다.

> **비동기 드레이너 전환**: 배포 트리거가 CI에서 드레이너 Lambda로 이동했다. CI는 이제
> `CreateDeployment`를 직접 호출하지 않고, DeployQueue에 `desiredVersion`만 enqueue하고 종료한다.
> 설계 전체는 리포 루트 `async-deploy-drainer.md`가 권위 있는 계약서다.

## 파일

- `deploy.mjs` — 코드 레포의 `scripts/deploy.mjs`가 될 참조 구현(enqueue-only). zip을 S3에 올리고
  버전을 publish한 뒤, DeployQueue에 `desiredVersion`만 기록(enqueue)하고 즉시 종료한다.
  실제 CodeDeploy 배포·알람 갱신·롤백은 드레이너 Lambda와 CodeDeploy가 담당한다.
  (리포 루트 `deploy.mjs`가 이 enqueue-only 축소판의 기준 구현이다.)
- `handler-metric.mjs` — 핸들러가 catch에서 커스텀 에러 지표를 발행하는 참조 구현.
  핸들러가 try/catch로 500을 정상 리턴해 AWS/Lambda Errors가 0이 되는 문제를 푼다.
- `cicd.yml` — GitHub Actions 워크플로의 "배포 경로" 스텝 참조본(enqueue-only).

## 왜 커스텀 메트릭인가

url/auth 핸들러는 예외를 try/catch로 잡아 500을 **정상 리턴**한다. 그러면 Lambda 런타임은
"성공"으로 집계해 `AWS/Lambda` `Errors` 지표가 0이 되고, 그 지표를 보는 CodeDeploy 롤백
알람은 영원히 울리지 않는다. 그래서 핸들러가 catch에서 `PutMetricData`로 커스텀 지표를
직접 발행하고, 롤백 알람은 그 지표를 본다.

- 네임스페이스: `UrlShortener/App`
- 지표명: `HandlerErrors`
- 차원: `FunctionName` + `Resource`(함수:alias) + `ExecutedVersion`(실행 버전)
  → `AWS/Lambda Errors`와 동일 차원 구조라 ExecutedVersion 동적 알람과 그대로 맞물린다.
- 발행 시점: 핸들러 catch(5xx 리턴 직전). 에러일 때만 발행되므로 평소엔 데이터가 없고,
  알람은 `treat_missing_data=notBreaching`이라 에러 없으면 OK다.

> 알람 갱신(PutMetricAlarm)의 **소유권은 드레이너로 이전**됐다. CI는 더 이상 알람을 갱신하지
> 않는다. 커스텀 메트릭을 **발행**하는 건 여전히 핸들러(함수 실행 역할)의 몫이다.

## 인프라 ↔ CI 계약

Terraform 루트 출력을 CI 변수에 매핑한다. 손으로 조립하지 말고 아래로 한 번에 뽑는다.

```bash
terraform output -raw lambda_deploy_map       # CI vars.LAMBDA_DEPLOY_MAP
terraform output -raw deploy_queue_table_name  # CI vars.DEPLOY_QUEUE_TABLE
```

`lambda_deploy_map`이 만드는 JSON(enqueue-only로 축소 — function/alias만):

```json
{
  "urls": { "function": "urlshortener-url", "alias": "live" },
  "auth": { "function": "urlshortener-auth", "alias": "live" }
}
```

codedeploy_app/group·알람 설정(errors_alarm_* 등)은 전부 드레이너(`modules/deploy-drainer`)로
이동했다. CI는 `function`/`alias`와 enqueue 대상 테이블명(`DEPLOY_QUEUE_TABLE`)만 알면 된다.

## 권한은 "두 역할"로 나뉜다

| 역할 | 누가 쓰나 | 필요 권한 | 관리 위치 |
|---|---|---|---|
| CI 배포 역할 | GitHub OIDC assume → deploy.mjs | `lambda:UpdateFunctionCode/PublishVersion`, `dynamodb:UpdateItem`(DeployQueue 한정), `s3:PutObject` | 코드 레포 OIDC 역할(이 레포 밖) |
| 함수 실행 역할 | Lambda 런타임 → 핸들러 PutMetricData | `cloudwatch:PutMetricData`(네임스페이스 `UrlShortener/App` 한정) | **이 레포 `modules/lambda`**(`metrics_namespace`로 부여) |
| 드레이너 역할 | 드레이너 Lambda | `codedeploy:CreateDeployment/GetDeployment/ListDeployments`, `lambda:GetAlias`, `cloudwatch:PutMetricAlarm`, DeployQueue item/stream | **이 레포 `modules/deploy-drainer`** |

- 비동기 전환으로 CI 배포 역할에서 `codedeploy:*`·`cloudwatch:PutMetricAlarm`·`lambda:GetAlias`를
  **제거**하고 `dynamodb:UpdateItem`(DeployQueue 한정)을 **추가**한다. `s3:PutObject`·
  `lambda:UpdateFunctionCode`·`lambda:PublishVersion`은 유지. (설계 9절 IAM 분담.)
- 함수 실행 역할의 PutMetricData는 `modules/lambda`가 `metrics_namespace` 설정 시 자동 부여한다.

## 전략 요약

- **url**: Canary 10%/30분. 롤백 기준은 커스텀 지표(`UrlShortener/App HandlerErrors`,
  ExecutedVersion=신버전) 알람. **드레이너**가 배포 직전 PutMetricAlarm으로 신버전 갱신. URL API 5xx는 상시 SNS 알람.
- **auth**: AllAtOnce. 롤백 기준은 커스텀 지표(alias 차원) 정적 알람. auth API 5xx는 상시 SNS 알람.
- CI는 두 함수 모두 publish → DeployQueue enqueue만 하고 종료한다(블로킹 없음). 배포 직렬화·전환·
  알람 갱신·롤백은 드레이너와 CodeDeploy가 수행한다.

## 전환 순서 주의 (깨짐 방지)

`lambda_deploy_map` 출력이 enqueue-only로 축소됐다(codedeploy_app/group·알람 키 제거). 따라서
**아직 구(舊) `deploy.mjs`(직접 CreateDeployment)를 쓰는 CI**가 있다면, 그 CI는 축소된 맵에서
필요한 키를 못 찾아 실패한다. 안전한 전환 순서는 다음과 같다.

1. 인프라 레포에 드레이너 모듈을 apply한다(DeployQueue/드레이너/트리거 생성).
2. 코드 레포의 `scripts/deploy.mjs`를 enqueue-only 버전으로 교체하고, CI 변수
   `LAMBDA_DEPLOY_MAP`/`DEPLOY_QUEUE_TABLE`를 새 출력으로 갱신한다.
3. 코드 레포 OIDC 역할 권한을 enqueue-only로 조정한다(아래 표).

즉 "드레이너 생성 → CI 전환" 순서를 지킨다. 반대로 하면 enqueue를 소비할 드레이너가 없어
배포가 멈춘다.
