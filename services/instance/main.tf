provider "aws" {
  region = "ap-northeast-2"
  version = ">= 5.50, < 6.0"
}


# 1. VPC
resource "aws_vpc" "lz_vpc" {
  cidr_block           = "10.40.0.0/16"
  enable_dns_hostnames = true
  tags                 = { Name = "NATInstance-VPC1" }
}

# 서브넷
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

# 2. 인터넷 게이트웨이 및 라우팅
resource "aws_internet_gateway" "igw" {
  vpc_id = aws_vpc.lz_vpc.id
}

resource "aws_route_table" "public_rt" {
  vpc_id = aws_vpc.lz_vpc.id
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.igw.id
  }
}


# 쿠버네티스 실행전용 인스턴스
resource "aws_instance" "k8s_manager_instance" {
  ami           = "ami-0d4c056a16f3ae150"
  instance_type = "t3.medium"
  subnet_id     = aws_subnet.public_subnet2.id 
  vpc_security_group_ids = [aws_security_group.k8s_sg.id] 
  key_name      = var.key_name
  
  
  user_data = <<-EOF
              #!/bin/bash
              set -ex
              
              sudo dnf install -y unzip jq bash-completion
              curl -o kubectl https://s3.us-west-2.amazonaws.com/amazon-eks/1.30.0/2024-05-12/bin/linux/amd64/kubectl
              chmod +x ./kubectl
              sudo mv ./kubectl /usr/local/bin/kubectl
              curl --silent --location "https://github.com/weaveworks/eksctl/releases/latest/download/eksctl_$(uname -s)_amd64.tar.gz" | tar xz -C /tmp
              sudo mv /tmp/eksctl /usr/local/bin

              curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
              hostnamectl --static set-hostname k8s-public


              cat << 'EKS_EOF' > /home/ec2-user/eks-demo-cluster.yaml
              apiVersion: eksctl.io/v1alpha5
              kind: ClusterConfig
              metadata:
                name: eks-demo
                region: ap-northeast-2
                version: "1.30"
              vpc:
                id: "${aws_vpc.lz_vpc.id}"
                subnets:
                  private:
                    ap-northeast-2a: { id: "${aws_subnet.private_subnet.id}" }
                    ap-northeast-2c: { id: "${aws_subnet.private_subnet2.id}" }
                  public:
                    ap-northeast-2a: { id: "${aws_subnet.public_subnet.id}" }
                    ap-northeast-2c: { id: "${aws_subnet.public_subnet2.id}" }
              managedNodeGroups:
                - name: node-group
                  instanceType: t3.medium
                  desiredCapacity: 2
                  privateNetworking: true
              EKS_EOF



              cat << 'APP_EOF' > /home/ec2-user/backend-app.yaml
              apiVersion: apps/v1
              kind: Deployment
              metadata:
                name: flask-backend
              spec:
                replicas: 2
                selector:
                  matchLabels:
                    app: flask-backend
                template:
                  metadata:
                    labels:
                      app: flask-backend
                  spec:
                    containers:
                    - name: nginx
                      image: nginx:alpine
                      ports:
                      - containerPort: 80
              ---
              apiVersion: v1
              kind: Service
              metadata:
                name: flask-backend-service
                annotations:
                  service.beta.kubernetes.io/aws-load-balancer-scheme: "internet-facing"
                  service.beta.kubernetes.io/aws-load-balancer-type: "alb"
                  service.beta.kubernetes.io/aws-load-balancer-subnets: "${aws_subnet.public_subnet.id}, ${aws_subnet.public_subnet2.id}"
              spec:
                type: LoadBalancer
                selector:
                  app: flask-backend
                ports:
                  - port: 80
                    targetPort: 80
              APP_EOF

              chown ec2-user:ec2-user /home/ec2-user/eks-demo-cluster.yaml /home/ec2-user/backend-app.yaml
              
              EOF

  tags = { Name = "K8s-Manager-EC2" }
}




# 3. NAT 인스턴스 (TestInstance2-Public-EC2 역할)
resource "aws_instance" "nat_bastion_instance" {
  ami           = "ami-0d4c056a16f3ae150"
  instance_type = "t3.micro"
  subnet_id     = aws_subnet.public_subnet.id
  key_name      = var.key_name

  # ★ 핵심: 패킷 포워딩 필수
  source_dest_check      = false
  vpc_security_group_ids = [aws_security_group.nat_sg.id]

  user_data = <<-EOF
    #!/bin/bash
    hostnamectl --static set-hostname Seoul-public

    # 1. IP 포워딩 활성화
    sysctl -w net.ipv4.ip_forward=1
    echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf

    # 2. 서비스 설치
    dnf install -y iptables-services

    # 3. FORWARD 정책 변경
    iptables -P FORWARD ACCEPT

    # 4. 동적 마스커레이딩
    IFACE=$(ip route show default | awk '/default/ {print $5; exit}')
    iptables -t nat -A POSTROUTING -o "$IFACE" -j MASQUERADE

    # 5. 설정 저장 및 서비스 시작
    service iptables save
    systemctl enable --now iptables
  EOF

  tags = { Name = "NAT-Instance-EC2" }
}




# 2. 라우트 테이블 (인스턴스 생성 후 생성되도록 확실한 의존성 부여)
resource "aws_route_table" "private_rt" {
  vpc_id = aws_vpc.lz_vpc.id
  tags   = { Name = "Private-Route-Table" }
}


// private 서브넷 -> public NAT 인스턴스로 지정
resource "aws_route" "private_nat_route" {
  route_table_id         = aws_route_table.private_rt.id
  destination_cidr_block = "0.0.0.0/0"
  
  network_interface_id   = aws_instance.nat_bastion_instance.primary_network_interface_id
  
  depends_on             = [aws_instance.nat_bastion_instance]
}


# 라우트 테이블에 a, c 모두 연결
resource "aws_route_table_association" "public_assoc_a" {
  subnet_id      = aws_subnet.public_subnet.id
  route_table_id = aws_route_table.public_rt.id
}

resource "aws_route_table_association" "public_assoc_c" {
  subnet_id      = aws_subnet.public_subnet2.id
  route_table_id = aws_route_table.public_rt.id
}

# 프라이빗 라우트 테이블에 a, c 모두 연결
resource "aws_route_table_association" "private_assoc_a" {
  subnet_id      = aws_subnet.private_subnet.id
  route_table_id = aws_route_table.private_rt.id
}

resource "aws_route_table_association" "private_assoc_c" {
  subnet_id      = aws_subnet.private_subnet2.id
  route_table_id = aws_route_table.private_rt.id
}


# region VPC & Subnets


// 2. 보안그룹 수정 (숫자형으로 변경)
resource "aws_security_group" "nat_sg" {
  name   = var.nat_sg_name  # 변수 적용
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

// 쿠버네티스용 보안그룹 (관리 및 트래픽 통신용)
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

  // 쿠버네티스 API 및 노드 간 통신을 위한 포트
  // EKS 사용 시 노드 간의 통신이 원활해야 함
  ingress { 
    from_port   = 10250 
    to_port     = 10250 
    protocol    = "tcp" 
    cidr_blocks = ["10.40.0.0/16"] 
  }

  // 노드 간 UDP 통신 (Flannel/Calico 등의 CNI 사용 시 필요)
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
# endregion