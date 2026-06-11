

// 그라파나 백엔드 로그용 내부인스턴스


// 인스턴스 private 백엔드용
resource "aws_instance" "private_Backend_test" {
  ami           = "ami-0d4c056a16f3ae150"
  instance_type = "t3.micro"

  iam_instance_profile = aws_iam_instance_profile.backend_profile.name

  
  subnet_id     = aws_subnet.private_subnet.id
  vpc_security_group_ids = [aws_security_group.private_sg.id]
  key_name      = var.key_name

  user_data = <<-EOF
              #!/bin/bash
              hostnamectl --static set-hostname Seoul-privates

              # 1. 도커 설치 및 실행
              dnf install -y docker
              systemctl enable --now docker
              usermod -aG docker ec2-user

              # 2. 도커 컴포즈 설치
              mkdir -p /usr/libexec/docker/cli-plugins/
              curl -SL https://github.com/docker/compose/releases/latest/download/docker-compose-linux-x86_64 -o /usr/libexec/docker/cli-plugins/docker-compose
              chmod +x /usr/libexec/docker/cli-plugins/docker-compose
              ln -sf /usr/libexec/docker/cli-plugins/docker-compose /usr/bin/docker-compose

              # git 설치(브런치 여기서 설정!!)
              dnf install -y git
              git clone -b team --single-branch https://github.com/rlduddl/Vamserlike-backend.git /home/ec2-user/backend
              
              cd /home/ec2-user/backend/src/Vamserlike.Api
              
              sudo curl -L "https://github.com/docker/compose/releases/download/v2.27.0/docker-compose-$(uname -s)-$(uname -m)" -o /usr/local/bin/docker-compose
              sudo chmod +x /usr/local/bin/docker-compose
              sudo ln -sf /usr/local/bin/docker-compose /usr/bin/docker-compose
              docker-compose up -d --build

              docker run -d --name=grafana -p 3000:3000 grafana/grafana:10.4.10
              
              EOF

  tags          = { Name = "Private-Backend-Test-EC2" }
}


// 2. private 백엔드있는쪽 보안그룹 테스트용
resource "aws_security_group" "private_sg" {
  
  name   = var.backend_sg_name
  vpc_id = aws_vpc.lz_vpc.id
  
  # 1. ALB 보안그룹에서 오는 트래픽만 허용 (핵심!)
  # ingress { 
  #   from_port       = 80 
  #   to_port         = 80 
  #   protocol        = "tcp" 
  #   security_groups = [aws_security_group.alb_sg.id] 
  # }

  ingress { 
    from_port       = 80 
    to_port         = 80 
    protocol        = "tcp" 
    cidr_blocks = ["10.40.0.0/16"]
  }

  # NAT 인스턴스에서 들어오는 모든 트래픽 허용
  ingress { 
    from_port   = 0 
    to_port     = 0 
    protocol    = "-1" 
    cidr_blocks = ["10.40.0.0/16"]
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

