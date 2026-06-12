# =========================================================
# [버전 B / 독립 폴더] WAF 를 ALB 에 연결 + 테스트 툴용 URL 출력
# WAF 가 별도 state 라 ALB 리소스를 직접 못 보므로, 연결할 ALB ARN 을 직접 지정한다.
#
# ※ 현재 대상: k8s-vamserlikebackend (AWS Load Balancer Controller 가 생성한 ALB).
#    이 ALB 는 k8s Ingress 가 재생성되면 ARN/이름이 바뀌므로, 그때 아래 alb_arn 을 갱신할 것.
# ※ terraform.tfvars 는 사용하지 않음(이 파일에 직접 지정).
# =========================================================

terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.0"
    }
    archive = { # waf_alert.tf 의 archive_file(zip)용
      source  = "hashicorp/archive"
      version = ">= 2.0"
    }
  }

  # 별도 state backend (예: S3). 미설정 시 이 폴더에 로컬 state 생성.
  # backend "s3" {
  #   bucket = "<your-tf-state-bucket>"
  #   key    = "waf/terraform.tfstate"
  #   region = "ap-northeast-2"
  # }
}

provider "aws" {
  region = "ap-northeast-2" # WAF(REGIONAL)와 ALB 는 같은 리전
}

locals {
  # 연결할 ALB ARN (콘솔/CLI 에서 확인한 k8s-vamserlikebackend ALB)
  alb_arn = "arn:aws:elasticloadbalancing:ap-northeast-2:248312021173:loadbalancer/app/k8s-vamserlikebackend-b3139b2a14/47cfcebbe328f8f9"
}

# ALB 의 DNS 이름을 가져오기 위해 ARN 으로 조회 (테스트 툴 WAF_TARGET_URL 용)
data "aws_lb" "alb" {
  arn = local.alb_arn
}

resource "aws_wafv2_web_acl_association" "backend" {
  resource_arn = local.alb_arn
  web_acl_arn  = aws_wafv2_web_acl.backend.arn
}

output "waf_attached_alb_arn" {
  value       = local.alb_arn
  description = "WAF 가 연결된 ALB ARN"
}

# 테스트 툴 환경변수에 바로 쓸 수 있는 http 주소
output "waf_target_url" {
  value       = "http://${data.aws_lb.alb.dns_name}"
  description = "테스트 툴 WAF_TARGET_URL 값 (= 연결된 ALB 의 http 주소)"
}
