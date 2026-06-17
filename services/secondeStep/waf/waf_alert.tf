# =========================================================
# WAF 차단 급증 → Slack 알림 (급증형/요약)
# 흐름: BlockedRequests(5분 합계) >= 임계값 → CloudWatch 알람 → SNS → Lambda → Slack
# services/instance/ 에 두면 WAF 본체와 같은 모듈로 단일 `terraform apply` 에 포함됨.
# 같은 폴더에 waf_slack_notifier.py 도 함께 두어야 함(아래 archive_file 이 zip).
#
# 사전 준비(1회): Slack Webhook URL 을 SSM SecureString 으로 저장 (비밀은 TF state 밖에 보관)
#   aws ssm put-parameter --name "/vamserlike/waf/slack_webhook" --type SecureString \
#     --value "https://hooks.slack.com/services/XXX/YYY/ZZZ" --region ap-northeast-2
#
# [변경 이력]
#   - 알람 ok_actions 추가 → 차단 급증 종료 시 [정상] 복구 메시지도 발송
#   - Lambda 환경변수에 WAF_BLOCK_THRESHOLD 추가 → 알림 본문의 "기준" 문구가
#     알람 임계치와 항상 동기화됨
# =========================================================

variable "web_acl_name" {
  type    = string
  default = "vamserlike-backend-acl"
}

variable "waf_region" {
  type    = string
  default = "ap-northeast-2"
}

variable "slack_webhook_param" {
  type    = string
  default = "/vamserlike/waf/slack_webhook"
}

# 5분간 이 건수 이상 차단되면 알림(테스트 도배 방지를 위해 적당히 높게; 필요시 조정)
variable "waf_block_threshold" {
  type    = number
  default = 50
}

# ---------- Lambda 패키지(zip) ----------
data "archive_file" "waf_notifier" {
  type        = "zip"
  source_file = "${path.module}/waf_slack_notifier.py"
  output_path = "${path.module}/waf_slack_notifier.zip"
}

# ---------- Lambda 실행 역할 ----------
data "aws_iam_policy_document" "waf_notifier_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "waf_notifier" {
  name               = "vamserlike-waf-slack-notifier"
  assume_role_policy = data.aws_iam_policy_document.waf_notifier_assume.json
}

data "aws_iam_policy_document" "waf_notifier" {
  statement {
    sid       = "Logs"
    actions   = ["logs:CreateLogGroup", "logs:CreateLogStream", "logs:PutLogEvents"]
    resources = ["arn:aws:logs:*:*:*"]
  }
  statement {
    sid       = "ReadMetrics"
    actions   = ["cloudwatch:GetMetricData"]
    resources = ["*"] # GetMetricData 는 리소스 단위 제한 미지원
  }
  statement {
    sid       = "ReadWebhookParam"
    actions   = ["ssm:GetParameter"]
    resources = ["arn:aws:ssm:*:*:parameter${var.slack_webhook_param}"]
  }
  statement {
    sid       = "DecryptParam"
    actions   = ["kms:Decrypt"]
    resources = ["*"] # SecureString 복호화(기본 aws/ssm 키). 필요시 특정 키 ARN 으로 좁히세요.
  }
}

resource "aws_iam_role_policy" "waf_notifier" {
  name   = "vamserlike-waf-slack-notifier"
  role   = aws_iam_role.waf_notifier.id
  policy = data.aws_iam_policy_document.waf_notifier.json
}

# ---------- Lambda ----------
resource "aws_lambda_function" "waf_notifier" {
  function_name    = "vamserlike-waf-slack-notifier"
  role             = aws_iam_role.waf_notifier.arn
  runtime          = "python3.12"
  handler          = "waf_slack_notifier.handler"
  filename         = data.archive_file.waf_notifier.output_path
  source_code_hash = data.archive_file.waf_notifier.output_base64sha256
  timeout          = 15

  environment {
    variables = {
      WEB_ACL_NAME        = var.web_acl_name
      WAF_REGION          = var.waf_region
      SLACK_WEBHOOK_PARAM = var.slack_webhook_param
      WINDOW_MINUTES      = "5"
      WAF_BLOCK_THRESHOLD = tostring(var.waf_block_threshold) # 알림 본문 "기준" 문구 동기화
    }
  }
}

# ---------- SNS (알람 → Lambda 연결) ----------
resource "aws_sns_topic" "waf_alerts" {
  name = "vamserlike-waf-alerts"
}

resource "aws_sns_topic_subscription" "waf_alerts_lambda" {
  topic_arn = aws_sns_topic.waf_alerts.arn
  protocol  = "lambda"
  endpoint  = aws_lambda_function.waf_notifier.arn
}

resource "aws_lambda_permission" "allow_sns" {
  statement_id  = "AllowSNSInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.waf_notifier.function_name
  principal     = "sns.amazonaws.com"
  source_arn    = aws_sns_topic.waf_alerts.arn
}

# ---------- CloudWatch 알람 (BlockedRequests 5분 합계 >= 임계값) ----------
resource "aws_cloudwatch_metric_alarm" "waf_block_spike" {
  alarm_name        = "vamserlike-waf-block-spike"
  alarm_description = "WAF blocked requests spiked over threshold in 5 minutes"
  namespace         = "AWS/WAFV2"
  metric_name       = "BlockedRequests"
  dimensions = {
    WebACL = var.web_acl_name
    Rule   = "ALL"
    Region = var.waf_region
  }
  statistic           = "Sum"
  period              = 300
  evaluation_periods  = 1
  threshold           = var.waf_block_threshold
  comparison_operator = "GreaterThanOrEqualToThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = [aws_sns_topic.waf_alerts.arn]
  ok_actions          = [aws_sns_topic.waf_alerts.arn] # 추가: 차단 급증 종료 시 [정상] 복구 메시지
}
