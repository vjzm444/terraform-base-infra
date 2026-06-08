# 1. IAM Role 생성
resource "aws_iam_role" "backend_role" {
  name = "backend-server-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action = "sts:AssumeRole"
      Effect = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
    }]
  })
}

# 2. 필요한 정책 연결 (CloudWatchLogsFullAccess + CognitoFullAccess)
resource "aws_iam_role_policy_attachment" "cw_access" {
  role       = aws_iam_role.backend_role.name
  policy_arn = "arn:aws:iam::aws:policy/CloudWatchLogsFullAccess"
}

resource "aws_iam_role_policy_attachment" "cognito_access" {
  role       = aws_iam_role.backend_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonCognitoPowerUser" # 또는 CognitoFullAccess
}

# 3. Instance Profile 생성 (인스턴스에 붙이기 위한 필수 단계)
resource "aws_iam_instance_profile" "backend_profile" {
  name = "backend-instance-profile"
  role = aws_iam_role.backend_role.name
}