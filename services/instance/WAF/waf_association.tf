# =========================================================
# [버전 A] 현재 구조 — instance/WAF 가 instance/ 의 '자식 모듈'일 때
# 부모(instance/)가 ALB ARN 을 넘겨주므로, 여기서는 변수로 받기만 한다.
# (자식 모듈이므로 provider/terraform 블록은 두지 않는다 — 부모 것을 상속)
#
# 사용법:
#  1) 이 파일을 instance/WAF/waf_association.tf 로 둔다.
#  2) waf.tf 안에 있던 기존 aws_wafv2_web_acl_association 블록(resource_arn = aws_lb.alb.arn)은
#     중복되므로 반드시 삭제한다.
#  3) 부모(instance/)에 waf_module_parent.tf 의 module "waf" 블록을 추가한다.
# =========================================================

variable "alb_arn" {
  type        = string
  description = "부모(instance) 모듈이 전달하는 ALB ARN"
}

resource "aws_wafv2_web_acl_association" "backend" {
  resource_arn = var.alb_arn
  web_acl_arn  = aws_wafv2_web_acl.backend.arn
}
