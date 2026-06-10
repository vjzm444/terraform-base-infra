# =========================================================
# Vamserlike Project - K8s Manager EC2 Assets Upload
#
# 목적:
# - terraform apply 후 K8s Manager EC2에 git clone 없이 바로 실행 가능하게 구성
# - bootstrap-vamserlike.sh 자동 업로드
# - cleanup-vamserlike.sh 자동 업로드
# - vamserlike.env 자동 생성
# - Cognito UserPoolId / ClientId 자동 주입
# - 실행 권한 자동 부여
#
# EC2 접속 후 실행:
# ./bootstrap-vamserlike.sh
# ./cleanup-vamserlike.sh
# =========================================================

variable "k8s_manager_private_key_path" {
  description = "K8s Manager EC2 접속에 사용할 private key 경로"
  type        = string
  default     = "C:/Vamserlike/thdguswn0005_seoul_v2.pem"
}

variable "vamserlike_manifest_repo_url" {
  description = "Argo CD가 바라볼 Vamserlike Kubernetes manifest repository URL"
  type        = string
  default     = "https://github.com/rlduddl/Vamserlike-k8s-manifests.git"
}

variable "vamserlike_manifest_path" {
  description = "Manifest repository 안에서 Argo CD Application이 바라볼 path"
  type        = string
  default     = "overlays/dev"
}

variable "vamserlike_argocd_app_name" {
  description = "Argo CD Application name"
  type        = string
  default     = "vamserlike-backend"
}

variable "vamserlike_eks_cluster_name" {
  description = "EKS Cluster name"
  type        = string
  default     = "eks-demo"
}

variable "vamserlike_eks_nodegroup_name" {
  description = "EKS Managed NodeGroup name"
  type        = string
  default     = "vamserlike-node-group"
}

variable "vamserlike_vpc_cidr" {
  description = "Terraform base infra VPC CIDR"
  type        = string
  default     = "10.40.0.0/16"
}

variable "vamserlike_ecr_repository" {
  description = "Vamserlike backend ECR repository name"
  type        = string
  default     = "vamserlike-backend"
}

variable "vamserlike_monitoring_enabled" {
  description = "Install Prometheus/Grafana monitoring stack during bootstrap"
  type        = bool
  default     = true
}

variable "vamserlike_grafana_admin_password" {
  description = "Grafana admin password"
  type        = string
  default     = "Vamserlike123!"
  sensitive   = true
}

variable "vamserlike_grafana_release_name" {
  description = "Helm release name for kube-prometheus-stack"
  type        = string
  default     = "vamserlike-monitoring"
}

variable "vamserlike_grafana_admin_secret_name" {
  description = "Grafana admin secret name"
  type        = string
  default     = "vamserlike-grafana-admin"
}

variable "vamserlike_delete_cloudwatch_log_group" {
  description = "Delete CloudWatch log group during cleanup"
  type        = bool
  default     = false
}

variable "vamserlike_backend_log_group_name" {
  description = "CloudWatch log group name for backend logs"
  type        = string
  default     = "/ec2/vamserlike-backend"
}

variable "vamserlike_mysql_connection_string" {
  description = "Optional MySQL connection string. 비워두면 EC2에서 scripts/vamserlike.env의 DB 부분만 수정해서 사용"
  type        = string
  default     = ""
  sensitive   = true
}

locals {
  vamserlike_mysql_connection_string_value = (
    var.vamserlike_mysql_connection_string != ""
    ? var.vamserlike_mysql_connection_string
    : "Server=CHANGE_ME;Port=3306;Database=vamserlike;User=CHANGE_ME;Password=CHANGE_ME;SslMode=Preferred;AllowPublicKeyRetrieval=True;"
  )

  # shell source 가능한 single quote escape 처리
  vamserlike_mysql_connection_string_shell = replace(
    local.vamserlike_mysql_connection_string_value,
    "'",
    "'\"'\"'"
  )

  vamserlike_grafana_admin_password_shell = replace(
    var.vamserlike_grafana_admin_password,
    "'",
    "'\"'\"'"
  )

  vamserlike_monitoring_enabled_value = var.vamserlike_monitoring_enabled ? "true" : "false"
  vamserlike_delete_log_group_value   = var.vamserlike_delete_cloudwatch_log_group ? "true" : "false"
}

