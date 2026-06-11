terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.50, < 6.0"
    }
  }
}

provider "aws" {
  region = "ap-northeast-2"
}

# =========================================================
# 1. VPC
# =========================================================
resource "aws_vpc" "lz_vpc" {
  cidr_block           = "10.40.0.0/16"
  enable_dns_hostnames = true
  tags                 = { Name = "NATInstance-VPC1" }
}

# =========================================================
# 2. Subnets
# =========================================================
resource "aws_subnet" "public_subnet" {
  vpc_id                  = aws_vpc.lz_vpc.id
  cidr_block              = "10.40.1.0/24"
  availability_zone       = "ap-northeast-2a"
  map_public_ip_on_launch = true
  tags                    = { Name = "Public-Subnet-2a" }
}

resource "aws_subnet" "public_subnet2" {
  vpc_id                  = aws_vpc.lz_vpc.id
  cidr_block              = "10.40.3.0/24"
  availability_zone       = "ap-northeast-2c"
  map_public_ip_on_launch = true
  tags                    = { Name = "Public-Subnet-2c" }
}

resource "aws_subnet" "private_subnet" {
  vpc_id            = aws_vpc.lz_vpc.id
  cidr_block        = "10.40.2.0/24"
  availability_zone = "ap-northeast-2a"
  tags              = { Name = "Private-Subnet-2a" }
}

resource "aws_subnet" "private_subnet2" {
  vpc_id            = aws_vpc.lz_vpc.id
  cidr_block        = "10.40.4.0/24"
  availability_zone = "ap-northeast-2c"
  tags              = { Name = "Private-Subnet-2c" }
}

# =========================================================
# 3. Internet Gateway / Public Route Table
# =========================================================
resource "aws_internet_gateway" "igw" {
  vpc_id = aws_vpc.lz_vpc.id

  tags = {
    Name = "NATInstance-IGW"
  }
}

resource "aws_route_table" "public_rt" {
  vpc_id = aws_vpc.lz_vpc.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.igw.id
  }

  tags = {
    Name = "Public-Route-Table"
  }
}

resource "aws_route_table_association" "public_assoc_a" {
  subnet_id      = aws_subnet.public_subnet.id
  route_table_id = aws_route_table.public_rt.id
}

resource "aws_route_table_association" "public_assoc_c" {
  subnet_id      = aws_subnet.public_subnet2.id
  route_table_id = aws_route_table.public_rt.id
}

