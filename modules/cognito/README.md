# cognito module

URL 단축 서비스의 인증용 Cognito User Pool과 App Client(public, secret 없음)를 만든다.

- 로그인 id는 email(`username_attributes`), 이메일 인증 코드 사용, 이메일 대소문자 구분 없음
- `name`, `email`은 필수 스키마 속성. **생성 후 변경 불가** (변경 시 User Pool 재생성)
- 이메일 발송은 Cognito 기본(`COGNITO_DEFAULT`). 실서비스 전에 SES로 교체 필요

## Inputs

| 이름 | 기본값 | 설명 |
|---|---|---|
| `name` | (필수) | 리소스 이름 접두사 |
| `deletion_protection` | `true` | User Pool 삭제 방지 |
| `access_token_validity_hours` | `1` | Access 토큰 유효기간(시간) |
| `id_token_validity_hours` | `1` | ID 토큰 유효기간(시간) |
| `refresh_token_validity_days` | `30` | Refresh 토큰 유효기간(일) |

## Outputs

`user_pool_id`, `user_pool_arn`, `user_pool_client_id`, `issuer_url`
