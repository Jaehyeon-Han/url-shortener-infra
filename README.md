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

## 문서
- 각 모듈의 상세(목적/Inputs/Outputs)는 해당 `modules/<name>/README.md`를 참고한다.
- 배포/삭제 절차와 안전 규칙은 `.kiro/steering/workflow.md`, 컨벤션은 `.kiro/steering/terraform-conventions.md`, 개요는 `.kiro/steering/project.md`를 참고한다.