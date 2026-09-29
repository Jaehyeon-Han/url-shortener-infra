module "cognito" {
  source = "./modules/cognito"

  name = var.name
}

# Lambda 배포 아티팩트(zip)를 보관하는 S3 버킷이다. CI가 이 버킷에 코드 zip을 업로드한다.
module "artifacts" {
  source = "./modules/artifacts"

  name = var.name
}

# 인증(auth) Lambda의 실행 역할에 부착할 세밀 권한이다.
# auth 핸들러가 호출하는 Cognito API에 맞춘 최소 권한이다.
#   SignUp / ConfirmSignUp / ResendConfirmationCode / InitiateAuth / GlobalSignOut
# 위 API들은 App Client 기반 비인증(public) 플로우라 IAM 권한 없이도 동작하지만,
# 최소 권한을 명시적으로 문서화하는 차원에서 실제 사용 액션을 대상 User Pool로 한정해 부여한다.
# Admin* API(예: AdminInitiateAuth)를 쓰게 되면 해당 액션을 여기에 추가한다.
data "aws_iam_policy_document" "auth" {
  statement {
    sid = "CognitoAuthFlows"
    actions = [
      "cognito-idp:SignUp",
      "cognito-idp:ConfirmSignUp",
      "cognito-idp:ResendConfirmationCode",
      "cognito-idp:InitiateAuth",
      "cognito-idp:GlobalSignOut",
    ]
    resources = [module.cognito.user_pool_arn]
  }
}

# 인증 관련 API를 모은 Lambda 함수다. 함수 내부 핸들러가 세부 라우팅을 담당한다.
# 이후 단축/리다이렉트 함수도 같은 lambda 모듈을 재사용해 추가한다.
module "lambda_auth" {
  source = "./modules/lambda"

  name = "${var.name}-auth"
  # CI가 프로젝트 루트 전체를 zip으로 압축하므로 zip 내부 경로는 src/ 접두가 붙는다.
  # 소스는 src/handlers/auth.mjs 이며, zip 루트 기준 핸들러는 src/handlers/auth.handler 다.
  handler = "src/handlers/auth.handler"

  artifact_bucket = module.artifacts.bucket_id
  s3_key          = "auth/function.zip"

  inline_policy_json = data.aws_iam_policy_document.auth.json

  # auth 핸들러는 App Client ID로 Cognito API를 호출한다.
  environment = {
    COGNITO_CLIENT_ID = module.cognito.user_pool_client_id
  }
}

# 루트 도메인 TLS 인증서를 발급/검증한다.
# 인증서 발급(ACM) + 검증 CNAME 생성(Porkbun) + 검증 완료 대기를 한 모듈에 응집한다.
# porkbun provider는 루트에서 정의해 모듈로 전달한다.
module "certificate" {
  source = "./modules/certificate"

  name        = var.name
  domain_name = var.domain_name

  # 인증 API 커스텀 도메인(auth.<domain>)을 같은 인증서로 커버한다.
  # 모듈은 서브도메인을 조립하지 않으므로 완전한 도메인 문자열을 넘긴다.
  subject_alternative_names = ["auth.${var.domain_name}"]

  providers = {
    porkbun = porkbun
  }
}

# 인증 Lambda 앞단의 HTTP API(v2)다.
# 6개 auth 라우트를 노출하고, auth.<domain> 커스텀 도메인 + TLS를 연결한다.
# 커스텀 도메인 CNAME은 이 모듈이 Porkbun DNS에 생성하므로 porkbun provider를 전달한다.
module "apigateway" {
  source = "./modules/apigateway"

  name = "${var.name}-auth"

  lambda_invoke_arn    = module.lambda_auth.invoke_arn
  lambda_function_name = module.lambda_auth.function_name

  # certificate 모듈이 SAN으로 auth.<domain>을 커버한다.
  certificate_arn = module.certificate.certificate_arn
  domain_name     = "auth.${var.domain_name}"
  porkbun_domain  = var.domain_name

  providers = {
    porkbun = porkbun
  }
}