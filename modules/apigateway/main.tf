# 인증 Lambda 앞단에 두는 HTTP API(v2)다.
# 외부 HTTP 요청을 payload v2로 Lambda에 프록시하고, 명시적 라우트만 노출한다.
# 커스텀 도메인(auth.<domain>)을 붙이고, Porkbun DNS에 해당 CNAME을 생성한다.

# --- HTTP API 본체 ---

resource "aws_apigatewayv2_api" "this" {
  name          = var.name
  protocol_type = "HTTP"

  # 브라우저에서 직접 호출하는 경우를 대비한 CORS 설정이다.
  cors_configuration {
    allow_origins = var.cors_allow_origins
    allow_methods = var.cors_allow_methods
    allow_headers = var.cors_allow_headers
  }

  tags = {
    Name      = var.name
    Project   = "urlshortener"
    ManagedBy = "terraform"
  }
}

# --- Lambda 통합 (AWS_PROXY, payload v2) ---

resource "aws_apigatewayv2_integration" "lambda" {
  api_id = aws_apigatewayv2_api.this.id

  integration_type       = "AWS_PROXY"
  integration_uri        = var.lambda_invoke_arn
  integration_method     = "POST"
  payload_format_version = "2.0"
}

# --- 명시적 라우트 ---

# route_keys의 각 "METHOD /path"를 동일한 Lambda 통합으로 연결한다.
# 목록에 없는 경로는 API Gateway가 404를 반환한다(최소 노출).
resource "aws_apigatewayv2_route" "this" {
  for_each = toset(var.route_keys)

  api_id    = aws_apigatewayv2_api.this.id
  route_key = each.value
  target    = "integrations/${aws_apigatewayv2_integration.lambda.id}"
}

# --- JWT authorizer (선택) ---

# jwt_issuer가 주어질 때만 생성한다. Cognito가 발급한 JWT(access/id token)를
# Authorization 헤더에서 검증한다. 보호 라우트가 이 authorizer를 참조한다.
resource "aws_apigatewayv2_authorizer" "jwt" {
  count = var.jwt_issuer != null ? 1 : 0

  api_id           = aws_apigatewayv2_api.this.id
  authorizer_type  = "JWT"
  identity_sources = ["$request.header.Authorization"]
  name             = "${var.name}-jwt"

  jwt_configuration {
    issuer   = var.jwt_issuer
    audience = var.jwt_audiences
  }
}

# --- 보호 라우트 (JWT authorizer 적용) ---

# protected_route_keys의 각 "METHOD /path"를 공개 라우트와 동일한 Lambda 통합으로
# 연결하되, JWT authorizer를 붙여 인증된 요청만 통과시킨다.
# 핸들러는 authorizer가 채운 requestContext.authorizer.jwt.claims.sub로 소유자를 식별한다.
resource "aws_apigatewayv2_route" "protected" {
  for_each = toset(var.protected_route_keys)

  api_id             = aws_apigatewayv2_api.this.id
  route_key          = each.value
  target             = "integrations/${aws_apigatewayv2_integration.lambda.id}"
  authorization_type = "JWT"
  authorizer_id      = aws_apigatewayv2_authorizer.jwt[0].id
}

# --- Lambda 호출 권한 ---

# API Gateway가 이 Lambda를 호출할 수 있도록 리소스 기반 권한을 부여한다.
# 이 권한이 없으면 라우트가 있어도 호출이 403으로 거부된다.
resource "aws_lambda_permission" "apigw" {
  statement_id  = "AllowInvokeFrom-${var.name}"
  action        = "lambda:InvokeFunction"
  function_name = var.lambda_function_name
  principal     = "apigateway.amazonaws.com"

  # Alias를 통해 호출하는 경우 해당 alias로 권한을 한정한다.
  # null이면 비한정($LATEST 포함)으로 부여한다.
  qualifier = var.lambda_qualifier

  # 이 API의 모든 스테이지/메서드/경로에서의 호출을 허용한다.
  source_arn = "${aws_apigatewayv2_api.this.execution_arn}/*/*"
}

# --- 액세스 로그 그룹 ---

resource "aws_cloudwatch_log_group" "access" {
  name              = "/aws/apigateway/${var.name}"
  retention_in_days = var.log_retention_days
}

# --- 스테이지 ($default, auto_deploy) ---

resource "aws_apigatewayv2_stage" "default" {
  api_id      = aws_apigatewayv2_api.this.id
  name        = "$default"
  auto_deploy = true

  # 요청 단위 액세스 로그를 JSON으로 CloudWatch에 남긴다.
  access_log_settings {
    destination_arn = aws_cloudwatch_log_group.access.arn
    format = jsonencode({
      requestId               = "$context.requestId"
      requestTime             = "$context.requestTime"
      httpMethod              = "$context.httpMethod"
      routeKey                = "$context.routeKey"
      path                    = "$context.path"
      status                  = "$context.status"
      responseLength          = "$context.responseLength"
      integrationErrorMessage = "$context.integrationErrorMessage"
      sourceIp                = "$context.identity.sourceIp"
    })
  }

  tags = {
    Name      = var.name
    Project   = "urlshortener"
    ManagedBy = "terraform"
  }
}

# --- 커스텀 도메인 ---

resource "aws_apigatewayv2_domain_name" "this" {
  domain_name = var.domain_name

  domain_name_configuration {
    certificate_arn = var.certificate_arn
    endpoint_type   = "REGIONAL"
    security_policy = "TLS_1_2"
  }

  tags = {
    Name      = var.name
    Project   = "urlshortener"
    ManagedBy = "terraform"
  }
}

# 커스텀 도메인을 위 스테이지에 연결한다.
resource "aws_apigatewayv2_api_mapping" "this" {
  api_id      = aws_apigatewayv2_api.this.id
  domain_name = aws_apigatewayv2_domain_name.this.id
  stage       = aws_apigatewayv2_stage.default.id
}

# --- Porkbun DNS CNAME ---

# 커스텀 도메인(예: auth.jhan.cc)을 API Gateway의 regional target 도메인으로 가리킨다.
# Porkbun의 subdomain은 루트 도메인을 제외한 부분("auth")만 요구하므로,
# domain_name에서 ".<porkbun_domain>"을 제거해 subdomain으로 넘긴다.
resource "porkbun_dns_record" "this" {
  domain    = var.porkbun_domain
  subdomain = trimsuffix(var.domain_name, ".${var.porkbun_domain}")
  type      = "CNAME"
  content   = aws_apigatewayv2_domain_name.this.domain_name_configuration[0].target_domain_name
  ttl       = 600
}
