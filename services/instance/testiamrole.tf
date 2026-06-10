# 1. IAM Role 생성

# private_Backend_test 내부인스턴스가 사용하고있음.
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

# 2. 클라우드워치 로그 권한
resource "aws_iam_role_policy_attachment" "cw_access" {
  role       = aws_iam_role.backend_role.name
  policy_arn = "arn:aws:iam::aws:policy/CloudWatchLogsFullAccess"
}

# 3. 코그니토 권한
resource "aws_iam_role_policy_attachment" "cognito_access" {
  role       = aws_iam_role.backend_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonCognitoPowerUser" # 또는 CognitoFullAccess
}


# 4. Grafana에서 아테나를 봐야되기에 관련권한(TODO: 추후 기영 Grafana인스턴스에 부착예정)
resource "aws_iam_role_policy" "athena_access_policy" {
  name = "athena-access-policy"
  role = aws_iam_role.backend_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "athena:ListDataCatalogs",
          "athena:ListDatabases",
          "athena:ListTableMetadata",
          "athena:GetTable",
          "athena:StartQueryExecution",
          "athena:GetQueryExecution",
          "athena:GetQueryResults",
          "athena:ListWorkGroups",
          "athena:GetWorkGroup"
        ]
        Resource = "*"
      },
      {
        Effect = "Allow"
        Action = [
          "glue:GetDatabase",
          "glue:GetDatabases",
          "glue:GetTable",
          "glue:GetTables",
          "glue:GetPartition",
          "glue:GetPartitions"
        ]
        Resource = "*"
      },
      {
        Effect = "Allow"
        Action = [
          "s3:GetBucketLocation",
          "s3:GetObject",
          "s3:ListBucket",
          "s3:PutObject"
        ]
        Resource = [
          aws_s3_bucket.vamserlike-logs-bucket.arn,
          "${aws_s3_bucket.vamserlike-logs-bucket.arn}/*"
        ]
      }
    ]
  })
}

# 3. Instance Profile 생성 (인스턴스에 붙이기 위한 필수 단계)
resource "aws_iam_instance_profile" "backend_profile" {
  name = "backend-instance-profile"
  role = aws_iam_role.backend_role.name
}
