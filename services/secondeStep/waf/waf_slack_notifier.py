"""
waf_slack_notifier.py

Vamserlike 백엔드 AWS WAF 차단 알림 Lambda (python3.12)

흐름: CloudWatch 알람(vamserlike-waf-block-spike) -> SNS -> 이 Lambda -> Slack Webhook

이번 수정 사항:
  - 알람 상태(NewStateValue)에 따라 [차단](ALARM) / [정상](OK) 메시지를 분기
  - "WAF가 차단 성공 / 백엔드는 영향 없이 정상 운영 중" 결과 중심 문구
  - 형님의 Grafana 알림과 동일한 포맷(상태/알림명/설명/서비스/기준)
  - 규칙별 BlockedRequests 5분 합계는 GetMetricData 한 번으로 조회
  - 설정값은 waf_alert.tf 의 환경변수에서 읽음(없으면 기본값 사용)

진입 함수: handler  (waf_alert.tf 의 handler = "waf_slack_notifier.handler" 와 일치)
"""

import json
import os
import urllib.request
from datetime import datetime, timedelta, timezone

import boto3

# ---------- 설정 (waf_alert.tf 의 environment 변수에서 주입) ----------
WEBHOOK_PARAM = os.environ.get("SLACK_WEBHOOK_PARAM", "/vamserlike/waf/slack_webhook")
WEB_ACL = os.environ.get("WEB_ACL_NAME", "vamserlike-backend-acl")
REGION = os.environ.get("WAF_REGION", "ap-northeast-2")
THRESHOLD = int(os.environ.get("WAF_BLOCK_THRESHOLD", "50"))
WINDOW_MIN = int(os.environ.get("WINDOW_MINUTES", "5"))

# Web ACL에 정의된 규칙들 (이 중 차단 건수 > 0 인 규칙만 메시지에 표시)
RULES = [
    "case1-geo-allowlist",
    "case2-rate-ranking",
    "case2-rate-unlock",
    "case3-rate-progress",
    "case4-aws-common-ruleset",
    "case4-aws-sqli-ruleset",
    "case5-body-size-limit",
    "case6-rate-login",
    "case7-rate-signup",
    "case8-block-tool-user-agents",
    "case9-aws-anonymous-ip",
    "case10-aws-known-bad-inputs",
    "case10-log4j-jndi",
]

ssm = boto3.client("ssm", region_name=REGION)
cw = boto3.client("cloudwatch", region_name=REGION)


# ---------- 유틸 ----------
def get_webhook_url() -> str:
    """SSM Parameter Store(SecureString)에서 슬랙 웹훅 URL을 복호화해 읽는다."""
    resp = ssm.get_parameter(Name=WEBHOOK_PARAM, WithDecryption=True)
    return resp["Parameter"]["Value"].strip()


def parse_alarm_state(event: dict) -> str:
    """SNS로 감싸진 CloudWatch 알람 메시지에서 상태값을 추출. (ALARM / OK)
    수동 테스트 등 SNS 구조가 아니면 ALARM 으로 간주한다."""
    try:
        message = event["Records"][0]["Sns"]["Message"]
        return json.loads(message).get("NewStateValue", "ALARM")
    except (KeyError, IndexError, TypeError, json.JSONDecodeError):
        return "ALARM"


def get_blocked_counts_by_rule():
    """최근 WINDOW_MIN 분간 규칙별 BlockedRequests 합계를 조회.
    반환: (정렬된 [(rule, count), ...]  (count>0만),  total)"""
    end = datetime.now(timezone.utc)
    start = end - timedelta(minutes=WINDOW_MIN)

    queries = [
        {
            "Id": f"r{i}",
            "MetricStat": {
                "Metric": {
                    "Namespace": "AWS/WAFV2",
                    "MetricName": "BlockedRequests",
                    "Dimensions": [
                        {"Name": "WebACL", "Value": WEB_ACL},
                        {"Name": "Region", "Value": REGION},
                        {"Name": "Rule", "Value": rule},
                    ],
                },
                "Period": WINDOW_MIN * 60,
                "Stat": "Sum",
            },
            "ReturnData": True,
        }
        for i, rule in enumerate(RULES)
    ]

    id_to_rule = {f"r{i}": rule for i, rule in enumerate(RULES)}

    resp = cw.get_metric_data(
        MetricDataQueries=queries,
        StartTime=start,
        EndTime=end,
        ScanBy="TimestampDescending",
    )

    counts = {}
    for result in resp.get("MetricDataResults", []):
        rule = id_to_rule.get(result["Id"])
        total = int(sum(result.get("Values", [])))
        if rule and total > 0:
            counts[rule] = total

    ordered = sorted(counts.items(), key=lambda kv: kv[1], reverse=True)
    return ordered, sum(counts.values())


def post_to_slack(text: str) -> int:
    body = json.dumps({"text": text}).encode("utf-8")
    req = urllib.request.Request(
        get_webhook_url(), data=body, headers={"Content-Type": "application/json"}
    )
    with urllib.request.urlopen(req, timeout=10) as resp:
        return resp.status


# ---------- 메시지 빌더 ----------
def build_alarm_message() -> str:
    rules, total = get_blocked_counts_by_rule()
    if rules:
        lines = "\n".join(f"• `{name}` : {cnt}건" for name, cnt in rules)
    else:
        lines = "• (규칙별 집계가 아직 없음 — 지표 반영 지연일 수 있음)"

    return (
        "🛡️ *[차단] Vamserlike 백엔드 WAF 방어 알림*\n"
        "*상태:* 비정상 트래픽 급증 — WAF가 차단 성공\n\n"
        "*알림명:* WAF 악성 트래픽 차단 감지\n"
        f"*설명:* 최근 {WINDOW_MIN}분간 악성·비정상 요청 *{total}건*을 WAF 규칙이 차단했습니다. "
        "백엔드는 영향 없이 정상 운영 중입니다.\n\n"
        f"{lines}\n\n"
        f"*서비스:* Vamserlike Backend (Web ACL: {WEB_ACL})\n"
        f"*기준:* 최근 {WINDOW_MIN}분 차단 건수가 {THRESHOLD}건을 초과하면 알림 발생\n"
        f"리전: {REGION} · CloudWatch에서 상세 확인"
    )


def build_ok_message() -> str:
    return (
        "✅ *[정상] Vamserlike 백엔드 WAF 방어 알림*\n"
        "*상태:* 차단 급증 종료 — 정상 트래픽으로 복구\n\n"
        "*알림명:* WAF 악성 트래픽 차단 감지\n"
        f"*설명:* 비정상 트래픽이 줄어 최근 {WINDOW_MIN}분 차단 건수가 "
        f"임계치({THRESHOLD}건) 아래로 복구되었습니다.\n\n"
        f"*서비스:* Vamserlike Backend (Web ACL: {WEB_ACL})\n"
        f"*기준:* 최근 {WINDOW_MIN}분 차단 건수가 {THRESHOLD}건을 초과하면 알림 발생\n"
        f"리전: {REGION}"
    )


# ---------- 핸들러 (waf_alert.tf 의 handler 와 이름 일치) ----------
def handler(event, context):
    state = parse_alarm_state(event)
    text = build_ok_message() if state == "OK" else build_alarm_message()
    status = post_to_slack(text)
    return {"ok": True, "state": state, "slack_status": status}
