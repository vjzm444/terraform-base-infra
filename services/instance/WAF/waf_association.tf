# =========================================================
# [버전 B / 독립 폴더] 여러 ALB 중 '현주님 ALB'만 골라 WAF 연결
# WAF 가 별도 state 라 aws_lb.alb 를 직접 못 보므로, ARN 또는 이름으로 '기존' ALB 를 지정한다.
#
# ▶ 둘 중 하나만 채운다(둘 다 비우면 의도적으로 실패 → 실수로 엉뚱한 ALB 연결 방지):
#    - alb_arn  : 가장 확실(권장). 현주님 ALB ARN 을 그대로 지정.
#    - alb_name : ARN 을 모를 때, 이름으로 조회(이름은 리전·계정 내 유일).
# ▶ 임의 기본값(예: public-backend-alb = 기영님 것)을 그대로 쓰지 말 것. 기본값을 비워 둠.
#
# 사용법: 같은 폴더에 terraform.tfvars 만들어 한 줄만 채우기. 예)
#    alb_arn  = "arn:aws:elasticloadbalancing:ap-northeast-2:...:loadbalancer/app/현주ALB/xxxx"
#  또는
#    alb_name = "현주님-ALB-이름"
# =========================================================

terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.0"
    }
  }

  # 별도 state 를 위해 자체 backend 구성(예: S3)
  # backend "s3" {
  #   bucket = "<your-tf-state-bucket>"
  #   key    = "waf/terraform.tfstate"
  #   region = "ap-northeast-2"
  # }
}

provider "aws" {
  region = "ap-northeast-2" # WAF(REGIONAL)와 ALB 는 반드시 같은 리전
}

variable "alb_arn" {
  type        = string
  default     = ""
  description = "현주님 ALB ARN(권장/가장 확실). 지정 시 이 값을 그대로 사용."
}

variable "alb_name" {
  type        = string
  default     = ""
  description = "alb_arn 이 비었을 때, 이 이름으로 ALB 조회(이름은 유일)."
}

# alb_arn 이 비어 있을 때만 이름으로 조회(count 분기)
data "aws_lb" "alb" {
  count = var.alb_arn == "" ? 1 : 0
  name  = var.alb_name
}

locals {
  # 둘 다 비면 data 가 name="" 로 조회 실패 → 의도된 안전장치(엉뚱한 ALB 연결 차단)
  alb_arn = var.alb_arn != "" ? var.alb_arn : data.aws_lb.alb[0].arn
}

resource "aws_wafv2_web_acl_association" "backend" {
  resource_arn = local.alb_arn
  web_acl_arn  = aws_wafv2_web_acl.backend.arn
}

# apply 후 '어느 ALB 에 붙었는지' 즉시 확인용 출력
output "waf_attached_alb_arn" {
  value       = local.alb_arn
  description = "WAF 가 연결된 ALB ARN(현주님 것이 맞는지 확인용)"
}
