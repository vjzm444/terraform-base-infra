import zlib from "zlib";
import {
  FirehoseClient,
  PutRecordBatchCommand
} from "@aws-sdk/client-firehose";

const REGION = process.env.AWS_REGION || "ap-northeast-2";
const DELIVERY_STREAM_NAME = process.env.DELIVERY_STREAM_NAME || "vpc-flow-firehose";

const firehose = new FirehoseClient({ region: REGION });

const toNumberOrNull = (value) => {
  if (
    value === undefined ||
    value === null ||
    value === "-" ||
    value === ""
  ) {
    return null;
  }

  const n = Number(value);
  return Number.isNaN(n) ? null : n;
};

const toIpOrNull = (value) => {
  if (
    value === undefined ||
    value === null ||
    value === "-" ||
    value === ""
  ) {
    return null;
  }

  const ipv4 = /^(\d{1,3}\.){3}\d{1,3}$/;

  if (!ipv4.test(value)) {
    return null;
  }

  const parts = value.split(".").map(Number);
  const valid = parts.every((part) => part >= 0 && part <= 255);

  return valid ? value : null;
};

const isPrivateIp = (ip) => {
  if (!ip) return false;

  const parts = ip.split(".").map(Number);

  if (parts.length !== 4 || parts.some((v) => Number.isNaN(v))) {
    return false;
  }

  const [a, b] = parts;

  if (a === 10) return true;
  if (a === 172 && b >= 16 && b <= 31) return true;
  if (a === 192 && b === 168) return true;
  if (a === 127) return true;
  if (a === 169 && b === 254) return true;

  return false;
};

const protocolName = (protocol) => {
  switch (protocol) {
    case 1:
      return "ICMP";
    case 6:
      return "TCP";
    case 17:
      return "UDP";
    default:
      return protocol === null ? "UNKNOWN" : `PROTO_${protocol}`;
  }
};

const serviceName = (port) => {
  const services = {
    20: "FTP-DATA",
    21: "FTP",
    22: "SSH",
    23: "TELNET",
    25: "SMTP",
    53: "DNS",
    80: "HTTP",
    110: "POP3",
    123: "NTP",
    143: "IMAP",
    443: "HTTPS",
    445: "SMB",
    465: "SMTPS",
    993: "IMAPS",
    995: "POP3S",
    1433: "MSSQL",
    1521: "ORACLE",
    3306: "MYSQL",
    3389: "RDP",
    5432: "POSTGRESQL",
    5601: "OPENSEARCH-DASHBOARDS",
    6379: "REDIS",
    8080: "HTTP-ALT",
    9200: "OPENSEARCH",
    9300: "OPENSEARCH-TRANSPORT"
  };

  return services[port] || "UNKNOWN";
};

const trafficDirection = ({ isPrivateSrc, isPrivateDst }) => {
  if (!isPrivateSrc && isPrivateDst) return "inbound";
  if (isPrivateSrc && !isPrivateDst) return "outbound";
  if (isPrivateSrc && isPrivateDst) return "internal";
  return "external";
};

const calculateSeverity = ({ action, dstport, isPrivateSrc, isPrivateDst }) => {
  const dangerousPorts = new Set([
    22,
    23,
    445,
    1433,
    1521,
    3306,
    3389,
    5432,
    5601,
    6379,
    9200,
    9300
  ]);

  if (
    action === "REJECT" &&
    isPrivateDst &&
    !isPrivateSrc &&
    dangerousPorts.has(dstport)
  ) {
    return { severity: "critical", risk_score: 95 };
  }

  if (action === "REJECT" && isPrivateDst && !isPrivateSrc) {
    return { severity: "high", risk_score: 70 };
  }

  if (
    action === "ACCEPT" &&
    isPrivateDst &&
    !isPrivateSrc &&
    dangerousPorts.has(dstport)
  ) {
    return { severity: "high", risk_score: 80 };
  }

  if (action === "ACCEPT" && isPrivateDst && !isPrivateSrc) {
    return { severity: "medium", risk_score: 50 };
  }

  if (action === "REJECT") {
    return { severity: "medium", risk_score: 40 };
  }

  return { severity: "low", risk_score: 10 };
};

const decodeCloudWatchLogsPayload = (awslogsData) => {
  const compressedPayload = Buffer.from(awslogsData, "base64");
  const uncompressedPayload = zlib.gunzipSync(compressedPayload);
  return JSON.parse(uncompressedPayload.toString("utf-8"));
};

