# 프로젝트 개요

AWS 기반 서버리스 URL 단축 서비스의 인프라를 Terraform으로 관리하는 프로젝트다.

## 기술 스택

| 항목 | 값 |
|---|---|
| IaC 도구 | Terraform (`>= 1.10.0`) |
| Provider | `hashicorp/aws` (`~> 6.0`) |
| 리전 | `ap-northeast-2` (Seoul) |
| 프로젝트 접두사 | `urlshortener` |
| State 저장 | S3 원격 backend, 잠금은 S3 네이티브 잠금(`use_lockfile`) |

## 네이밍 규칙

- 리소스 이름은 접두사를 붙인다. 모듈 내부에서는 `${var.name}-*` 형식을 사용한다.
  - 예: `${var.name}-users`, `${var.name}-client`
- 루트/bootstrap의 이름 접두사 변수 기본값은 `urlshortener`다.
- 기본 태그: `Project = urlshortener`, `ManagedBy = terraform`.

## 현재 구현 상태

- 구현됨: `bootstrap`(state용 S3 버킷), `modules/cognito`(사용자 인증).
- 미구현: Lambda, API Gateway, DynamoDB 등 URL 단축 핵심 기능 모듈은 아직 없다.

## 문서 규칙

- 문서와 주석은 한국어 서술체(`~다`)로 작성한다.
- 상세 구조/실행 가이드는 `PROJECT_STRUCTURE.md`를 참고한다.
