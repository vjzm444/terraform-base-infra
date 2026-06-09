# ==========================================
# WAF (AWS WAFv2) — "WAF 대응 정책" 적용
# ==========================================
# testalb.tf 의 aws_lb.alb(Application Load Balancer)에 Web ACL을 연결한다.
# 명세서 v11의 Case 1~10 대응 정책을 규칙으로 구현한다.
#
# 차단 규칙 식별(커스텀 응답):
#   직접 정의한 규칙(Geo/크기/UA/속도 제한)은 차단 시 응답 헤더
#   'x-waf-rule' 에 규칙 이름을 실어 보낸다. 테스트 툴이 이 헤더를 읽어
#   "어느 규칙이 막았는지"를 바로 확인할 수 있다.
#   관리형 룰셋(Common/KnownBadInputs/AnonymousIpList)은 그룹 내부에서
#   차단하므로 이 헤더가 없으며, 403만 반환된다.
#
# 배포 시 참고:
#   - scope = "REGIONAL" (ALB는 리전 리소스)
#   - 규칙은 우선순위(priority) 순으로 평가되고, 처음 차단하는 규칙에서 멈춘다.
#     (Geo=0 이 가장 먼저, 관리형 룰셋은 30번대로 뒤에 둔다.)
#   - 관리형 룰 WCU 합계(Common 700 + KnownBadInputs 200 + AnonymousIp 50 등)는
#     기본 한도 1500 WCU 이내이다.
# ==========================================

variable "allowed_country_codes" {
  description = "서비스 대상 국가(allowlist). 이 외 국가는 차단."
  type        = list(string)
  default     = ["KR", "US", "JP"]
}

variable "waf_rate_limit" {
  description = "Rate-based 규칙 임계값 (5분 / IP). WAFv2 최소값 100."
  type        = number
  default     = 100
}

