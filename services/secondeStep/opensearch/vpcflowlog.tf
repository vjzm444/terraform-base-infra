# 1. CloudWatch Log Group 생성
resource "aws_cloudwatch_log_group" "vpc_flow_log_group" {
  name              = "/vpc/flowlogs"
  retention_in_days = 7 # 보존 기간
}

# 2. VPC Flow Logs용 IAM 역할 생성
resource "aws_iam_role" "vpc_flow_log_role" {
  name = "VPCFlowLogsRole"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid    = "AllowVPCFlowLogsServiceAssumeRole"
      Effect = "Allow"
      Principal = {
        Service = "vpc-flow-logs.amazonaws.com"
      }
      Action = "sts:AssumeRole"
    }]
  })
}

# 3. 역할에 인라인 정책(VPCFlowLogsToCloudWatchPolicy) 연결
resource "aws_iam_role_policy" "vpc_flow_log_policy" {
  name = "VPCFlowLogsToCloudWatchPolicy"
  role = aws_iam_role.vpc_flow_log_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid    = "AllowPublishFlowLogsToCloudWatchLogs"
      Effect = "Allow"
      Action = [
        "logs:CreateLogGroup",
        "logs:CreateLogStream",
        "logs:PutLogEvents",
        "logs:DescribeLogGroups",
        "logs:DescribeLogStreams"
      ]
      Resource = "*"
    }]
  })
}

# 4. VPC Flow Log 생성
resource "aws_flow_log" "vpc_flow_log" {
  # vpc_id는 기존에 있는 네 VPC ID를 넣으면 돼
  vpc_id               = var.vpc_id
  traffic_type         = "ALL"
  log_destination_type = "cloud-watch-logs"
  log_destination      = aws_cloudwatch_log_group.vpc_flow_log_group.arn
  iam_role_arn         = aws_iam_role.vpc_flow_log_role.arn
}


# 1. 람다 실행 권한 설정
resource "aws_lambda_permission" "allow_cloudwatch" {
  statement_id  = "AllowCloudWatchLogsInvokeAccess"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.vpc_flow_lambda.function_name
  principal     = "logs.ap-northeast-2.amazonaws.com"
  source_arn    = "${aws_cloudwatch_log_group.vpc_flow_log_group.arn}:*"
}

# 2. 구독 필터 생성 (depends_on 추가!)
resource "aws_cloudwatch_log_subscription_filter" "vpc_flow_to_lambda" {
  name            = "vpc-flow-to-lambda"
  log_group_name  = aws_cloudwatch_log_group.vpc_flow_log_group.name
  filter_pattern  = "" 
  destination_arn = aws_lambda_function.vpc_flow_lambda.arn

  # 핵심: 람다 권한이 먼저 설정된 후 이 작업이 수행되도록 강제함
  depends_on = [aws_lambda_permission.allow_cloudwatch]
}