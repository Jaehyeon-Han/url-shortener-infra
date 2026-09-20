Url 단축기를 위한 AWS 인프라 설정이다.

각 구성 요소는 /modules 디렉토리 하위에 존재한다.

## 구성 요소
0. bootstrap: Terraform state를 저장하기 위해 S3 버킷을 생성한다. (초기 1회)
1. Cognito: 사용자를 인증한다.