# =========================================================
# 4. K8s Manager EC2
# =========================================================
resource "aws_instance" "k8s_manager_instance" {
  ami                    = "ami-0d4c056a16f3ae150"
  instance_type          = "t3.medium"
  subnet_id              = aws_subnet.public_subnet2.id
  vpc_security_group_ids = [aws_security_group.k8s_sg.id]
  key_name               = var.key_name
  iam_instance_profile   = aws_iam_instance_profile.eksworkspace_admin_profile.name

  depends_on = [
    aws_iam_instance_profile.eksworkspace_admin_profile,
    aws_iam_role_policy_attachment.eksworkspace_admin_attach,
    aws_cognito_user_pool.vamserlike_user_pool,
    aws_cognito_user_pool_client.vamserlike_app_client,
    aws_ecr_repository.vamserlike_backend
  ]

  user_data = <<-EOF
#!/bin/bash
set -euxo pipefail

hostnamectl --static set-hostname k8s-public

dnf update -y
dnf install -y unzip jq bash-completion git tar gzip awscli

curl -fsSL -o /tmp/kubectl https://s3.us-west-2.amazonaws.com/amazon-eks/1.30.0/2024-05-12/bin/linux/amd64/kubectl
chmod +x /tmp/kubectl
mv /tmp/kubectl /usr/local/bin/kubectl

curl --silent --location "https://github.com/weaveworks/eksctl/releases/latest/download/eksctl_$(uname -s)_amd64.tar.gz" | tar xz -C /tmp
mv /tmp/eksctl /usr/local/bin/eksctl

curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
helm repo add eks https://aws.github.io/eks-charts || true
helm repo update

TOKEN=$(curl -sS -X PUT "http://169.254.169.254/latest/api/token" -H "X-aws-ec2-metadata-token-ttl-seconds: 21600")
AWS_REGION=$(curl -sS -H "X-aws-ec2-metadata-token: $TOKEN" http://169.254.169.254/latest/dynamic/instance-identity/document | jq -r '.region')

echo "export AWS_REGION=$AWS_REGION" >> /home/ec2-user/.bash_profile
aws configure set default.region "$AWS_REGION"

cd /home/ec2-user



# 여기서 브런치이름 설정(allmerge)
if [ ! -d /home/ec2-user/terraform-base-infra/.git ]; then
  sudo -u ec2-user git clone -b allmerge https://github.com/vjzm444/terraform-base-infra.git /home/ec2-user/terraform-base-infra
else
  cd /home/ec2-user/terraform-base-infra
  sudo -u ec2-user git pull --ff-only || true
fi

INSTANCE_DIR="/home/ec2-user/terraform-base-infra/services/instance"
mkdir -p "$INSTANCE_DIR/scripts"

sed -i 's/\r$//' "$INSTANCE_DIR"/scripts/*.sh "$INSTANCE_DIR"/scripts/vamserlike.env.example 2>/dev/null || true
chmod +x "$INSTANCE_DIR"/scripts/*.sh 2>/dev/null || true

cat > "$INSTANCE_DIR/scripts/vamserlike.env" <<'VAMSERLIKE_ENV_EOF'
AWS_REGION=ap-northeast-2
CLUSTER_NAME=eks-demo
NODEGROUP_NAME=vamserlike-node-group
VPC_CIDR=10.40.0.0/16
ECR_REPOSITORY=vamserlike-backend

PUBLIC_SUBNET_2A_NAME=Public-Subnet-2a
PUBLIC_SUBNET_2C_NAME=Public-Subnet-2c
PRIVATE_SUBNET_2A_NAME=Private-Subnet-2a
PRIVATE_SUBNET_2C_NAME=Private-Subnet-2c

COGNITO_USER_POOL_ID=${aws_cognito_user_pool.vamserlike_user_pool.id}
COGNITO_CLIENT_ID=${aws_cognito_user_pool_client.vamserlike_app_client.id}

MYSQL_CONNECTION_STRING='Server=CHANGE_ME;Port=3306;Database=vamserlike;User=admin;Password=CHANGE_ME;SslMode=Preferred;AllowPublicKeyRetrieval=True;'

BACKEND_REPO_URL=https://github.com/rlduddl/Vamserlike-backend.git
BACKEND_BRANCH=rlduddl5519
BACKEND_IMAGE_TAG=latest
BACKEND_DOCKERFILE_PATH=Dockerfile
BACKEND_BUILD_CONTEXT=.

MANIFEST_REPO_URL=https://github.com/rlduddl/Vamserlike-k8s-manifests.git
MANIFEST_PATH=overlays/dev
ARGOCD_APP_NAME=vamserlike-backend

MONITORING_ENABLED=true
GRAFANA_ADMIN_PASSWORD='Vamserlike123!'
GRAFANA_RELEASE_NAME=vamserlike-monitoring
GRAFANA_ADMIN_SECRET_NAME=vamserlike-grafana-admin

BACKEND_LOG_GROUP_NAME=/ec2/vamserlike-backend
DELETE_CLOUDWATCH_LOG_GROUP=false
DELETE_ECR_IMAGES=false
CLEAN_LOCAL_DOCKER_IMAGES=true
CLEAN_BACKEND_SOURCE_DIR=false
VAMSERLIKE_ENV_EOF

cat > /home/ec2-user/bootstrap-vamserlike.sh <<'RUN_BOOTSTRAP_EOF'
#!/usr/bin/env bash
set -euo pipefail
cd /home/ec2-user/terraform-base-infra/services/instance
bash scripts/bootstrap-vamserlike.sh
RUN_BOOTSTRAP_EOF

cat > /home/ec2-user/cleanup-vamserlike.sh <<'RUN_CLEANUP_EOF'
#!/usr/bin/env bash
set -euo pipefail
cd /home/ec2-user/terraform-base-infra/services/instance
bash scripts/cleanup-vamserlike.sh
RUN_CLEANUP_EOF

cat > /home/ec2-user/show-vamserlike-env.sh <<'SHOW_ENV_EOF'
#!/usr/bin/env bash
set -euo pipefail
cat /home/ec2-user/terraform-base-infra/services/instance/scripts/vamserlike.env
SHOW_ENV_EOF

cat > /home/ec2-user/VAMSERLIKE_README.txt <<'README_EOF'
Vamserlike K8s Manager EC2

1. Check generated env:
   ./show-vamserlike-env.sh

2. Edit DB connection string if needed:
   vi ~/terraform-base-infra/services/instance/scripts/vamserlike.env

3. Deploy EKS, Argo CD, backend image build/push, and backend ALB:
   ./bootstrap-vamserlike.sh

4. Cleanup Kubernetes/EKS resources:
   ./cleanup-vamserlike.sh
README_EOF

chmod +x /home/ec2-user/bootstrap-vamserlike.sh
chmod +x /home/ec2-user/cleanup-vamserlike.sh
chmod +x /home/ec2-user/show-vamserlike-env.sh

chown -R ec2-user:ec2-user /home/ec2-user/terraform-base-infra
chown ec2-user:ec2-user /home/ec2-user/bootstrap-vamserlike.sh /home/ec2-user/cleanup-vamserlike.sh /home/ec2-user/show-vamserlike-env.sh /home/ec2-user/VAMSERLIKE_README.txt

bash -n "$INSTANCE_DIR/scripts/bootstrap-vamserlike.sh" || true
bash -n "$INSTANCE_DIR/scripts/cleanup-vamserlike.sh" || true
bash -n /home/ec2-user/bootstrap-vamserlike.sh
bash -n /home/ec2-user/cleanup-vamserlike.sh

echo "===== Vamserlike K8s Manager user_data completed ====="
echo "./show-vamserlike-env.sh"
echo "./bootstrap-vamserlike.sh"
echo "./cleanup-vamserlike.sh"
EOF

  tags = { Name = "K8s-Manager-EC2" }
}

# =========================================================
# 5. NAT Instance
# =========================================================
resource "aws_instance" "nat_bastion_instance" {
  ami                    = "ami-0d4c056a16f3ae150"
  instance_type          = "t3.micro"
  subnet_id              = aws_subnet.public_subnet.id
  key_name               = var.key_name
  source_dest_check      = false
  vpc_security_group_ids = [aws_security_group.nat_sg.id]

  user_data = <<-EOF
#!/bin/bash
set -euxo pipefail

hostnamectl --static set-hostname Seoul-public

sysctl -w net.ipv4.ip_forward=1
echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf

dnf install -y iptables-services

iptables -P FORWARD ACCEPT

IFACE=$(ip route show default | awk '/default/ {print $5; exit}')
iptables -t nat -A POSTROUTING -o "$IFACE" -j MASQUERADE

service iptables save
systemctl enable --now iptables
EOF

  tags = { Name = "NAT-Instance-EC2" }
}

# =========================================================
# 6. Private Route Table / NAT Route
# =========================================================
resource "aws_route_table" "private_rt" {
  vpc_id = aws_vpc.lz_vpc.id
  tags   = { Name = "Private-Route-Table" }
}

resource "aws_route" "private_nat_route" {
  route_table_id         = aws_route_table.private_rt.id
  destination_cidr_block = "0.0.0.0/0"
  network_interface_id   = aws_instance.nat_bastion_instance.primary_network_interface_id

  depends_on = [aws_instance.nat_bastion_instance]
}

resource "aws_route_table_association" "private_assoc_a" {
  subnet_id      = aws_subnet.private_subnet.id
  route_table_id = aws_route_table.private_rt.id
}

resource "aws_route_table_association" "private_assoc_c" {
  subnet_id      = aws_subnet.private_subnet2.id
  route_table_id = aws_route_table.private_rt.id
}

# =========================================================
# 7. Security Groups
# =========================================================
resource "aws_security_group" "nat_sg" {
  name   = var.nat_sg_name
  vpc_id = aws_vpc.lz_vpc.id

  ingress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["10.40.2.0/24", "10.40.4.0/24"]
  }

  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_security_group" "k8s_sg" {
  name   = var.k8s_sg_name
  vpc_id = aws_vpc.lz_vpc.id

  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    from_port   = 10250
    to_port     = 10250
    protocol    = "tcp"
    cidr_blocks = ["10.40.0.0/16"]
  }

  ingress {
    from_port   = 4789
    to_port     = 4789
    protocol    = "udp"
    cidr_blocks = ["10.40.0.0/16"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}