const parseVpcFlowLog = ({ message, timestamp, logGroup, logStream, owner }) => {
  const fields = message.trim().split(/\s+/);

  if (fields.length < 14) {
    return {
      drop: false,
      document: {
        "@timestamp": new Date(timestamp).toISOString(),
        parse_error: true,
        parse_error_reason: "VPC Flow Logs field count is less than 14",
        field_count: fields.length,
        raw_message: message,
        log_group: logGroup,
        log_stream: logStream,
        owner,
        severity: "unknown",
        risk_score: 0
      }
    };
  }

  const version = toNumberOrNull(fields[0]);
  const account_id = fields[1] === "-" ? null : fields[1];
  const interface_id = fields[2] === "-" ? null : fields[2];

  const srcaddr = toIpOrNull(fields[3]);
  const dstaddr = toIpOrNull(fields[4]);

  const srcport = toNumberOrNull(fields[5]);
  const dstport = toNumberOrNull(fields[6]);
  const protocol = toNumberOrNull(fields[7]);
  const packets = toNumberOrNull(fields[8]);
  const bytes = toNumberOrNull(fields[9]);
  const start = toNumberOrNull(fields[10]);
  const end = toNumberOrNull(fields[11]);

  const action = fields[12] === "-" ? null : fields[12];
  const log_status = fields[13] === "-" ? null : fields[13];

  // NODATA / SKIPDATA는 대시보드 분석용으로는 제외하는 것을 추천
  if (log_status === "NODATA" || log_status === "SKIPDATA") {
    return {
      drop: true,
      document: null
    };
  }

  const is_private_src = isPrivateIp(srcaddr);
  const is_private_dst = isPrivateIp(dstaddr);

  const direction = trafficDirection({
    isPrivateSrc: is_private_src,
    isPrivateDst: is_private_dst
  });

  const severityInfo = calculateSeverity({
    action,
    dstport,
    isPrivateSrc: is_private_src,
    isPrivateDst: is_private_dst
  });

  return {
    drop: false,
    document: {
      "@timestamp": new Date(timestamp).toISOString(),

      version,
      account_id,
      interface_id,

      srcaddr,
      dstaddr,
      srcport,
      dstport,

      protocol,
      protocol_name: protocolName(protocol),

      packets,
      bytes,

      start,
      end,
      start_time: start ? new Date(start * 1000).toISOString() : null,
      end_time: end ? new Date(end * 1000).toISOString() : null,

      action,
      log_status,

      traffic_direction: direction,
      service_name: serviceName(dstport),

      is_private_src,
      is_private_dst,
      src_category: is_private_src ? "private" : "public",
      dst_category: is_private_dst ? "private" : "public",

      severity: severityInfo.severity,
      risk_score: severityInfo.risk_score,

      raw_message: message,

      log_group: logGroup,
      log_stream: logStream,
      owner
    }
  };
};

const chunkArray = (items, size) => {
  const chunks = [];

  for (let i = 0; i < items.length; i += size) {
    chunks.push(items.slice(i, i + size));
  }

  return chunks;
};

export const handler = async (event) => {
  console.log("✅ VPC Flow Logs to Firehose transformer v3");

  // ✅ CloudWatch Logs 구독 필터 이벤트인지 확인
  if (!event.awslogs || !event.awslogs.data) {
    console.error("Invalid event shape. Expected CloudWatch Logs subscription event with event.awslogs.data");
    console.error("Received event keys:", Object.keys(event || {}));

    throw new Error(
      "Invalid event shape. This Lambda expects CloudWatch Logs subscription event, not Firehose transformation event."
    );
  }

  const payload = decodeCloudWatchLogsPayload(event.awslogs.data);

  if (payload.messageType !== "DATA_MESSAGE") {
    console.log("Dropped non-DATA_MESSAGE:", payload.messageType);

    return {
      statusCode: 200,
      message: `Dropped ${payload.messageType}`
    };
  }

  const documents = [];

  for (const log of payload.logEvents || []) {
    const parsed = parseVpcFlowLog({
      message: log.message,
      timestamp: log.timestamp,
      logGroup: payload.logGroup,
      logStream: payload.logStream,
      owner: payload.owner
    });

    if (!parsed.drop && parsed.document) {
      documents.push(parsed.document);
    }
  }

  console.log("Parsed VPC Flow Log documents:", documents.length);

  if (documents.length === 0) {
    return {
      statusCode: 200,
      records: 0,
      message: "No documents to send"
    };
  }

  const firehoseRecords = documents.map((doc) => ({
    Data: Buffer.from(JSON.stringify(doc) + "\n", "utf-8")
  }));

  const chunks = chunkArray(firehoseRecords, 500);

  let totalFailed = 0;
  let totalSent = 0;

  for (const chunk of chunks) {
    const response = await firehose.send(
      new PutRecordBatchCommand({
        DeliveryStreamName: DELIVERY_STREAM_NAME,
        Records: chunk
      })
    );

    const failedPutCount = response.FailedPutCount || 0;

    totalFailed += failedPutCount;
    totalSent += chunk.length;

    console.log("PutRecordBatch result:", {
      sent: chunk.length,
      failedPutCount
    });

    if (failedPutCount > 0) {
      console.error("Failed records:", response.RequestResponses);
    }
  }

  if (totalFailed > 0) {
    throw new Error(`Firehose PutRecordBatch failed. totalFailed=${totalFailed}`);
  }

  return {
    statusCode: 200,
    sent: totalSent,
    failed: totalFailed
  };
};