# =========================================================
# [버전 A 전용] 부모(instance/)에 추가 — WAF 자식 모듈을 호출하며 ALB ARN 전달.
# 이 파일을 instance/ (WAF 의 상위 폴더)에 둔다.  ※ instance/WAF/ 가 아니라 instance/ 다.
#
# 이미 module "waf" 블록이 있다면 새로 만들지 말고 alb_arn 줄만 추가하면 된다.
# (Terraform 은 하위 폴더를 자동 포함하지 않으므로, WAF 를 함께 적용하려면
#  이렇게 module 블록으로 호출해야 한다.)
# =========================================================

module "waf" {
  source  = "./WAF"
  alb_arn = aws_lb.alb.arn
}
