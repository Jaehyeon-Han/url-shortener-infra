module "cognito" {
  source = "./modules/cognito"

  name = var.name
}

# Lambda 배포 아티팩트(zip)를 보관하는 S3 버킷이다. CI가 이 버킷에 코드 zip을 업로드한다.
module "artifacts" {
  source = "./modules/artifacts"

  name = var.name
}

# URL/통계 데이터를 담는 단일 테이블(싱글 테이블 디자인)이다.
# 추후 단축/리다이렉트/통계 Lambda가 이 테이블명(env)과 ARN(IAM 정책 대상)을 참조한다.
module "dynamodb" {
  source = "./modules/dynamodb"

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

# URL/통계/리다이렉트 Lambda의 실행 역할에 부착할 DynamoDB 권한이다.
# 핸들러(lib/url-repo.mjs, lib/dynamo.mjs)가 단일 테이블에 수행하는 데이터플레인 작업에 맞춘다.
#   - 생성: PutItem (URL 메타/카운터/쿼터)
#   - 리다이렉트(핫패스): GetItem (URL 메타)
#   - 비활성/카운터 증가: UpdateItem
#   - 목록/통계: Query (GSI1=소유자별, GSI2=상태별, 기본 테이블 SK range)
# 테이블 본체와 모든 보조 인덱스(index/*)를 대상으로 한다(GSI 쿼리에 index/* 필요).
# 관리플레인(CreateTable 등) 액션은 포함하지 않는다.
data "aws_iam_policy_document" "url" {
  statement {
    sid = "DynamoSingleTableAccess"
    actions = [
      "dynamodb:GetItem",
      "dynamodb:BatchGetItem",
      "dynamodb:Query",
      "dynamodb:PutItem",
      "dynamodb:UpdateItem",
      "dynamodb:DeleteItem",
      "dynamodb:BatchWriteItem",
      "dynamodb:ConditionCheckItem",
    ]
    resources = [
      module.dynamodb.table_arn,
      "${module.dynamodb.table_arn}/index/*",
    ]
  }
}

# URL 단축/목록/통계/비활성/리다이렉트를 담당하는 Lambda 함수다.
# 함수 내부 핸들러가 세부 라우팅을 담당하며, 단일 테이블(DynamoDB)을 데이터 저장소로 쓴다.
# API Gateway 연결은 별도 단계에서 추가한다(이 함수는 아직 공개 엔드포인트에 물려 있지 않다).
module "lambda_url" {
  source = "./modules/lambda"

  name = "${var.name}-url"
  # CI가 프로젝트 루트 전체를 zip으로 압축하므로 zip 내부 경로는 src/ 접두가 붙는다.
  # 소스는 src/handlers/urls.mjs 이며, zip 루트 기준 핸들러는 src/handlers/urls.handler 다.
  handler = "src/handlers/urls.handler"

  artifact_bucket = module.artifacts.bucket_id
  s3_key          = "url/function.zip"

  inline_policy_json = data.aws_iam_policy_document.url.json

  # 핸들러(lib/dynamo.mjs)는 TABLE_NAME 환경변수로 대상 테이블을 읽는다.
  environment = {
    TABLE_NAME = module.dynamodb.table_name
  }
}

# 루트 도메인 TLS 인증서를 발급/검증한다.
# 인증서 발급(ACM) + 검증 CNAME 생성(Porkbun) + 검증 완료 대기를 한 모듈에 응집한다.
# porkbun provider는 루트에서 정의해 모듈로 전달한다.
module "certificate" {
  source = "./modules/certificate"

  name        = var.name
  domain_name = var.domain_name

  # 인증 API(auth.<domain>)와 URL 리다이렉트 API(short.<domain>) 커스텀 도메인을
  # 같은 인증서로 커버한다. 모듈은 서브도메인을 조립하지 않으므로 완전한 도메인 문자열을 넘긴다.
  subject_alternative_names = ["auth.${var.domain_name}", "short.${var.domain_name}"]

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

# URL Lambda 앞단의 HTTP API(v2)다. 같은 apigateway 모듈을 재사용한다.
# - 공개 라우트: GET /{code} (리다이렉트 핫패스, authorizer 없음)
# - 보호 라우트: /urls* (Cognito JWT authorizer로 보호, 핸들러가 claims.sub로 소유자 식별)
# 커스텀 도메인은 short.<domain>이며, 루트(<domain>)는 다른 API가 ALIAS로 점유 중이라 쓰지 않는다.
module "apigateway_url" {
  source = "./modules/apigateway"

  name = "${var.name}-url"

  lambda_invoke_arn    = module.lambda_url.invoke_arn
  lambda_function_name = module.lambda_url.function_name

  # 공개(authorizer 없음): 리다이렉트.
  route_keys = ["GET /{code}"]

  # 보호(JWT authorizer 적용): 생성/목록/통계/비활성.
  protected_route_keys = [
    "POST /urls",
    "GET /urls",
    "GET /urls/{code}/stats",
    "POST /urls/{code}/disable",
  ]

  # Cognito JWT authorizer. issuer는 스킴(https://)을 포함해야 한다.
  # cognito 모듈의 issuer_url(=user pool endpoint)은 스킴이 없으므로 접두한다.
  jwt_issuer    = "https://${module.cognito.issuer_url}"
  jwt_audiences = [module.cognito.user_pool_client_id]

  # 리다이렉트(GET)와 /urls(GET/POST)를 모두 허용한다.
  cors_allow_methods = ["GET", "POST", "OPTIONS"]

  # certificate 모듈이 SAN으로 short.<domain>을 커버한다.
  certificate_arn = module.certificate.certificate_arn
  domain_name     = "short.${var.domain_name}"
  porkbun_domain  = var.domain_name

  providers = {
    porkbun = porkbun
  }
}