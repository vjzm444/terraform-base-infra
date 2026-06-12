# =========================================================
# WAF(B 버전 / 독립 폴더)가 연결할 ALB 지정
# 이 파일을 waf_association.tf(B 버전)와 '같은 폴더'에 두면 terraform 이 자동으로 읽는다.
#
# ※ 아래 ARN 은 instance/ state 의 aws_lb.alb(public-backend-alb)에서 확인한 값.
#   이 ALB 가 WAF 를 붙이려는 그 ALB 가 맞는지 확인 후 사용할 것.
#   (다른 ALB 면 그쪽 ARN 으로 교체)
# =========================================================

alb_arn = "arn:aws:elasticloadbalancing:ap-northeast-2:248312021173:loadbalancer/app/public-backend-alb/29a71a139c24908c"

# 이름으로 지정하고 싶으면 위 alb_arn 을 지우고 아래를 사용(둘 중 하나만):
# alb_name = "public-backend-alb"
