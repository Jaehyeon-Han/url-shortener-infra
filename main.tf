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

  # Alias(live)를 통해 호출한다. auth는 CodeDeploy AllAtOnce로 신규 버전에
  # 전환하며, Lambda Errors / API Gateway 5xx 알람이 울리면 자동 롤백한다.
  # (Canary는 url만. auth는 점진 전환이 불필요해 AllAtOnce로 단순화한다.)
  enable_alias = true

  # 핸들러가 catch에서 커스텀 에러 지표(UrlShortener/App HandlerErrors)를 발행하므로,
  # 실행 역할에 해당 네임스페이스 한정 PutMetricData 권한을 부여한다.
  metrics_namespace = "UrlShortener/App"

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
module "lambda_url" {
  source = "./modules/lambda"

  name = "${var.name}-url"
  # CI가 프로젝트 루트 전체를 zip으로 압축하므로 zip 내부 경로는 src/ 접두가 붙는다.
  # 소스는 src/handlers/urls.mjs 이며, zip 루트 기준 핸들러는 src/handlers/urls.handler 다.
  handler = "src/handlers/urls.handler"

  artifact_bucket = module.artifacts.bucket_id
  s3_key          = "urls/function.zip"

  # Alias(live)를 통해 호출한다. url은 CodeDeploy Canary(10%/30분)로 전환하며
  # 알람 발생 시 자동 롤백한다. CI가 버전 publish 후 CodeDeploy 배포를 트리거한다.
  enable_alias = true

  # 핸들러가 catch에서 커스텀 에러 지표(UrlShortener/App HandlerErrors)를 발행하므로,
  # 실행 역할에 해당 네임스페이스 한정 PutMetricData 권한을 부여한다.
  metrics_namespace = "UrlShortener/App"

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

  lambda_invoke_arn    = module.lambda_auth.integration_invoke_arn
  lambda_function_name = module.lambda_auth.function_name
  lambda_qualifier     = module.lambda_auth.qualifier

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

  lambda_invoke_arn    = module.lambda_url.integration_invoke_arn
  lambda_function_name = module.lambda_url.function_name
  lambda_qualifier     = module.lambda_url.qualifier

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

# URL 함수의 CodeDeploy Canary 배포 설정이다.
# live Alias의 트래픽을 10%씩 30분에 걸쳐 신규 버전으로 옮기고,
# Lambda Errors / API Gateway 5xx 알람이 울리면 자동 롤백한다.
# 롤백/실패 이벤트와 알람은 SNS로 운영 담당자에게 통지된다.
# 실제 배포 트리거(create-deployment)는 CI가 수행한다.
module "codedeploy_url" {
  source = "./modules/codedeploy"

  name = "${var.name}-url"

  lambda_function_name = module.lambda_url.function_name
  lambda_alias_name    = module.lambda_url.alias_name

  # URL API의 5xx 지표를 상시 운영 알람으로 둔다(자동 롤백 기준 아님).
  api_id = module.apigateway_url.api_id

  # Canary 10%/30분. (CodeDeployDefault.LambdaCanary10Percent30Minutes가 기본값)
  deployment_config_name = "CodeDeployDefault.LambdaCanary10Percent30Minutes"

  # Canary는 신/구 버전이 공존하므로, 신버전만 가드하도록 ExecutedVersion 동적 알람을 쓴다.
  # Terraform은 고정 이름 알람만 만들고, CI가 배포 직전 PutMetricAlarm으로 신버전 차원을 갱신한다.
  errors_alarm_mode = "executed_version"

  # 핸들러가 try/catch로 예외를 삼키고 500을 정상 리턴하는 구조라, AWS/Lambda Errors는
  # 0이라 롤백이 안 걸린다. 핸들러가 PutMetricData로 올리는 커스텀 메트릭을 기준으로 삼는다.
  # (핸들러는 catch에서 UrlShortener/App 네임스페이스에 HandlerErrors=1을 발행해야 한다.)
  error_namespace   = "UrlShortener/App"
  error_metric_name = "HandlerErrors"

