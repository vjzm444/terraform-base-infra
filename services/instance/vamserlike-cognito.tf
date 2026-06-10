# =========================================================
# Vamserlike Project - Cognito
# 기존 main.tf는 수정하지 않고, Cognito 리소스만 별도 tf 파일로 추가
# =========================================================

resource "aws_cognito_user_pool" "vamserlike_user_pool" {
  name = "vamserlike-user-pool"

  username_attributes      = ["email"]
  auto_verified_attributes = ["email"]

  deletion_protection = "INACTIVE"

  password_policy {
    minimum_length                   = 8
    require_lowercase                = true
    require_numbers                  = true
    require_symbols                  = false
    require_uppercase                = true
    temporary_password_validity_days = 7
  }

  admin_create_user_config {
    allow_admin_create_user_only = false
  }

  account_recovery_setting {
    recovery_mechanism {
      name     = "verified_email"
      priority = 1
    }
  }

  schema {
    name                = "email"
    attribute_data_type = "String"
    required            = true
    mutable             = true

    string_attribute_constraints {
      min_length = 5
      max_length = 2048
    }
  }

  tags = {
    Project = "vamserlike"
    Managed = "terraform"
  }
}

resource "aws_cognito_user_pool_client" "vamserlike_app_client" {
  name         = "vamserlike-app-client"
  user_pool_id = aws_cognito_user_pool.vamserlike_user_pool.id

  generate_secret = false

  prevent_user_existence_errors = "ENABLED"

  explicit_auth_flows = [
    "ALLOW_USER_PASSWORD_AUTH",
    "ALLOW_USER_SRP_AUTH",
    "ALLOW_REFRESH_TOKEN_AUTH"
  ]

  supported_identity_providers = ["COGNITO"]

  access_token_validity  = 60
  id_token_validity      = 60
  refresh_token_validity = 30

  token_validity_units {
    access_token  = "minutes"
    id_token      = "minutes"
    refresh_token = "days"
  }
}

output "vamserlike_cognito_user_pool_id" {
  value       = aws_cognito_user_pool.vamserlike_user_pool.id
  description = "Vamserlike Cognito User Pool ID"
}

output "vamserlike_cognito_app_client_id" {
  value       = aws_cognito_user_pool_client.vamserlike_app_client.id
  description = "Vamserlike Cognito App Client ID"
}

output "vamserlike_cognito_issuer" {
  value       = "https://cognito-idp.ap-northeast-2.amazonaws.com/${aws_cognito_user_pool.vamserlike_user_pool.id}"
  description = "Vamserlike Cognito JWT issuer URL"
}