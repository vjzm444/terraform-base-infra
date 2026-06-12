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
  default     = ["KR", "US", "JP"] # 허용할 국가 코드 (한국, 미국, 일본)
}

variable "waf_rate_limit" {
  description = "Rate-based 규칙 임계값 (5분 / IP). WAFv2 최소값 100."
  type        = number
  default     = 100 # 5분당 허용되는 최대 요청 수
}

resource "aws_wafv2_web_acl" "backend" {
  name        = "vamserlike-backend-acl"
  description = "Vamserlike backend protection spec v11"
  scope       = "REGIONAL" # ALB(리전 리소스)에 연결하기 위해 설정

  default_action {
    allow {} # 아래 규칙들에 해당하지 않는 모든 정상 트래픽은 기본 허용
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
            value = "case1-geo-allowlist" # 테스트 툴이 차단 원인을 식별할 커스텀 헤더
          }
        }
      }
    }
    statement {
      not_statement { # 아래 조건(허용 국가)에 '해당하지 않는' 요청 차단
        statement {
          geo_match_statement {
            country_codes = var.allowed_country_codes # ["KR", "US", "JP"]
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
        limit                 = var.waf_rate_limit # 100회 초과 시 차단 발동
        aggregate_key_type    = "IP" # 출발지 IP 주소를 기준으로 카운팅
        evaluation_window_sec = 300 # 5분(300초) 동안의 요청량 측정
        scope_down_statement {
          byte_match_statement {
            field_to_match {
              uri_path {}
            }
            positional_constraint = "STARTS_WITH" # 아래 경로로 시작하는 요청만 집계
            search_string         = "/api/players/ranking" # 랭킹 조회 API 대상 (서버 요금 방어)
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
            search_string         = "/api/players/me/characters/unlock" # 캐릭터 해금 API 대상
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
            search_string         = "/api/players/me/progress" # 결과 저장 API 대상 (재화 무한 복사 핵 방어)
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
  rule {
    name     = "case4-aws-common-ruleset"
    priority = 30
    override_action {
      none {}
    }
    statement {
      managed_rule_group_statement {
        vendor_name = "AWS" # AWS에서 기본 제공하는 관리형 룰셋 사용
        name        = "AWSManagedRulesCommonRuleSet" # XSS 및 보편적 웹 취약점 방어
      }
    }
    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "case4-aws-common-ruleset"
      sampled_requests_enabled   = true
    }
  }

  # ----- Case 4b. SQL 인젝션 차단 (SQLiRuleSet) -----
  rule {
    name     = "case4-aws-sqli-ruleset"
    priority = 33
    override_action {
      none {}
    }
    statement {
      managed_rule_group_statement {
        vendor_name = "AWS"
        name        = "AWSManagedRulesSQLiRuleSet" # 정밀한 SQL Injection 패턴 탐지 및 차단
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
            oversize_handling = "MATCH" # WAF 검사 한도(8KB) 초과 시 무조건 차단 처리
          }
        }
        comparison_operator = "GT" # 초과 (Greater Than)
        size                = 8192 # 8KB 크기 제한
        text_transformation {
          priority = 0
          type     = "NONE" # 텍스트 변환 없이 원본 크기 그대로 검사
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
            search_string         = "/api/auth/login" # 로그인 API 대상 (무차별 대입 공격 방어)
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
            search_string         = "/api/auth/signup" # 회원가입 API 대상 (봇 대량생성 방어)
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
          for_each = ["sqlmap", "nikto", "zgrab", "selenium", "puppeteer"] # 탐지할 해킹/자동화 툴 키워드
          content {
            byte_match_statement {
              field_to_match {
                single_header {
                  name = "user-agent" # HTTP User-Agent 헤더 검사
                }
              }
              positional_constraint = "CONTAINS" # 해당 키워드가 포함되어 있으면 차단
              search_string         = statement.value
              text_transformation {
                priority = 0
                type     = "LOWERCASE" # 대소문자 구분 없이 탐지하기 위해 소문자로 변환
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
        name        = "AWSManagedRulesAnonymousIpList" # VPN, Tor 등 우회 목적의 익명 IP 접근 차단
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
        name        = "AWSManagedRulesKnownBadInputsRuleSet" # Log4j 등 잘 알려진 취약점 페이로드 차단
      }
    }
    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "case10-aws-known-bad-inputs"
      sampled_requests_enabled   = true
    }
  }

  # ----- Case 10b. Log4Shell(JNDI) 명시적 차단 -----
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
        # 바디, 파라미터, 주소, 헤더 내에 jndi: 패턴이 포함되어 있는지 각각 검사
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

# 테스트 툴(WAF_TARGET_URL)에 넣을 ALB 주소
output "waf_target_url" {
  value       = "http://${aws_lb.alb.dns_name}" # 테스트 툴 환경변수에 바로 복붙할 수 있도록 터미널에 출력
  description = "WAF 보안 테스트 툴의 WAF_TARGET_URL 값"
}