  notification_emails = var.deploy_notification_emails
}

# auth 함수의 CodeDeploy 배포 설정이다. url과 동일한 모듈을 재사용하되,
# 점진 전환이 불필요하므로 전략만 AllAtOnce로 다르게 준다.
# live Alias를 신규 버전으로 한 번에 전환하고, Lambda Errors / auth API 5xx 알람이
# 울리면 자동 롤백한다. 롤백/실패/알람은 SNS로 통지된다.
# 배포 경로를 CodeDeploy 단일로 통일해 CI 로직과 운영 모델을 일관화한다.
module "codedeploy_auth" {
  source = "./modules/codedeploy"

  name = "${var.name}-auth"

  lambda_function_name = module.lambda_auth.function_name
  lambda_alias_name    = module.lambda_auth.alias_name

  # auth API의 5xx 지표를 상시 운영 알람으로 둔다(자동 롤백 기준 아님).
  api_id = module.apigateway.api_id

  # AllAtOnce: 전량 전환 후 알람으로 롤백 여부를 판단한다.
  deployment_config_name = "CodeDeployDefault.LambdaAllAtOnce"

  # 전량 전환이라 버전 분리가 불필요하므로 alias 차원 정적 알람을 쓴다(CI 갱신 불필요).
  errors_alarm_mode = "alias"

  # auth 핸들러도 try/catch로 500을 정상 리턴하는 구조라면 AWS/Lambda Errors가 0이다.
  # url과 동일하게 핸들러가 발행하는 커스텀 메트릭(UrlShortener/App HandlerErrors)을 기준으로 삼는다.
  error_namespace   = "UrlShortener/App"
  error_metric_name = "HandlerErrors"

  notification_emails = var.deploy_notification_emails
}

# 비동기 배포 드레이너다. DeployQueue 테이블 + 드레이너 Lambda + 두 트리거(DDB Streams / EventBridge
# CodeDeploy 상태변경) + IAM을 캡슐화한다. 배포 트리거를 CI에서 떼어 이 드레이너로 옮겨, 배포가
# 겹쳐도 CreateDeployment가 DeploymentLimitExceededException으로 거부되지 않게 큐로 직렬화한다.
#
# CI(deploy.mjs 축소판)는 S3 업로드 + 버전 publish 후 DeployQueue에 desiredVersion만 enqueue하고
# 즉시 종료한다. 드레이너가 큐를 조건부 락으로 소비해 배포 그룹당 1개 제약을 지켜 순차(coalescing) 배포한다.
#
# deploy_config: 키는 "FN#<function>"(DeployQueue PK와 동일). lambda/codedeploy 모듈 output을 모아 조립한다.
#   - url: executed_version 모드이므로 드레이너가 CreateDeployment 직전 PutMetricAlarm으로 신버전 기준
#     롤백 알람을 갱신한다(알람 이름/SNS/네임스페이스/지표/임계값/주기 포함). 이 "알람 갱신 소유권"이
#     기존 CI에서 드레이너로 이전됐다(설계 6절). codedeploy 모듈의 알람 리소스/ignore_changes는 그대로다.
#   - auth: alias 모드이므로 알람 갱신이 없다(Terraform 정적 알람 사용). 알람 관련 키를 생략한다.
module "deploy_drainer" {
  source = "./modules/deploy-drainer"

  name = var.name

  deploy_config = {
    "FN#${module.lambda_url.function_name}" = {
      function          = module.lambda_url.function_name
      alias             = module.lambda_url.alias_name
      codedeploy_app    = module.codedeploy_url.app_name
      codedeploy_group  = module.codedeploy_url.deployment_group_name
      errors_alarm_mode = module.codedeploy_url.errors_alarm_mode
      errors_alarm_name = module.codedeploy_url.errors_alarm_name
      notify_topic_arn  = module.codedeploy_url.sns_topic_arn
      error_namespace   = module.codedeploy_url.error_namespace
      error_metric_name = module.codedeploy_url.error_metric_name
      alarm_threshold   = module.codedeploy_url.alarm_threshold
      alarm_period      = module.codedeploy_url.alarm_period_seconds
    }
    "FN#${module.lambda_auth.function_name}" = {
      function          = module.lambda_auth.function_name
      alias             = module.lambda_auth.alias_name
      codedeploy_app    = module.codedeploy_auth.app_name
      codedeploy_group  = module.codedeploy_auth.deployment_group_name
      errors_alarm_mode = module.codedeploy_auth.errors_alarm_mode
    }
  }
}
