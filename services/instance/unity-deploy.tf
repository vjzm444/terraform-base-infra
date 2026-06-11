
# 1. 아테나로 보낼 s3용(CloudFormation에서 사용예정)
resource "aws_s3_bucket" "vamserlike-logs-bucket" {
  # 예: "vjzm44-vamserlike-backend-logs"
  bucket = "${local.account_id}-vamserlike-backend-logs"
  force_destroy = true
}

# 1. 파이프라인용 아티팩트 버킷 생성 (이름을 고정해버리자)
resource "aws_s3_bucket" "artifact_bucket" {
  # 예: "vjzm44-artifacts"
  bucket        = "${local.account_id}-pipeline-artifacts"
  force_destroy = true
}

resource "aws_s3_bucket" "deploy_bucket" {
  # 예: "vjzm44" + "-" + "vamserlike" = "vjzm44-vamserlike"
  bucket        = "${local.account_id}-unity-vamserlike"
  force_destroy = true
}


//파이프라인
resource "aws_codepipeline" "pipeline" {
  name     = "unity-pipeline"
  role_arn = aws_iam_role.pipeline_role.arn

  artifact_store {
    location = aws_s3_bucket.artifact_bucket.bucket
    type     = "S3"
  }

  stage {
    name = "Source"
    action {
      name             = "Source"
      category         = "Source"
      owner            = "AWS"
      provider         = "CodeStarSourceConnection"
      version          = "1"
      output_artifacts = ["SourceArtifact"]
      configuration = {
        # 변수(var)를 여기서 호출!
        ConnectionArn    = var.github_connection_arn

        # 유니티게임버킷(git계정에 초대를 받아야 접근가능!)
        FullRepositoryId = "vjzm444/vamserlike-unity"
        BranchName       = "main"
      }
    }
  }

  stage {
    name = "Deploy"
    action {
      name            = "Deploy"
      category        = "Deploy"
      owner           = "AWS"
      provider        = "S3"
      input_artifacts = ["SourceArtifact"]
      version         = "1"
      configuration = {
        BucketName = "${local.account_id}-unity-vamserlike"
        Extract    = "true" 
      }
    }
  }
}



# 1. 파이프라인용 깡통 IAM 역할 생성
resource "aws_iam_role" "pipeline_role" {
  name = "newFifeline3"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action = "sts:AssumeRole"
      Effect = "Allow"
      Principal = { Service = "codepipeline.amazonaws.com" }
    }]
  })
}

resource "aws_iam_role_policy" "pipeline_policy" {
  name = "s3-access-policy"
  role = aws_iam_role.pipeline_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        # S3 데이터 접근 + Git 연결 권한
        Effect = "Allow"
        Action = [
          "s3:PutObject",
          "s3:GetObject",
          "s3:GetObjectVersion",
          "s3:GetBucketVersioning",
          "codestar-connections:UseConnection"
        ]
        Resource = [
          "${aws_s3_bucket.artifact_bucket.arn}",
          "${aws_s3_bucket.artifact_bucket.arn}/*",
          "${aws_s3_bucket.deploy_bucket.arn}",
          "${aws_s3_bucket.deploy_bucket.arn}/*",
          var.github_connection_arn
        ]
      },
      {
        # 파이프라인 제어 권한 (locals 활용)
        Effect = "Allow"
        Action = [
          "codepipeline:GetPipeline",
          "codepipeline:GetPipelineExecution",
          "codepipeline:GetPipelineState",
          "codepipeline:StartPipelineExecution",
          "codepipeline:PutJobSuccessResult",
          "codepipeline:PutJobFailureResult"
        ]
        Resource = [
          "arn:aws:codepipeline:ap-northeast-2:${local.account_id}:unity-pipeline"
        ]
      }
    ]
  })
}


#클라우드 프론트쪽 설정 ######################

# 1. CloudFront OAC (S3 비공개 접근용)
resource "aws_cloudfront_origin_access_control" "oac" {
  name                              = "s3-oac"
  origin_access_control_origin_type = "s3"
  signing_behavior                  = "always"
  signing_protocol                  = "sigv4"
}

# 2. CloudFront 배포
resource "aws_cloudfront_distribution" "s3_distribution" {
  enabled             = true
  default_root_object = "index.html"

  origin {
    domain_name              = aws_s3_bucket.deploy_bucket.bucket_regional_domain_name
    origin_id                = "S3-Origin"
    origin_access_control_id = aws_cloudfront_origin_access_control.oac.id
  }

  default_cache_behavior {
    allowed_methods  = ["GET", "HEAD"]
    cached_methods   = ["GET", "HEAD"]
    target_origin_id = "S3-Origin"
    viewer_protocol_policy = "redirect-to-https"
    forwarded_values {
      query_string = false
      cookies { forward = "none" }
    }
  }

  restrictions {
    geo_restriction { restriction_type = "none" }
  }

  viewer_certificate {
    cloudfront_default_certificate = true
  }
}

# 3. S3 버킷 정책 (OAC와 자동 연동)
resource "aws_s3_bucket_policy" "allow_cloudfront" {
  bucket = aws_s3_bucket.deploy_bucket.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid    = "AllowCloudFrontServicePrincipalReadOnly"
      Effect = "Allow"
      Principal = { Service = "cloudfront.amazonaws.com" }
      Action   = "s3:GetObject"
      Resource = "${aws_s3_bucket.deploy_bucket.arn}/*"
      Condition = {
        StringEquals = {
          "AWS:SourceArn" = aws_cloudfront_distribution.s3_distribution.arn
        }
      }
    }]
  })
}