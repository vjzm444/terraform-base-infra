
// Grafana용 ALB(public)

# 1. ALB 생성 (퍼블릭 서브넷 배치)
resource "aws_lb" "alb" {
  name               = "public-backend-alb"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [aws_security_group.alb_sg.id]
  subnets            = [aws_subnet.public_subnet.id, aws_subnet.public_subnet2.id]
}

# 2. 타겟 그룹
resource "aws_lb_target_group" "tg" {
  
  name     = "backend-tg"
  port     = 80
  protocol = "HTTP"
  vpc_id   = aws_vpc.lz_vpc.id

  health_check {
    enabled             = true
    path                = "/"
    port                = "traffic-port"
    protocol            = "HTTP"
    matcher             = "200-299"             # 스웨거 페이지가 정상 응답(200)을 주는지 확인
    interval            = 30                    # 30초마다 체크
    timeout             = 5                     # 5초 안에 응답 안 오면 실패
    healthy_threshold   = 3                     # 3번 성공하면 정상
    unhealthy_threshold = 3                     # 3번 실패하면 비정상
  }
}

# 3. 인스턴스를 타겟 그룹에 등록
resource "aws_lb_target_group_attachment" "attach_ec2" {
  target_group_arn = aws_lb_target_group.tg.arn
  target_id        = aws_instance.private_Backend_test.id
  port             = 80
}



# 4. 리스너 (ALB 80 -> 타겟 그룹)
resource "aws_lb_listener" "listener" {
  load_balancer_arn = aws_lb.alb.arn
  port              = 80
  protocol          = "HTTP"
  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.tg.arn
  }
}

# 1. 3000번 포트용 타겟 그룹 생성
resource "aws_lb_target_group" "tg_3000" {
  name     = "grafana-tg-3000"
  port     = 3000
  protocol = "HTTP"
  vpc_id   = aws_vpc.lz_vpc.id

  health_check {
    enabled             = true
    path                = "/"            # 그라파나 루트 경로
    port                = "traffic-port"
    protocol            = "HTTP"
    matcher             = "200,302"      # 302 리다이렉트 허용
    interval            = 30
    timeout             = 5
    healthy_threshold   = 3
    unhealthy_threshold = 3
  }
}

# 2. 인스턴스를 3000번 타겟 그룹에 등록
resource "aws_lb_target_group_attachment" "attach_ec2_3000" {
  target_group_arn = aws_lb_target_group.tg_3000.arn
  target_id        = aws_instance.private_Backend_test.id
  port             = 3000
}

# 3. 3000번 포트용 리스너 추가
resource "aws_lb_listener" "listener_3000" {
  load_balancer_arn = aws_lb.alb.arn
  port              = 3000
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.tg_3000.arn
  }
}

resource "aws_security_group" "alb_sg" {
  name   = "alb-sg"
  vpc_id = aws_vpc.lz_vpc.id
  
  # 1. 외부 인터넷 전체 허용 (이게 있어야 접속이 돼!)
  ingress { 
    from_port   = 80 
    to_port     = 80 
    protocol    = "tcp" 
    cidr_blocks = ["0.0.0.0/0"] 
  }

  ingress { 
    from_port   = 3000 
    to_port     = 3000 
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