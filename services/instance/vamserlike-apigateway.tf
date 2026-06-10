# =========================================================
# Vamserlike Project - API Gateway HTTP API
# 기존 main.tf는 수정하지 않고, API Gateway 껍데기만 별도 tf 파일로 추가
# Route53 / Custom Domain / Gabia 인증은 나중에 수동 또는 별도 작업
# =========================================================

variable "vamserlike_api_allowed_origins" {
  description = "Allowed CORS origins for Vamserlike API Gateway. Use specific CloudFront domain later."
  type        = list(string)
  default     = ["*"]
}

# 나중에 EKS Backend ALB 주소를 붙일 때 사용할 변수
# 지금 1차 배포에서는 비워둔다.
variable "vamserlike_backend_alb_dns" {
  description = "Backend ALB DNS name. Leave empty for API Gateway skeleton only."
  type        = string
  default     = ""
}

resource "aws_apigatewayv2_api" "vamserlike_http_api" {
  name          = "vamserlike-http-api"
  protocol_type = "HTTP"

  cors_configuration {
    allow_credentials = false

    allow_headers = [
      "authorization",
      "content-type",
      "x-amz-date",
      "x-api-key",
      "x-amz-security-token"
    ]

    allow_methods = [
      "GET",
      "POST",
      "PUT",
      "PATCH",
      "DELETE",
      "OPTIONS"
    ]

    allow_origins = var.vamserlike_api_allowed_origins
    max_age       = 300
  }

  tags = {
    Project = "vamserlike"
    Managed = "terraform"
  }
}

resource "aws_apigatewayv2_stage" "vamserlike_default_stage" {
  api_id      = aws_apigatewayv2_api.vamserlike_http_api.id
  name        = "$default"
  auto_deploy = true

  tags = {
    Project = "vamserlike"
    Managed = "terraform"
  }
}

# Cognito JWT Authorizer 껍데기
# 지금 당장 모든 route에 붙이지는 않고, 나중에 보호 API에 적용할 수 있게 먼저 생성
resource "aws_apigatewayv2_authorizer" "vamserlike_cognito_jwt_authorizer" {
  api_id          = aws_apigatewayv2_api.vamserlike_http_api.id
  name            = "vamserlike-cognito-jwt-authorizer"
  authorizer_type = "JWT"

  identity_sources = [
    "$request.header.Authorization"
  ]

  jwt_configuration {
    audience = [
      aws_cognito_user_pool_client.vamserlike_app_client.id
    ]

    issuer = "https://cognito-idp.ap-northeast-2.amazonaws.com/${aws_cognito_user_pool.vamserlike_user_pool.id}"
  }
}

# ---------------------------------------------------------
# Optional Backend ALB Integration
# ---------------------------------------------------------
# 지금은 backend ALB가 bootstrap 이후 생성되므로 기본값은 빈 문자열.
# 나중에 API Gateway -> Backend ALB 연결할 때
# -var 'vamserlike_backend_alb_dns=xxxxx.ap-northeast-2.elb.amazonaws.com'
# 형태로 넣으면 route/integration 생성 가능.
# ---------------------------------------------------------

resource "aws_apigatewayv2_integration" "vamserlike_backend_alb_integration" {
  count = var.vamserlike_backend_alb_dns == "" ? 0 : 1

  api_id             = aws_apigatewayv2_api.vamserlike_http_api.id
  integration_type   = "HTTP_PROXY"
  integration_method = "ANY"
  integration_uri    = "http://${var.vamserlike_backend_alb_dns}"

  payload_format_version = "1.0"
}

resource "aws_apigatewayv2_route" "vamserlike_backend_proxy_route" {
  count = var.vamserlike_backend_alb_dns == "" ? 0 : 1

  api_id    = aws_apigatewayv2_api.vamserlike_http_api.id
  route_key = "ANY /{proxy+}"
  target    = "integrations/${aws_apigatewayv2_integration.vamserlike_backend_alb_integration[0].id}"
}

resource "aws_apigatewayv2_route" "vamserlike_backend_root_route" {
  count = var.vamserlike_backend_alb_dns == "" ? 0 : 1

  api_id    = aws_apigatewayv2_api.vamserlike_http_api.id
  route_key = "ANY /"
  target    = "integrations/${aws_apigatewayv2_integration.vamserlike_backend_alb_integration[0].id}"
}

output "vamserlike_api_gateway_id" {
  value       = aws_apigatewayv2_api.vamserlike_http_api.id
  description = "Vamserlike API Gateway HTTP API ID"
}

output "vamserlike_api_gateway_endpoint" {
  value       = aws_apigatewayv2_api.vamserlike_http_api.api_endpoint
  description = "Vamserlike API Gateway HTTP API endpoint"
}

output "vamserlike_api_gateway_stage" {
  value       = aws_apigatewayv2_stage.vamserlike_default_stage.name
  description = "Vamserlike API Gateway default stage"
}

output "vamserlike_api_gateway_authorizer_id" {
  value       = aws_apigatewayv2_authorizer.vamserlike_cognito_jwt_authorizer.id
  description = "Vamserlike API Gateway Cognito JWT Authorizer ID"
}