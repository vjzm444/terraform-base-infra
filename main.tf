provider "aws" {
  region = "ap-northeast-2"

  version = "~> 2.0"
}

//Ec2
resource "aws_instance" "example" {
  ami                    = "ami-0d4c056a16f3ae150"
  instance_type          = "t3.micro"
  vpc_security_group_ids = [aws_security_group.instance.id]
  
  key_name ="thdguswn0005_seoul_v2"

  user_data = <<-EOF
              #!/bin/bash
              dnf install -y httpd
              echo "Hello, World Server Port is ${var.server_port}" > /var/www/html/index.html
              systemctl enable --now httpd
              EOF

  tags = {
    Name = "terraform-example"
  }
}


//보안그룹
resource "aws_security_group" "instance" {
    
  name = var.security_group_name

  ingress {
    from_port   = var.server_port
    to_port     = var.server_port
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
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