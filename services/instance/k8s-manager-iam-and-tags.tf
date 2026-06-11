# =========================================================
# Vamserlike Project - K8s Manager IAM Role + EKS/ALB Tags
#
# 목적:
# - K8s Manager EC2에서 eksctl, kubectl, helm, aws cli, ECR push 작업 수행
# - AWS Load Balancer Controller가 ALB/NLB를 만들 수 있도록 Subnet Tag 설정
#
# 주의:
# - main.tf의 aws_instance.k8s_manager_instance에서
#   iam_instance_profile을 직접 연결하므로 local-exec/null_resource는 사용하지 않음
# =========================================================

# ---------------------------------------------------------
# K8s Manager EC2용 IAM Role
# - EC2에서 EKS 생성/삭제
# - AWS Load Balancer Controller IAM Policy 생성
# - IAM ServiceAccount 생성
# - ECR 로그인 / 이미지 push
# - CloudWatch Logs 설정
# - 프로젝트 시연 편의상 AdministratorAccess 부여
# ---------------------------------------------------------
resource "aws_iam_role" "eksworkspace_admin_role" {
  name = "eksworkspace-admin"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Service = "ec2.amazonaws.com"
        }
        Action = "sts:AssumeRole"
      }
    ]
  })

  tags = {
    Name    = "eksworkspace-admin"
    Project = "vamserlike"
    Owner   = "rlduddl5519"
  }
}

# ---------------------------------------------------------
# AdministratorAccess 정책 연결
#
# 포함되는 작업:
# - eksctl create/delete cluster
# - iamserviceaccount 생성/삭제
# - ECR describe/create/login/push
# - CloudWatch Logs
# - ELB/ALB 관련 작업
# ---------------------------------------------------------
resource "aws_iam_role_policy_attachment" "eksworkspace_admin_attach" {
  role       = aws_iam_role.eksworkspace_admin_role.name
  policy_arn = "arn:aws:iam::aws:policy/AdministratorAccess"
}

# ---------------------------------------------------------
# EC2에 붙일 Instance Profile
#
# main.tf:
# iam_instance_profile = aws_iam_instance_profile.eksworkspace_admin_profile.name
# ---------------------------------------------------------
resource "aws_iam_instance_profile" "eksworkspace_admin_profile" {
  name = "eksworkspace-admin-profile"
  role = aws_iam_role.eksworkspace_admin_role.name
}

# ---------------------------------------------------------
# EKS / AWS Load Balancer Controller용 Subnet Tags
#
# Public Subnet:
# - internet-facing ALB/NLB 생성용
#
# Private Subnet:
# - internal ELB / EKS private nodegroup용
# ---------------------------------------------------------

resource "aws_ec2_tag" "public_subnet_cluster_tag" {
  resource_id = aws_subnet.public_subnet.id
  key         = "kubernetes.io/cluster/eks-demo"
  value       = "shared"
}

resource "aws_ec2_tag" "public_subnet_elb_tag" {
  resource_id = aws_subnet.public_subnet.id
  key         = "kubernetes.io/role/elb"
  value       = "1"
}

resource "aws_ec2_tag" "public_subnet2_cluster_tag" {
  resource_id = aws_subnet.public_subnet2.id
  key         = "kubernetes.io/cluster/eks-demo"
  value       = "shared"
}

resource "aws_ec2_tag" "public_subnet2_elb_tag" {
  resource_id = aws_subnet.public_subnet2.id
  key         = "kubernetes.io/role/elb"
  value       = "1"
}

resource "aws_ec2_tag" "private_subnet_cluster_tag" {
  resource_id = aws_subnet.private_subnet.id
  key         = "kubernetes.io/cluster/eks-demo"
  value       = "shared"
}

resource "aws_ec2_tag" "private_subnet_internal_elb_tag" {
  resource_id = aws_subnet.private_subnet.id
  key         = "kubernetes.io/role/internal-elb"
  value       = "1"
}

resource "aws_ec2_tag" "private_subnet2_cluster_tag" {
  resource_id = aws_subnet.private_subnet2.id
  key         = "kubernetes.io/cluster/eks-demo"
  value       = "shared"
}

resource "aws_ec2_tag" "private_subnet2_internal_elb_tag" {
  resource_id = aws_subnet.private_subnet2.id
  key         = "kubernetes.io/role/internal-elb"
  value       = "1"
}