resource "null_resource" "upload_vamserlike_assets_to_k8s_manager" {
  triggers = {
    instance_id        = aws_instance.k8s_manager_instance.id
    instance_public_ip = aws_instance.k8s_manager_instance.public_ip

    bootstrap_sha   = filesha256("${path.module}/scripts/bootstrap-vamserlike.sh")
    cleanup_sha     = filesha256("${path.module}/scripts/cleanup-vamserlike.sh")
    env_example_sha = filesha256("${path.module}/scripts/vamserlike.env.example")

    cognito_user_pool_id = aws_cognito_user_pool.vamserlike_user_pool.id
    cognito_client_id    = aws_cognito_user_pool_client.vamserlike_app_client.id

    manifest_repo_url = var.vamserlike_manifest_repo_url
    manifest_path     = var.vamserlike_manifest_path
    argocd_app_name   = var.vamserlike_argocd_app_name
  }

  depends_on = [
    aws_instance.k8s_manager_instance,
    aws_cognito_user_pool.vamserlike_user_pool,
    aws_cognito_user_pool_client.vamserlike_app_client,
    null_resource.associate_k8s_manager_instance_profile
  ]

  connection {
    type        = "ssh"
    user        = "ec2-user"
    host        = aws_instance.k8s_manager_instance.public_ip
    private_key = file(var.k8s_manager_private_key_path)
    timeout     = "10m"
  }

  provisioner "remote-exec" {
    inline = [
      "echo '===== Wait for cloud-init ====='",
      "sudo cloud-init status --wait || true",
      "mkdir -p /home/ec2-user/vamserlike/scripts",
      "mkdir -p /home/ec2-user/vamserlike/generated"
    ]
  }

  provisioner "file" {
    source      = "${path.module}/scripts/bootstrap-vamserlike.sh"
    destination = "/home/ec2-user/vamserlike/scripts/bootstrap-vamserlike.sh"
  }

  provisioner "file" {
    source      = "${path.module}/scripts/cleanup-vamserlike.sh"
    destination = "/home/ec2-user/vamserlike/scripts/cleanup-vamserlike.sh"
  }

  provisioner "file" {
    source      = "${path.module}/scripts/vamserlike.env.example"
    destination = "/home/ec2-user/vamserlike/scripts/vamserlike.env.example"
  }

  provisioner "file" {
    destination = "/home/ec2-user/vamserlike/scripts/vamserlike.env"

    content = <<-EOF
# =========================================================
# Vamserlike Auto Generated Environment
# Generated by Terraform
# =========================================================

AWS_REGION=ap-northeast-2
CLUSTER_NAME=${var.vamserlike_eks_cluster_name}
NODEGROUP_NAME=${var.vamserlike_eks_nodegroup_name}
VPC_CIDR=${var.vamserlike_vpc_cidr}
ECR_REPOSITORY=${var.vamserlike_ecr_repository}

PUBLIC_SUBNET_2A_NAME=${aws_subnet.public_subnet.tags["Name"]}
PUBLIC_SUBNET_2C_NAME=${aws_subnet.public_subnet2.tags["Name"]}
PRIVATE_SUBNET_2A_NAME=${aws_subnet.private_subnet.tags["Name"]}
PRIVATE_SUBNET_2C_NAME=${aws_subnet.private_subnet2.tags["Name"]}

# Cognito values are generated by Terraform automatically
COGNITO_USER_POOL_ID=${aws_cognito_user_pool.vamserlike_user_pool.id}
COGNITO_CLIENT_ID=${aws_cognito_user_pool_client.vamserlike_app_client.id}

# DB 부분은 장한결 RDS / HAProxy 구성 완료 후 필요하면 이 줄만 수정
MYSQL_CONNECTION_STRING='${local.vamserlike_mysql_connection_string_shell}'

MANIFEST_REPO_URL=${var.vamserlike_manifest_repo_url}
MANIFEST_PATH=${var.vamserlike_manifest_path}
ARGOCD_APP_NAME=${var.vamserlike_argocd_app_name}

MONITORING_ENABLED=${local.vamserlike_monitoring_enabled_value}
GRAFANA_ADMIN_PASSWORD='${local.vamserlike_grafana_admin_password_shell}'
GRAFANA_RELEASE_NAME=${var.vamserlike_grafana_release_name}
GRAFANA_ADMIN_SECRET_NAME=${var.vamserlike_grafana_admin_secret_name}

BACKEND_LOG_GROUP_NAME=${var.vamserlike_backend_log_group_name}
DELETE_CLOUDWATCH_LOG_GROUP=${local.vamserlike_delete_log_group_value}
EOF
  }

  provisioner "remote-exec" {
    inline = [
      "echo '===== Prepare Vamserlike scripts ====='",

      "sed -i 's/\\r$//' /home/ec2-user/vamserlike/scripts/*.sh /home/ec2-user/vamserlike/scripts/vamserlike.env /home/ec2-user/vamserlike/scripts/vamserlike.env.example",
      "chmod +x /home/ec2-user/vamserlike/scripts/*.sh",
      "chown -R ec2-user:ec2-user /home/ec2-user/vamserlike",

      "cat > /home/ec2-user/bootstrap-vamserlike.sh <<'BOOTSTRAP_EOF'",
      "#!/usr/bin/env bash",
      "set -euo pipefail",
      "cd /home/ec2-user/vamserlike",
      "bash scripts/bootstrap-vamserlike.sh",
      "BOOTSTRAP_EOF",

      "cat > /home/ec2-user/cleanup-vamserlike.sh <<'CLEANUP_EOF'",
      "#!/usr/bin/env bash",
      "set -euo pipefail",
      "cd /home/ec2-user/vamserlike",
      "bash scripts/cleanup-vamserlike.sh",
      "CLEANUP_EOF",

      "cat > /home/ec2-user/show-vamserlike-env.sh <<'SHOW_ENV_EOF'",
      "#!/usr/bin/env bash",
      "set -euo pipefail",
      "cat /home/ec2-user/vamserlike/scripts/vamserlike.env",
      "SHOW_ENV_EOF",

      "chmod +x /home/ec2-user/bootstrap-vamserlike.sh /home/ec2-user/cleanup-vamserlike.sh /home/ec2-user/show-vamserlike-env.sh",
      "chown ec2-user:ec2-user /home/ec2-user/bootstrap-vamserlike.sh /home/ec2-user/cleanup-vamserlike.sh /home/ec2-user/show-vamserlike-env.sh",

      "bash -n /home/ec2-user/vamserlike/scripts/bootstrap-vamserlike.sh",
      "bash -n /home/ec2-user/vamserlike/scripts/cleanup-vamserlike.sh",
      "bash -n /home/ec2-user/bootstrap-vamserlike.sh",
      "bash -n /home/ec2-user/cleanup-vamserlike.sh",

      "echo '===== Vamserlike assets uploaded ====='",
      "echo 'Workdir          : /home/ec2-user/vamserlike'",
      "echo 'Show env command : ./show-vamserlike-env.sh'",
      "echo 'Bootstrap command: ./bootstrap-vamserlike.sh'",
      "echo 'Cleanup command  : ./cleanup-vamserlike.sh'"
    ]
  }
}

output "vamserlike_k8s_manager_workdir" {
  value       = "/home/ec2-user/vamserlike"
  description = "K8s Manager EC2에 자동 업로드된 Vamserlike 작업 디렉터리"
}

output "vamserlike_show_env_command" {
  value       = "./show-vamserlike-env.sh"
  description = "K8s Manager EC2 접속 후 자동 생성된 env 확인 명령어"
}

output "vamserlike_bootstrap_command" {
  value       = "./bootstrap-vamserlike.sh"
  description = "K8s Manager EC2 접속 후 실행할 bootstrap 명령어"
}

output "vamserlike_cleanup_command" {
  value       = "./cleanup-vamserlike.sh"
  description = "K8s Manager EC2 접속 후 실행할 cleanup 명령어"
}