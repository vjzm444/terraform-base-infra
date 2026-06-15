terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0" # 5.0 이상 버전이 있어야 보안 옵션 블록들이 다 작동해!
    }
  }
}


data "aws_caller_identity" "current" {}

locals {
  account_id = data.aws_caller_identity.current.account_id
}

# 1. S3
resource "aws_s3_bucket" "vamserlike-logs-bucket2" {
  bucket = "${local.account_id}-firehose-vpc-flow-backup"
  force_destroy = true
}


//OpenSearch
resource "aws_opensearch_domain" "vpc_flow_domain" {
  domain_name    = "vpc-flow-log-domain"
  engine_version = "OpenSearch_2.11"

  # 1. 보안 설정 (필수 블록)
  encrypt_at_rest {
    enabled = true
  }

  node_to_node_encryption {
    enabled = true
  }

  domain_endpoint_options {
    enforce_https       = true
    tls_security_policy = "Policy-Min-TLS-1-2-2019-07"
  }

  advanced_security_options {
    enabled                        = true
    internal_user_database_enabled = true
    anonymous_auth_enabled         = false  # <--- 이 부분이 false인지 확인해!
    master_user_options {
      master_user_name     = "admin"
      master_user_password = "P@ssw0rd"
    }
  }

  # 2. 클러스터 설정
  cluster_config {
    instance_type            = "t3.small.search"
    instance_count           = 3
    zone_awareness_enabled   = true
    zone_awareness_config {
      availability_zone_count = 3
    }
  }

  ebs_options {
    ebs_enabled = true
    volume_size = 10
  }
}

resource "aws_opensearch_domain_policy" "main" {
  domain_name = aws_opensearch_domain.vpc_flow_domain.domain_name

  access_policies = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "AllowFirehoseWrite"
        Effect = "Allow"
        Principal = { AWS = aws_iam_role.firehose_role.arn }
        Action   = ["es:ESHttpGet", "es:ESHttpPost", "es:ESHttpPut"]
        Resource = "arn:aws:es:ap-northeast-2:${local.account_id}:domain/vpc-flow-log-domain/*"
      },
      {
        Sid    = "AllowDashboardAccessFromMyIP"
        Effect = "Allow"
        Principal = { AWS = "*" }
        Action   = ["es:ESHttpGet", "es:ESHttpPost", "es:ESHttpPut", "es:ESHttpDelete"]
        Resource = "arn:aws:es:ap-northeast-2:${local.account_id}:domain/vpc-flow-log-domain/*"
        Condition = {
          IpAddress = {
            "aws:SourceIp" = ["180.80.107.14/32", "121.160.42.57/32"]
          }
        }
      }
    ]
  })
}

# 1. IAM 역할 생성 (Firehose가 사용할 역할)
resource "aws_iam_role" "firehose_role" {
  name = "FirehoseToOpenSearchRole2"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action = "sts:AssumeRole"
      Effect = "Allow"
      Principal = {
        Service = "firehose.amazonaws.com"
      }
    }]
  })
}

# 2. 역할에 정책 연결
resource "aws_iam_role_policy" "firehose_policy" {
  name = "FirehoseToOpenSearchPcdolicy"
  role = aws_iam_role.firehose_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "AllowWriteToOpenSearch"
        Effect = "Allow"
        Action = [
          "es:DescribeElasticsearchDomain",
          "es:DescribeElasticsearchDomains",
          "es:DescribeElasticsearchDomainConfig",
          "es:ESHttpGet",
          "es:ESHttpPost",
          "es:ESHttpPut"
        ]
        Resource = [
          "${aws_opensearch_domain.vpc_flow_domain.arn}",
          "${aws_opensearch_domain.vpc_flow_domain.arn}/*"
        ]
      },
      {
        Sid    = "AllowS3Backup"
        Effect = "Allow"
        Action = [
          "s3:AbortMultipartUpload",
          "s3:GetBucketLocation",
          "s3:GetObject",
          "s3:ListBucket",
          "s3:ListBucketMultipartUploads",
          "s3:PutObject"
        ]
        Resource = [
          "arn:aws:s3:::${local.account_id}-firehose-vpc-flow-backup",
          "arn:aws:s3:::${local.account_id}-firehose-vpc-flow-backup/*"
        ]
      },
      {
        Sid    = "AllowFirehoseLogging"
        Effect = "Allow"
        Action = [
          "logs:CreateLogGroup",
          "logs:CreateLogStream",
          "logs:PutLogEvents"
        ]
        Resource = "*"
      }
    ]
  })
}

//파이어호스
resource "aws_kinesis_firehose_delivery_stream" "vpc_flow_firehose" {
  name        = "vpc-flow-firehose"
  destination = "opensearch"

  opensearch_configuration {
    domain_arn         = aws_opensearch_domain.vpc_flow_domain.arn
    role_arn           = aws_iam_role.firehose_role.arn
    index_name         = "vpc-flow-logs"
    
    # 날짜별 인덱스 생성 끄기 (None으로 설정)
    index_rotation_period = "NoRotation"

    buffering_size     = 1
    buffering_interval = 60

    processing_configuration {
      enabled = false
    }

    # "Disabled" 대신 "FailedDocumentsOnly" 사용 (성공 시엔 S3에 안 남음)
    s3_backup_mode = "FailedDocumentsOnly"

    # [중요] S3 설정은 opensearch_configuration 블록 안으로
    s3_configuration {
      role_arn           = aws_iam_role.firehose_role.arn
      bucket_arn         = aws_s3_bucket.vamserlike-logs-bucket2.arn
      buffering_size     = 1
      buffering_interval = 60
    }
  }
}