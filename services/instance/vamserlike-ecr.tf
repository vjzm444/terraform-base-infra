# =========================================================
# Vamserlike Project - ECR
#
# 목적:
# - 팀원별 AWS 계정에 backend 이미지 저장소를 자동 생성
# - bootstrap-vamserlike.sh에서 Docker build 후 이 ECR로 push
# - EKS/Argo CD 배포 시 현재 계정 ECR 이미지를 사용
# =========================================================

data "aws_caller_identity" "current" {}

locals {
  account_id = data.aws_caller_identity.current.account_id
}

resource "aws_ecr_repository" "vamserlike_backend" {
  name                 = "vamserlike-backend"
  image_tag_mutability = "MUTABLE"
  force_delete         = true

  image_scanning_configuration {
    scan_on_push = true
  }

  tags = {
    Project = "vamserlike"
    Managed = "terraform"
  }
}

output "vamserlike_ecr_repository_name" {
  value       = aws_ecr_repository.vamserlike_backend.name
  description = "Vamserlike backend ECR repository name"
}

output "vamserlike_ecr_repository_url" {
  value       = aws_ecr_repository.vamserlike_backend.repository_url
  description = "Vamserlike backend ECR repository URL"
}

output "vamserlike_account_id" {
  value       = local.account_id
  description = "Current AWS Account ID"
}