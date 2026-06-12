"""
WAF 차단 급증 알림 Lambda (급증형/요약)
흐름: CloudWatch 알람(BlockedRequests 5분 합계 >= N) → SNS → 이 Lambda → Slack Webhook
- 알람이 ALARM 상태로 전환될 때만 동작(조용함).
- 최근 WINDOW_MINUTES 동안 '규칙별' BlockedRequests를 조회해 어떤 공격이 몇 건인지 요약.
- 외부 패키지 불필요(boto3 + 표준 라이브러리 urllib만 사용) → 의존성 zip 없이 배포 가능.
"""
import os
import json
import datetime
import urllib.request
import boto3

cw = boto3.client("cloudwatch")
ssm = boto3.client("ssm")

ACL = os.environ["WEB_ACL_NAME"]
WAF_REGION = os.environ["WAF_REGION"]
WEBHOOK_PARAM = os.environ["SLACK_WEBHOOK_PARAM"]
WINDOW_MIN = int(os.environ.get("WINDOW_MINUTES", "5"))

# waf.tf 의 13개 규칙 metric_name 과 동일
RULES = [
    "case1-geo-allowlist", "case2-rate-ranking", "case2-rate-unlock",
    "case3-rate-progress", "case4-aws-common-ruleset", "case4-aws-sqli-ruleset",
    "case5-body-size-limit", "case6-rate-login", "case7-rate-signup",
    "case8-block-tool-user-agents", "case9-aws-anonymous-ip",
    "case10-aws-known-bad-inputs", "case10-log4j-jndi",
]


def _get_webhook_url():
    return ssm.get_parameter(Name=WEBHOOK_PARAM, WithDecryption=True)["Parameter"]["Value"]


def _rule_breakdown():
    """최근 WINDOW_MIN 분간 규칙별 차단 건수 합계를 {규칙: 건수}로 반환(0 제외)."""
    end = datetime.datetime.utcnow()
    start = end - datetime.timedelta(minutes=WINDOW_MIN)
    queries = [{
        "Id": f"r{i}",
        "MetricStat": {
            "Metric": {
                "Namespace": "AWS/WAFV2", "MetricName": "BlockedRequests",
                "Dimensions": [
                    {"Name": "WebACL", "Value": ACL},
                    {"Name": "Rule", "Value": r},
                    {"Name": "Region", "Value": WAF_REGION},
                ],
            },
            "Period": WINDOW_MIN * 60, "Stat": "Sum",
        },
        "ReturnData": True,
    } for i, r in enumerate(RULES)]

    resp = cw.get_metric_data(MetricDataQueries=queries, StartTime=start, EndTime=end)
    counts = {}
    for res in resp.get("MetricDataResults", []):
        idx = int(res["Id"][1:])
        total = int(sum(res.get("Values", []) or []))
        if total > 0:
            counts[RULES[idx]] = total
    return counts


def _post_slack(text):
    url = _get_webhook_url()
    body = json.dumps({"text": text}).encode("utf-8")
    req = urllib.request.Request(url, data=body, headers={"Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=10) as r:
        r.read()


def handler(event, context):
    # SNS → CloudWatch 알람 메시지 파싱. ALARM 전환일 때만 알림.
    state, reason = "ALARM", ""
    try:
        msg = json.loads(event["Records"][0]["Sns"]["Message"])
        state = msg.get("NewStateValue", "ALARM")
        reason = msg.get("NewStateReason", "")
    except Exception:
        pass
    if state != "ALARM":
        return {"skipped": state}

    bd = _rule_breakdown()
    total = sum(bd.values())

    lines = [f":rotating_light: *WAF 차단 급증 감지* — 최근 {WINDOW_MIN}분 합계 *{total}건*"]
    if bd:
        for rule, cnt in sorted(bd.items(), key=lambda x: -x[1])[:8]:
            lines.append(f"• `{rule}` : {cnt}건")
    else:
        lines.append("• (규칙별 집계가 아직 없음 — 지표 반영 지연일 수 있음)")
    lines.append(f"_Web ACL: {ACL} · {WAF_REGION} · CloudWatch에서 상세 확인_")

    _post_slack("\n".join(lines))
    return {"sent": total, "rules": bd}