resource "aws_wafv2_web_acl" "backend" {
  name        = "vamserlike-backend-acl"
  description = "Vamserlike backend protection spec v11" # 한글과 괄호를 제거한 영문 설명
  scope       = "REGIONAL"

  # 기본은 허용. 차단은 아래 개별 규칙이 담당한다.
  default_action {
    allow {}
  }

  # ----- Case 1. 지역 기반 접근 제어 (allowlist) -----
  rule {
    name     = "case1-geo-allowlist"
    priority = 0
    action {
      block {
        custom_response {
          response_code = 403
          response_header {
            name  = "x-waf-rule"
            value = "case1-geo-allowlist"
          }
        }
      }
    }
    statement {
      not_statement {
        statement {
          geo_match_statement {
            country_codes = var.allowed_country_codes
          }
        }
      }
    }
    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "case1-geo-allowlist"
      sampled_requests_enabled   = true
    }
  }

  # ----- Case 2-1. 랭킹 조회 속도 제한 -----
  rule {
    name     = "case2-rate-ranking"
    priority = 10
    action {
      block {
        custom_response {
          response_code = 403
          response_header {
            name  = "x-waf-rule"
            value = "case2-rate-ranking"
          }
        }
      }
    }
    statement {
      rate_based_statement {
        limit                 = var.waf_rate_limit
        aggregate_key_type    = "IP"
        evaluation_window_sec = 300
        scope_down_statement {
          byte_match_statement {
            field_to_match {
              uri_path {}
            }
            positional_constraint = "STARTS_WITH"
            search_string         = "/api/players/ranking"
            text_transformation {
              priority = 0
              type     = "LOWERCASE"
            }
          }
        }
      }
    }
    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "case2-rate-ranking"
      sampled_requests_enabled   = true
    }
  }

  # ----- Case 2-2. 캐릭터 해금 속도 제한 -----
  rule {
    name     = "case2-rate-unlock"
    priority = 11
    action {
      block {
        custom_response {
          response_code = 403
          response_header {
            name  = "x-waf-rule"
            value = "case2-rate-unlock"
          }
        }
      }
    }
    statement {
      rate_based_statement {
        limit                 = var.waf_rate_limit
        aggregate_key_type    = "IP"
        evaluation_window_sec = 300
        scope_down_statement {
          byte_match_statement {
            field_to_match {
              uri_path {}
            }
            positional_constraint = "STARTS_WITH"
            search_string         = "/api/players/me/characters/unlock"
            text_transformation {
              priority = 0
              type     = "LOWERCASE"
            }
          }
        }
      }
    }
    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "case2-rate-unlock"
      sampled_requests_enabled   = true
    }
  }

  # ----- Case 3. 결과 저장 속도 제한 -----
  rule {
    name     = "case3-rate-progress"
    priority = 12
    action {
      block {
        custom_response {
          response_code = 403
          response_header {
            name  = "x-waf-rule"
            value = "case3-rate-progress"
          }
        }
      }
    }
    statement {
      rate_based_statement {
        limit                 = var.waf_rate_limit
        aggregate_key_type    = "IP"
        evaluation_window_sec = 300
        scope_down_statement {
          byte_match_statement {
            field_to_match {
              uri_path {}
            }
            positional_constraint = "STARTS_WITH"
            search_string         = "/api/players/me/progress"
            text_transformation {
              priority = 0
              type     = "LOWERCASE"
            }
          }
        }
      }
    }
    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "case3-rate-progress"
      sampled_requests_enabled   = true
    }
  }

  # ----- Case 4. SQLi/XSS 등 알려진 웹 공격 패턴 (CommonRuleSet) -----
  # 관리형 룰셋은 그룹 내부에서 차단하므로 x-waf-rule 헤더가 없다.
  # 참고: 이 룰셋의 SizeRestrictions_BODY 가 8KB 초과 바디도 함께 차단하므로
  #       Case 5와 일부 중복되나, 명세 충실성을 위해 두 규칙을 모두 둔다.
  rule {
    name     = "case4-aws-common-ruleset"
    priority = 30
    override_action {
      none {}
    }
    statement {
      managed_rule_group_statement {
        vendor_name = "AWS"
        name        = "AWSManagedRulesCommonRuleSet"
      }
    }
    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "case4-aws-common-ruleset"
      sampled_requests_enabled   = true
    }
  }

  # ----- Case 4b. SQL 인젝션 차단 (SQLiRuleSet) -----
  # CommonRuleSet에는 SQLi 탐지가 없어(XSS 등만 포함) SQL 인젝션이 통과한다.
  # SQLi 전용 관리형 룰셋을 추가해 SQL 인젝션 패턴을 차단한다.
  rule {
    name     = "case4-aws-sqli-ruleset"
    priority = 33
    override_action {
      none {}
    }
    statement {
      managed_rule_group_statement {
        vendor_name = "AWS"
        name        = "AWSManagedRulesSQLiRuleSet"
      }
    }
    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "case4-aws-sqli-ruleset"
      sampled_requests_enabled   = true
    }
  }

  # ----- Case 5. 대용량 페이로드 차단 (요청 바디 8KB 초과) -----
  rule {
    name     = "case5-body-size-limit"
    priority = 1
    action {
      block {
        custom_response {
          response_code = 403
          response_header {
            name  = "x-waf-rule"
            value = "case5-body-size-limit"
          }
        }
      }
    }
    statement {
      size_constraint_statement {
        field_to_match {
          body {
            # 8KB 초과로 검사 한도를 넘는 바디는 매치(=차단) 처리
            oversize_handling = "MATCH"
          }
        }
        comparison_operator = "GT"
        size                = 8192
        text_transformation {
          priority = 0
          type     = "NONE"
        }
      }
    }
    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "case5-body-size-limit"
      sampled_requests_enabled   = true
    }
  }

  # ----- Case 6. 로그인 속도 제한 -----
  rule {
    name     = "case6-rate-login"
    priority = 13
    action {
      block {
        custom_response {
          response_code = 403
          response_header {
            name  = "x-waf-rule"
            value = "case6-rate-login"
          }
        }
      }
    }
    statement {
      rate_based_statement {
        limit                 = var.waf_rate_limit
        aggregate_key_type    = "IP"
        evaluation_window_sec = 300
        scope_down_statement {
          byte_match_statement {
            field_to_match {
              uri_path {}
            }
            positional_constraint = "STARTS_WITH"
            search_string         = "/api/auth/login"
            text_transformation {
              priority = 0
              type     = "LOWERCASE"
            }
          }
        }
      }
    }
    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "case6-rate-login"
      sampled_requests_enabled   = true
    }
  }

  # ----- Case 7. 회원가입 속도 제한 -----
  rule {
    name     = "case7-rate-signup"
    priority = 14
    action {
      block {
        custom_response {
          response_code = 403
          response_header {
            name  = "x-waf-rule"
            value = "case7-rate-signup"
          }
        }
      }
    }
    statement {
      rate_based_statement {
        limit                 = var.waf_rate_limit
        aggregate_key_type    = "IP"
        evaluation_window_sec = 300
        scope_down_statement {
          byte_match_statement {
            field_to_match {
              uri_path {}
            }
            positional_constraint = "STARTS_WITH"
            search_string         = "/api/auth/signup"
            text_transformation {
              priority = 0
              type     = "LOWERCASE"
            }
          }
        }
      }
    }
    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "case7-rate-signup"
      sampled_requests_enabled   = true
    }
  }

  # ----- Case 8. 자동화 도구/스캐너 User-Agent 차단 -----
  rule {
    name     = "case8-block-tool-user-agents"
    priority = 2
    action {
      block {
        custom_response {
          response_code = 403
          response_header {
            name  = "x-waf-rule"
            value = "case8-user-agent"
          }
        }
      }
    }
    statement {
      or_statement {
        dynamic "statement" {
          for_each = ["sqlmap", "nikto", "zgrab", "selenium", "puppeteer"]
          content {
            byte_match_statement {
              field_to_match {
                single_header {
                  name = "user-agent"
                }
              }
              positional_constraint = "CONTAINS"
              search_string         = statement.value
              text_transformation {
                priority = 0
                type     = "LOWERCASE"
              }
            }
          }
        }
      }
    }
    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "case8-block-tool-user-agents"
      sampled_requests_enabled   = true
    }
  }

  # ----- Case 9. 익명 IP / Tor / 공개 프록시 (AnonymousIpList) -----
  rule {
    name     = "case9-aws-anonymous-ip"
    priority = 32
    override_action {
      none {}
    }
    statement {
      managed_rule_group_statement {
        vendor_name = "AWS"
        name        = "AWSManagedRulesAnonymousIpList"
      }
    }
    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "case9-aws-anonymous-ip"
      sampled_requests_enabled   = true
    }
  }

  # ----- Case 10. 알려진 취약점 공격 패턴 (KnownBadInputs) -----
  rule {
    name     = "case10-aws-known-bad-inputs"
    priority = 31
    override_action {
      none {}
    }
    statement {
      managed_rule_group_statement {
        vendor_name = "AWS"
        name        = "AWSManagedRulesKnownBadInputsRuleSet"
      }
    }
    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "case10-aws-known-bad-inputs"
      sampled_requests_enabled   = true
    }
  }

  # ----- Case 10b. Log4Shell(JNDI) 명시적 차단 -----
  # 관리형 KnownBadInputs가 취약 경로(ExploitablePaths)는 잡지만 바디/헤더의
  # JNDI 문자열을 놓치는 경우를 대비한 명시적 규칙. 커스텀 헤더로 식별도 가능하다.
  rule {
    name     = "case10-log4j-jndi"
    priority = 3
    action {
      block {
        custom_response {
          response_code = 403
          response_header {
            name  = "x-waf-rule"
            value = "case10-known-bad-inputs"
          }
        }
      }
    }
    statement {
      or_statement {
        statement {
          byte_match_statement {
            field_to_match {
              body {
                oversize_handling = "MATCH"
              }
            }
            positional_constraint = "CONTAINS"
            search_string         = "jndi:"
            text_transformation {
              priority = 0
              type     = "LOWERCASE"
            }
          }
        }
        statement {
          byte_match_statement {
            field_to_match {
              all_query_arguments {}
            }
            positional_constraint = "CONTAINS"
            search_string         = "jndi:"
            text_transformation {
              priority = 0
              type     = "LOWERCASE"
            }
          }
        }
        statement {
          byte_match_statement {
            field_to_match {
              uri_path {}
            }
            positional_constraint = "CONTAINS"
            search_string         = "jndi:"
            text_transformation {
              priority = 0
              type     = "LOWERCASE"
            }
          }
        }
        statement {
          byte_match_statement {
            field_to_match {
              headers {
                match_pattern {
                  all {}
                }
                match_scope       = "VALUE"
                oversize_handling = "MATCH"
              }
            }
            positional_constraint = "CONTAINS"
            search_string         = "jndi:"
            text_transformation {
              priority = 0
              type     = "LOWERCASE"
            }
          }
        }
      }
    }
    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "case10-log4j-jndi"
      sampled_requests_enabled   = true
    }
  }

  visibility_config {
    cloudwatch_metrics_enabled = true
    metric_name                = "vamserlike-backend-acl"
    sampled_requests_enabled   = true
  }

  tags = { Name = "Vamserlike-Backend-WAF" }
}

# ----- Web ACL을 ALB에 연결 -----
resource "aws_wafv2_web_acl_association" "backend" {
  resource_arn = aws_lb.alb.arn
  web_acl_arn  = aws_wafv2_web_acl.backend.arn
}

# 테스트 툴(WAF_TARGET_URL)에 넣을 ALB 주소
output "waf_target_url" {
  value       = "http://${aws_lb.alb.dns_name}"
  description = "WAF 보안 테스트 툴의 WAF_TARGET_URL 값"
}
