# certificate 모듈

## 목적

루트 도메인에 대한 AWS ACM 퍼블릭 TLS 인증서를 발급하고, DNS 검증을 자동화한다.
인증서 발급(ACM), 검증용 CNAME 생성(Porkbun DNS), 검증 완료 대기를 하나의 모듈에 응집한다.
`subject_alternative_names`로 추가 도메인(SAN)을 넘기면 하나의 인증서가 여러 도메인을 함께 커버한다 (예: 루트 + `auth.jhan.cc`).

인증서를 실제로 연결하는 리소스(API Gateway custom domain, ALB 등)는 이 모듈 범위가 아니다.
연결 대상은 이 모듈의 `certificate_arn` 출력을 참조해 별도로 구성한다.

## 동작 방식

1. `aws_acm_certificate`로 DNS 검증 방식 인증서를 요청한다.
2. ACM이 산출한 `domain_validation_options`를 바탕으로 `porkbun_dns_record`(CNAME)를 생성한다.
   - ACM의 `resource_record_name`은 `_abc.<domain>.` 형태 FQDN이라, `.<domain>.`과 후행 점을 제거해
     Porkbun의 `subdomain`으로 넘긴다. `content`도 후행 점을 제거한다.
3. `aws_acm_certificate_validation`이 위 CNAME 기준으로 검증 완료를 대기한다.

인증서 → CNAME → 검증의 일직선 의존이므로 순환 참조가 없다.

## 주의

- `porkbun` provider는 서드파티(비공식)이며, `plan`/`apply`가 **실제 Porkbun DNS를 변경**한다.
- provider 설정(자격증명)은 루트에서 정의해 `providers = { porkbun = porkbun }`로 이 모듈에 전달한다.
- 대상 도메인은 Porkbun 기본 네임서버를 사용해야 검증 CNAME이 실제로 조회된다.

## Inputs

| 이름 | 설명 | 타입 | 필수 |
|---|---|---|---|
| `name` | 리소스 이름 접두사 (예: `urlshortener`). 태그에 사용한다. | `string` | 예 |
| `domain_name` | 인증서를 발급할 루트 도메인 (예: `jhan.cc`). | `string` | 예 |
| `subject_alternative_names` | 인증서가 함께 커버할 추가 도메인(SAN) 목록. 완전한 도메인 문자열을 넘긴다 (예: `["auth.jhan.cc"]`). 기본값 `[]`. | `list(string)` | 아니오 |

## Outputs

| 이름 | 설명 |
|---|---|
| `certificate_arn` | 검증 완료된 ACM 인증서 ARN. 연결 대상에서 참조한다. |
| `domain_name` | 인증서가 발급된 도메인. |
