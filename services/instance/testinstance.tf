

//TODO: 인스턴스
//          - 쿠버네티스에서 알아서 생성할것이게 임시 테스트용

// 4. 인스턴스 private 백엔드용
resource "aws_instance" "private_Backend_test" {
  ami           = "ami-0d4c056a16f3ae150"
  instance_type = "t3.micro"
  subnet_id     = aws_subnet.private_subnet.id
  vpc_security_group_ids = [aws_security_group.private_sg.id]
  key_name      = var.key_name

  user_data = <<-EOF
              #!/bin/bash
              hostnamectl --static set-hostname Seoul-privates

              dnf install -y httpd
              echo "Hello, World Server Port is ${var.server_port}" > /var/www/html/index.html
              systemctl enable --now httpd
              EOF

  tags          = { Name = "Private-Backend-Test-EC2" }
}


// 2. private 백엔드있는쪽 보안그룹 테스트용
resource "aws_security_group" "private_sg" {
  
  name   = var.backend_sg_name
  vpc_id = aws_vpc.lz_vpc.id
  
  # 1. ALB 보안그룹에서 오는 트래픽만 허용 (핵심!)
  ingress { 
    from_port       = 80 
    to_port         = 80 
    protocol        = "tcp" 
    security_groups = [aws_security_group.alb_sg.id] 
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

