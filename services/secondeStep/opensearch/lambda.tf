

# 3. 람다 소스 코드 압축 (lambda/ 폴더에 index.js가 있다고 가정)
data "archive_file" "lambda_zip" {
  type        = "zip"
  source_file = "${path.module}/index.mjs"
  output_path = "${path.module}/index.zip"
}

# 4. 람다 함수 생성 (Node.js 22)
resource "aws_lambda_function" "vpc_flow_lambda" {
  function_name    = "VPCFlowLogs-To-Firehose-Function"
  filename         = data.archive_file.lambda_zip.output_path
  source_code_hash = data.archive_file.lambda_zip.output_base64sha256
  
  handler = "index.handler"
  runtime = "nodejs22.x" # 최신 22 버전
  role    = aws_iam_role.lambda_role.arn

  environment {
    variables = {
      DELIVERY_STREAM_NAME  = "vpc-flow-firehose"
    }
  }
}

# 1. 람다 실행용 IAM 역할 생성
resource "aws_iam_role" "lambda_role" {
  name = "LambdaExecutionRoleForVPCFlow"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action = "sts:AssumeRole"
      Effect = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
    }]
  })
}

# 2. 요청한 커스텀 정책 생성 및 연결
resource "aws_iam_role_policy" "lambda_policy" {
  name = "LambdaVPCFLowLogsToFirehosePolicy2"
  role = aws_iam_role.lambda_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "AllowLambdaLogs"
        Effect = "Allow"
        Action = [
          "logs:CreateLogGroup",
          "logs:CreateLogStream",
          "logs:PutLogEvents"
        ]
        Resource = "*"
      },
      {
        Sid    = "AllowPutRecordsToFirehose"
        Effect = "Allow"
        Action = [
          "firehose:PutRecord",
          "firehose:PutRecordBatch"
        ]
        Resource = "arn:aws:firehose:ap-northeast-2:${local.account_id}:deliverystream/vpc-flow-firehose"
      }
    ]
  })
}