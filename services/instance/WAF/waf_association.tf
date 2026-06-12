# =========================================================
# [버전 B] 향후 분리 구조 — instance/WAF 를 '독립 폴더(별도 state)'로 운영할 때
# 부모가 없으므로 ALB ARN 을 직접 알아내야 한다.
# → 이미 존재하는 ALB 를 '이름'으로 조회(data 소스)하여, 수동 입력(ARN 복붙) 없이 연결.
#
# 사용법:
#  1) 이 파일을 instance/WAF/waf_association.tf 로 둔다(버전 A 연결 파일은 제거).
#  2) waf.tf 안의 기존 aws_wafv2_web_acl_association 블록은 삭제(중복 방지).
#  3) 부모의 waf_module_parent.tf(module "waf" 블록)는 더 이상 쓰지 않으므로 제거.
#
# 배포 순서: instance 배포(ALB 생성) → 그 다음 이 WAF 폴더에서 단독 배포(기존 ALB 조회).
# 주의: 이 폴더 안에 provider/terraform 블록이 이미 있다면 중복되지 않게 하나만 유지할 것.
#       waf_alert.tf 도 함께 단독 배포한다면 required_providers 에 archive 를 추가.
# =========================================================

terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.0"
    }
  }

  # 별도 state 를 위해 자체 backend 를 구성하세요(예: S3). 예시:
  # backend "s3" {
  #   bucket = "<your-tf-state-bucket>"
  #   key    = "waf/terraform.tfstate"
  #   region = "ap-northeast-2"
  # }
}

provider "aws" {
  region = "ap-northeast-2"
}

variable "alb_name" {
  type        = string
  default     = "public-backend-alb" # 실제 ALB 이름으로 확인/수정
  description = "연결할 기존 ALB 의 이름(자동 조회용)"
}

data "aws_lb" "alb" {
  name = var.alb_name
}

resource "aws_wafv2_web_acl_association" "backend" {
  resource_arn = data.aws_lb.alb.arn
  web_acl_arn  = aws_wafv2_web_acl.backend.arn
}
