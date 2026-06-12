# =========================================================
# [버전 B / 독립 폴더] WAF 를 ALB 에 직접 연결 (terraform.tfvars 없이 ARN 직접 지정)
# WAF 가 별도 state 라 aws_lb.alb 를 직접 못 보므로, 연결할 ALB ARN 을 여기에 직접 적는다.
# ※ ALB 가 재생성되어 ARN(끝의 무작위 접미사)이 바뀌면 이 값만 갱신.
# ※ 이 방식에서는 terraform.tfvars 가 더 이상 필요 없으므로 삭제할 것.
# =========================================================

terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.0"
    }
    # waf_alert.tf 의 archive_file(zip)용
    archive = {
      source  = "hashicorp/archive"
      version = ">= 2.0"
    }
  }

  # 별도 state 를 위한 backend (예: S3). 미설정 시 이 폴더에 로컬 state 생성.
  # backend "s3" {
  #   bucket = "<your-tf-state-bucket>"
  #   key    = "waf/terraform.tfstate"
  #   region = "ap-northeast-2"
  # }
}

provider "aws" {
  region = "ap-northeast-2" # WAF(REGIONAL)와 ALB 는 같은 리전이어야 함
}

locals {
  # 연결할 ALB ARN (instance/ state 의 public-backend-alb 에서 확인한 값)
  alb_arn = "arn:aws:elasticloadbalancing:ap-northeast-2:248312021173:loadbalancer/app/public-backend-alb/cda1a47aa1a51c26"
}

resource "aws_wafv2_web_acl_association" "backend" {
  resource_arn = local.alb_arn
  web_acl_arn  = aws_wafv2_web_acl.backend.arn
}

# apply 후 '어느 ALB 에 붙었는지' 확인용
output "waf_attached_alb_arn" {
  value       = local.alb_arn
  description = "WAF 가 연결된 ALB ARN"
}
