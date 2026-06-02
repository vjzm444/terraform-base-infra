provider "aws" {
  region = "ap-northeast-2"
  version = ">= 5.50, < 6.0"
}


# 1. VPC & 서브넷
resource "aws_vpc" "lz_vpc" {
  cidr_block           = "10.40.0.0/16"
  enable_dns_hostnames = true
  tags                 = { Name = "NATInstance-VPC1" }
}

resource "aws_subnet" "public_subnet" {
  vpc_id                  = aws_vpc.lz_vpc.id
  cidr_block              = "10.40.1.0/24"
  map_public_ip_on_launch = true
  tags                    = { Name = "Public-Subnet" }
}

resource "aws_subnet" "private_subnet" {
  vpc_id     = aws_vpc.lz_vpc.id
  cidr_block = "10.40.2.0/24"
  tags       = { Name = "Private-Subnet" }
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

resource "aws_route_table_association" "public_assoc" {
  subnet_id      = aws_subnet.public_subnet.id
  route_table_id = aws_route_table.public_rt.id
}

# 3. NAT 인스턴스 (TestInstance2-Public-EC2 역할)
resource "aws_instance" "nat_instance" {
  ami               = "ami-0d4c056a16f3ae150" # 예시 AMI
  instance_type     = "t3.micro"
  subnet_id         = aws_subnet.public_subnet.id
  source_dest_check = false # ★ 핵심: 패킷 포워딩 필수
  vpc_security_group_ids = [aws_security_group.nat_sg.id]
  key_name          = "thdguswn0005_seoul_v2"

  user_data = <<-EOF
              #!/bin/bash
              
              hostnamectl --static set-hostname Seoul-public

              # 1. IP 포워딩 활성화
              sysctl -w net.ipv4.ip_forward=1
              echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf
              
              # 2. 필요한 서비스 설치
              dnf install -y iptables-services
              
              # 3. 먼저 FORWARD 정책을 ACCEPT로 변경
              iptables -P FORWARD ACCEPT
              
              # 4. 동적으로 인터페이스 찾아서 마스커레이딩 추가
              IFACE=$(ip route show default | awk '/default/ {print $5; exit}')
              iptables -t nat -A POSTROUTING -o "$IFACE" -j MASQUERADE
              
              # 5. 이제 서비스를 켜고 현재 규칙을 저장해버림
              service iptables save
              systemctl enable --now iptables
              EOF

  tags = { Name = "TestInstance2-NAT-EC2" }
}

# 4. 프라이빗 기영 인스턴스
resource "aws_instance" "private_giyeong" {
  ami           = "ami-0d4c056a16f3ae150"
  instance_type = "t3.micro"
  subnet_id     = aws_subnet.private_subnet.id
  vpc_security_group_ids = [aws_security_group.private_sg.id]
  key_name      = "thdguswn0005_seoul_v2"

  user_data = <<-EOF
              #!/bin/bash
              hostnamectl --static set-hostname Seoul-privates

              dnf install -y httpd
              echo "Hello, World Server Port is ${var.server_port}" > /var/www/html/index.html
              systemctl enable --now httpd
              EOF

  tags          = { Name = "Private-Giyeong-EC2" }
}

# 2. 라우트 테이블 (인스턴스 생성 후 생성되도록 확실한 의존성 부여)
resource "aws_route_table" "private_rt" {
  vpc_id = aws_vpc.lz_vpc.id
  tags   = { Name = "Private-Route-Table" }
}

resource "aws_route_table_association" "private_assoc" {
  subnet_id      = aws_subnet.private_subnet.id
  route_table_id = aws_route_table.private_rt.id
}


# 2. 보안그룹 수정 (숫자형으로 변경)
resource "aws_security_group" "nat_sg" {
  name   = var.nat_sg_name  # 변수 적용
  vpc_id = aws_vpc.lz_vpc.id
  
  ingress { 
    from_port   = 0     # 0은 숫자 그대로 써야 해
    to_port     = 0 
    protocol    = "-1" 
    cidr_blocks = ["10.40.2.0/24"] 
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


# 기영이(프라이빗) 서브넷에서 외부로 나가는 길을 NAT 인스턴스로 지정
resource "aws_route" "private_nat_route" {
  route_table_id         = aws_route_table.private_rt.id
  destination_cidr_block = "0.0.0.0/0"
  
  # instance_id 대신 아래처럼 network_interface_id를 사용해!
  network_interface_id   = aws_instance.nat_instance.primary_network_interface_id
  
  depends_on             = [aws_instance.nat_instance]
}

# 2. 기영 보안그룹 수정
resource "aws_security_group" "private_sg" {
  
  name   = var.giyeong_sg_name # 변수 적용
  vpc_id = aws_vpc.lz_vpc.id
  
  # NAT 인스턴스(10.40.1.0/24)에서 들어오는 모든 트래픽 허용
  ingress { 
    from_port   = 0 
    to_port     = 0 
    protocol    = "-1" 
    cidr_blocks = ["10.40.1.0/24"] 
  }

  # 웹 서버용 80 포트 추가
  ingress { 
    from_port   = 80 
    to_port     = 80 
    protocol    = "tcp" 
    cidr_blocks = ["0.0.0.0/0"] 
  }

  # SSH 허용
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