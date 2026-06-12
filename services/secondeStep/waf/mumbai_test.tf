# ======================================================
# 1. 인도 뭄바이 리전용 서브 프로바이더 정의 (Alias 적용)
# ======================================================
provider "aws" {
  alias  = "mumbai"
  region = "ap-south-1"
}

# ======================================================
# 2. 인도 뭄바이의 기본 인프라 정보 자동 조회 (Data Source)
# ======================================================

# 기본 VPC 조회
data "aws_vpc" "mumbai_default" {
  provider = aws.mumbai
  default  = true
}

# 기본 서브넷 목록 조회
data "aws_subnets" "mumbai_default" {
  provider = aws.mumbai
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.mumbai_default.id]
  }
}

# 최신 Amazon Linux 2023 AMI 조회
data "aws_ami" "al2023_mumbai" {
  provider    = aws.mumbai
  most_recent = true
  owners      = ["amazon"]
  filter {
    name   = "name"
    values = ["al2023-ami-2023.*-x86_64"]
  }
}

# ======================================================
# 3. 인도 뭄바이 리전용 보안 그룹 생성 (SSH 22번 포트 허용)
# ======================================================
resource "aws_security_group" "mumbai_ssh" {
  provider    = aws.mumbai
  name        = "mumbai-ssh-allowed"
  description = "Allow SSH from anywhere for testing"
  vpc_id      = data.aws_vpc.mumbai_default.id

  # 로컬 터미널 SSH 접속용 허용
  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"] # 보안을 위해 본인 공인IP로 변경하셔도 좋습니다.
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "mumbai-ssh-sg" }
}

# ======================================================
# 4. 인도 뭄바이 일회용 테스트 인스턴스(t3.micro) 생성
# ======================================================
resource "aws_instance" "mumbai_test_instance" {
  provider                    = aws.mumbai
  ami                         = data.aws_ami.al2023_mumbai.id
  instance_type               = "t3.micro"
  subnet_id                   = element(data.aws_subnets.mumbai_default.ids, 0)
  vpc_security_group_ids      = [aws_security_group.mumbai_ssh.id]
  key_name                    = "thdguswn0005_mumbai_v2" # 요청하신 키 페어 지정
  associate_public_ip_address = true

  tags = { Name = "Mumbai-Test-EC2" }
}

# ======================================================
# 5. 생성된 인도 VM의 공인 IP 출력 추가
# ======================================================
output "mumbai_instance_public_ip" {
  value       = aws_instance.mumbai_test_instance.public_ip
  description = "인도 뭄바이 테스트 인스턴스 공인 IP"
}