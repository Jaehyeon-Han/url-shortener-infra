Url 단축기를 위한 AWS 인프라 설정이다.

각 구성 요소는 /modules 디렉토리 하위에 존재한다.

## 구성 요소
0. bootstrap: Terraform state를 저장하기 위해 S3 버킷을 생성한다. (초기 1회)
1. Cognito: 사용자를 인증한다.
2. artifacts: Lambda 배포 아티팩트(zip)를 보관하는 S3 버킷이다. CI가 이 버킷에 코드 zip을 업로드한다.
3. lambda: 재사용 가능한 Node.js(mjs) Lambda 함수 모듈이다.

## 문서
- 각 모듈의 상세(목적/Inputs/Outputs)는 해당 `modules/<name>/README.md`를 참고한다.
- 배포/삭제 절차와 안전 규칙은 `.kiro/steering/workflow.md`, 컨벤션은 `.kiro/steering/terraform-conventions.md`, 개요는 `.kiro/steering/project.md`를 참고한다.