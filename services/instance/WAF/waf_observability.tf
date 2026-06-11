# =========================================================
# WAF 관측(Observability) 일괄 구성
# services/instance/ 에 두면 waf.tf 의 aws_wafv2_web_acl.backend 와 '같은 모듈'이라,
# 단일 `terraform apply` 에서 WAF 본체와 함께 생성됩니다.
#   (1) 전체 요청 로깅 → CloudWatch Logs (요청 단위 증거)
#   (2) 케이스별 차단을 보여주는 CloudWatch 대시보드
#
# ※ 이 파일 하나로 로깅+대시보드를 모두 담습니다.
#    앞서 받은 waf_logging.tf 는 같은 폴더에 두지 마세요 (resource 중복 정의 에러 발생).
# ※ 같은 폴더에 waf_cloudwatch_dashboard.json 도 함께 두어야 합니다 (대시보드가 이 파일을 읽음).
# =========================================================

# (1) 전체 요청 로깅 → CloudWatch Logs
#     로그 그룹 이름은 반드시 'aws-waf-logs-' 로 시작해야 함 (AWS 강제 규칙)
resource "aws_cloudwatch_log_group" "waf" {
  name              = "aws-waf-logs-vamserlike-backend"
  retention_in_days = 14
}

resource "aws_wafv2_web_acl_logging_configuration" "backend" {
  resource_arn = aws_wafv2_web_acl.backend.arn

  # CloudWatch Logs 대상 ARN은 끝의 ":*" 를 제거해야 적용됨
  log_destination_configs = [
    replace(aws_cloudwatch_log_group.waf.arn, ":*", "")
  ]
}

# (2) 케이스별 차단 대시보드
#     같은 폴더의 waf_cloudwatch_dashboard.json 을 그대로 본문으로 사용
resource "aws_cloudwatch_dashboard" "waf" {
  dashboard_name = "vamserlike-waf"
  dashboard_body = file("${path.module}/waf_cloudwatch_dashboard.json")
}
