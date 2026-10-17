Url 단축기를 위한 AWS 인프라 설정이다.

각 구성 요소는 /modules 디렉토리 하위에 존재한다.

## 구성 요소
0. bootstrap: Terraform state를 저장하기 위해 S3 버킷을 생성한다. (초기 1회)
1. Cognito: 사용자를 인증한다.
2. artifacts: Lambda 배포 아티팩트(zip)를 보관하는 S3 버킷이다. CI가 이 버킷에 코드 zip을 업로드한다.
3. lambda: 재사용 가능한 Node.js(mjs) Lambda 함수 모듈이다. 루트에서 인증(`auth`)과 URL 단축/통계/리다이렉트(`url`) 두 함수를 이 모듈로 배선한다. `url` 함수는 dynamodb 단일 테이블을 `TABLE_NAME` env와 IAM으로 주입받는다.
4. certificate: 루트 도메인 TLS 인증서를 ACM으로 발급하고 Porkbun DNS로 검증을 자동화한다. `auth.<domain>`과 `short.<domain>`을 SAN으로 함께 커버한다.
5. apigateway: Lambda 앞단의 HTTP API(v2) 재사용 모듈이다. auth API(`auth.<domain>`, 공개)와 URL API(`short.<domain>`, 공개 리다이렉트 `GET /{code}` + Cognito JWT로 보호되는 `/urls*`)를 배선하고, 각 커스텀 도메인 CNAME을 Porkbun DNS에 생성한다.
6. dynamodb: URL/통계 데이터를 담는 단일 테이블(싱글 테이블 디자인)이다. PK/SK + GSI1(소유자별 목록)/GSI2(상태별 조회), 온디맨드 과금, PITR 활성이다.
7. codedeploy: Lambda의 트래픽 전환 배포를 담당한다. live Alias를 신규 버전에 전환하고(`url`은 Canary 10%/30분, `auth`는 AllAtOnce), 에러 알람이 울리면 자동 롤백한다. 핸들러가 try/catch로 500을 정상 리턴해 `AWS/Lambda Errors`가 0이 되는 구조라, 롤백 기준은 핸들러가 발행하는 커스텀 지표(`UrlShortener/App` `HandlerErrors`)다. `url`은 Canary 신버전만 가드하도록 이 지표를 ExecutedVersion(신버전) 차원으로 좁히며, 그 차원은 **드레이너가 배포 직전 갱신**한다. API Gateway 5xx는 버전 차원이 없어 롤백 기준에서 제외하고 상시 SNS 알람으로 둔다. 롤백/실패/알람은 SNS로 통지한다. 실제 배포 트리거는 **드레이너(8번)**가 수행한다.
8. deploy-drainer: 비동기 배포 드레이너다. `DeployQueue` DynamoDB 테이블(큐+분산 락+멱등 저장소) + 드레이너 Lambda + 두 트리거(DeployQueue Streams로 enqueue 수신, EventBridge CodeDeploy 상태변경으로 dequeue) + IAM을 캡슐화한다. CodeDeploy는 배포 그룹당 활성 배포가 1개뿐이라 배포가 겹치면 이후 `CreateDeployment`가 `DeploymentLimitExceededException`으로 거부되는데, 이를 큐로 직렬화해 해소한다. CI는 `desiredVersion`만 enqueue하고 즉시 종료하며, 드레이너가 조건부 락으로 배포 그룹당 1개 제약을 지켜 순차(coalescing) 배포한다. `url`(executed_version 모드)의 롤백 알람 갱신(PutMetricAlarm) 소유권도 CI에서 드레이너로 이전됐다. 핵심 결정 로직은 순수 함수로 분리해 `node:test`로 네 불변식(멱등성/경쟁/수렴/dequeue)을 증명한다.

## 배포 전략 (Alias + CodeDeploy + 비동기 드레이너)

- 두 함수(`auth`/`url`) 모두 `live` Alias를 통해 호출되고, 전환은 **CodeDeploy로 통일**한다. API Gateway는 함수가 아니라 Alias를 가리킨다.
- **배포 트리거는 드레이너가 수행한다**: CI는 `CreateDeployment`를 직접 호출하지 않는다. S3 업로드 + 버전 publish 후 `DeployQueue`에 `desiredVersion`만 적재(enqueue)하고 종료한다. 드레이너 Lambda가 큐를 조건부 락으로 소비해 배포 그룹당 1개 제약을 지켜 순차 배포한다. 배포가 겹쳐도 충돌하지 않는다.
- **롤백 기준 지표**: 핸들러가 예외를 try/catch로 삼키고 500을 리턴하므로 `AWS/Lambda Errors`가 0이다. 그래서 핸들러가 `PutMetricData`로 올리는 커스텀 지표(`UrlShortener/App` `HandlerErrors`)를 롤백 기준으로 쓴다. 발행 권한은 함수 실행 역할의 `cloudwatch:PutMetricData`(`modules/lambda`의 `metrics_namespace`)로 부여한다.
- **url**: CodeDeploy Canary 10%/30분. 롤백 기준은 `HandlerErrors`(ExecutedVersion=신버전) 알람이며, **드레이너가 배포 직전 신버전으로 갱신**한다. URL API 5xx는 상시 SNS 알람(롤백 기준 아님).
- **auth**: CodeDeploy AllAtOnce(전량 전환). 롤백 기준은 `HandlerErrors`(alias 차원) 정적 알람. auth API 5xx는 상시 SNS 알람.
- Canary/AllAtOnce 차이는 각 배포 그룹의 `deployment_config_name`이 결정하며, 드레이너는 두 함수 모두 동일한 경로(조건부 락 → (url) 알람 갱신 → GetAlias → create-deployment)를 쓴다.
- 버전 publish와 큐 적재(enqueue)는 CI가 담당하고, 배포 트리거는 드레이너가 담당한다. CI 연동 계약과 참조 구현은 `ci-reference/`를 참고한다.

## 문서
- 각 모듈의 상세(목적/Inputs/Outputs)는 해당 `modules/<name>/README.md`를 참고한다.
- 배포/삭제 절차와 안전 규칙은 `.kiro/steering/workflow.md`, 컨벤션은 `.kiro/steering/terraform-conventions.md`, 개요는 `.kiro/steering/project.md`를 참고한다.