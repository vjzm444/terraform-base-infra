# =========================================================
# Vamserlike Project - K8s Manager IAM Role + EKS/ALB Tags
# 기존 main.tf는 수정하지 않고, EKS 준비 설정만 별도 tf 파일로 추가
# =========================================================

# ---------------------------------------------------------
# K8s Manager EC2용 IAM Role
# - EC2에서 eksctl, kubectl, helm, aws cli 작업 수행
# - 프로젝트 편의상 AdministratorAccess 부여
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

# AdministratorAccess 정책 연결
resource "aws_iam_role_policy_attachment" "eksworkspace_admin_attach" {
  role       = aws_iam_role.eksworkspace_admin_role.name
  policy_arn = "arn:aws:iam::aws:policy/AdministratorAccess"
}

# EC2에 붙일 Instance Profile 생성
resource "aws_iam_instance_profile" "eksworkspace_admin_profile" {
  name = "eksworkspace-admin-profile"
  role = aws_iam_role.eksworkspace_admin_role.name
}

# ---------------------------------------------------------
# 기존 main.tf의 aws_instance 블록을 수정하지 않기 위해
# AWS CLI로 K8s Manager EC2에 IAM Instance Profile 연결
#
# 주의:
# - Terraform 실행 PC에 AWS CLI 인증이 되어 있어야 함
# - main.tf 수정 없이 별도 tf 파일만으로 IAM Role을 연결하기 위한 우회 방식
# ---------------------------------------------------------
resource "null_resource" "associate_k8s_manager_instance_profile" {
  triggers = {
    instance_id = aws_instance.k8s_manager_instance.id
    profile_arn = aws_iam_instance_profile.eksworkspace_admin_profile.arn
  }

  depends_on = [
    aws_instance.k8s_manager_instance,
    aws_iam_instance_profile.eksworkspace_admin_profile,
    aws_iam_role_policy_attachment.eksworkspace_admin_attach
  ]

  provisioner "local-exec" {
    interpreter = ["PowerShell", "-NoProfile", "-ExecutionPolicy", "Bypass", "-Command"]

    command = <<-EOT
      $instanceId = "${aws_instance.k8s_manager_instance.id}"
      $profileArn = "${aws_iam_instance_profile.eksworkspace_admin_profile.arn}"
      $region = "ap-northeast-2"

      Write-Host "Checking IAM instance profile association for instance: $instanceId"

      $associationId = aws ec2 describe-iam-instance-profile-associations `
        --region $region `
        --filters "Name=instance-id,Values=$instanceId" `
        --query "IamInstanceProfileAssociations[?State=='associated' || State=='associating'].AssociationId | [0]" `
        --output text

      if ($associationId -and $associationId -ne "None") {
        Write-Host "Existing association found: $associationId"
        Write-Host "Replacing IAM instance profile..."

        aws ec2 replace-iam-instance-profile-association `
          --region $region `
          --association-id $associationId `
          --iam-instance-profile Arn=$profileArn
      }
      else {
        Write-Host "No association found."
        Write-Host "Associating IAM instance profile..."

        aws ec2 associate-iam-instance-profile `
          --region $region `
          --instance-id $instanceId `
          --iam-instance-profile Arn=$profileArn
      }
    EOT
  }
}

# ---------------------------------------------------------
# EKS / AWS Load Balancer Controller용 Subnet Tags
# Public Subnet: internet-facing ALB용
# Private Subnet: internal ELB / EKS private nodegroup용
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