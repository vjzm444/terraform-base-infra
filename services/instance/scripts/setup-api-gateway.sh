#!/usr/bin/env bash
set -euo pipefail

export AWS_PAGER=""

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${SCRIPT_DIR}/vamserlike.env"

if [ -f "${ENV_FILE}" ]; then
  sed -i 's/\r$//' "${ENV_FILE}" 2>/dev/null || true
  source "${ENV_FILE}"
else
  echo "[WARN] ${ENV_FILE} not found. setup-api-gateway will use default values."
fi

AWS_REGION="${AWS_REGION:-ap-northeast-2}"
CLUSTER_NAME="${CLUSTER_NAME:-eks-demo}"
VAMSERLIKE_NAMESPACE="${VAMSERLIKE_NAMESPACE:-vamserlike}"

API_GATEWAY_NAME="${API_GATEWAY_NAME:-vamserlike-backend-http-api}"
API_GATEWAY_RECREATE="${API_GATEWAY_RECREATE:-true}"

# 테스트 단계에서는 * 로 시작.
# 최종 Unity WebGL CloudFront 도메인이 확정되면 env에서 아래처럼 제한:
# API_GATEWAY_CORS_ALLOW_ORIGINS=https://xxxxx.cloudfront.net,https://game.example.com
API_GATEWAY_CORS_ALLOW_ORIGINS="${API_GATEWAY_CORS_ALLOW_ORIGINS:-*}"
API_GATEWAY_CORS_ALLOW_METHODS="${API_GATEWAY_CORS_ALLOW_METHODS:-GET,POST,PUT,DELETE,PATCH,OPTIONS}"
API_GATEWAY_CORS_ALLOW_HEADERS="${API_GATEWAY_CORS_ALLOW_HEADERS:-authorization,content-type,x-requested-with}"
API_GATEWAY_CORS_EXPOSE_HEADERS="${API_GATEWAY_CORS_EXPOSE_HEADERS:-date}"
API_GATEWAY_CORS_MAX_AGE="${API_GATEWAY_CORS_MAX_AGE:-3600}"

BACKEND_INGRESS_NAME="${BACKEND_INGRESS_NAME:-vamserlike-backend-ingress}"
COGNITO_SECRET_NAME="${COGNITO_SECRET_NAME:-vamserlike-cognito-secret}"

OUTPUT_FILE="${SCRIPT_DIR}/api-gateway-output.env"

echo "===== Vamserlike API Gateway Setup Start ====="
echo "AWS_REGION=${AWS_REGION}"
echo "CLUSTER_NAME=${CLUSTER_NAME}"
echo "VAMSERLIKE_NAMESPACE=${VAMSERLIKE_NAMESPACE}"
echo "API_GATEWAY_NAME=${API_GATEWAY_NAME}"
echo "API_GATEWAY_RECREATE=${API_GATEWAY_RECREATE}"
echo "API_GATEWAY_CORS_ALLOW_ORIGINS=${API_GATEWAY_CORS_ALLOW_ORIGINS}"
echo "OUTPUT_FILE=${OUTPUT_FILE}"

echo "===== Check Required Commands ====="
for cmd in aws kubectl curl jq python3 base64; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "[ERROR] required command not found: $cmd"
    exit 1
  fi
done

echo "===== Check AWS Identity ====="
aws sts get-caller-identity --no-cli-pager

echo "===== Set AWS Region ====="
aws configure set default.region "${AWS_REGION}" || true

echo "===== Update kubeconfig ====="
aws eks update-kubeconfig \
  --region "${AWS_REGION}" \
  --name "${CLUSTER_NAME}"

echo "===== Resolve Backend ALB ====="
BACKEND_ALB="${BACKEND_ALB:-$(kubectl get ingress "${BACKEND_INGRESS_NAME}" \
  -n "${VAMSERLIKE_NAMESPACE}" \
  -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || true)}"

if [ -z "${BACKEND_ALB}" ]; then
  echo "[ERROR] Backend ALB not found."
  echo "Check:"
  echo "kubectl get ingress -n ${VAMSERLIKE_NAMESPACE}"
  echo "kubectl describe ingress ${BACKEND_INGRESS_NAME} -n ${VAMSERLIKE_NAMESPACE}"
  exit 1
fi

echo "BACKEND_ALB=${BACKEND_ALB}"

echo "===== Check Backend Health Through ALB ====="
HEALTH_CODE="$(curl -s -o /dev/null -w "%{http_code}" "http://${BACKEND_ALB}/api/Health" || true)"
echo "ALB Health HTTP Code=${HEALTH_CODE}"

if [ "${HEALTH_CODE}" != "200" ]; then
  HEALTH_CODE_LOWER="$(curl -s -o /dev/null -w "%{http_code}" "http://${BACKEND_ALB}/api/health" || true)"
  echo "ALB Health Lowercase HTTP Code=${HEALTH_CODE_LOWER}"

  if [ "${HEALTH_CODE_LOWER}" != "200" ]; then
    echo "[WARN] /api/Health and /api/health did not return 200."
    echo "Continue, but API Gateway test may fail."
  fi
fi

echo "===== Resolve Cognito Values ====="
COGNITO_USER_POOL_ID="${COGNITO_USER_POOL_ID:-$(kubectl get secret "${COGNITO_SECRET_NAME}" \
  -n "${VAMSERLIKE_NAMESPACE}" \
  -o jsonpath='{.data.userPoolId}' 2>/dev/null | base64 -d || true)}"

COGNITO_CLIENT_ID="${COGNITO_CLIENT_ID:-$(kubectl get secret "${COGNITO_SECRET_NAME}" \
  -n "${VAMSERLIKE_NAMESPACE}" \
  -o jsonpath='{.data.clientId}' 2>/dev/null | base64 -d || true)}"

if [ -z "${COGNITO_USER_POOL_ID}" ] || [ -z "${COGNITO_CLIENT_ID}" ]; then
  echo "[ERROR] Cognito values not found."
  echo "Expected Kubernetes secret: ${VAMSERLIKE_NAMESPACE}/${COGNITO_SECRET_NAME}"
  echo "Required keys: userPoolId, clientId"
  exit 1
fi

echo "COGNITO_USER_POOL_ID=${COGNITO_USER_POOL_ID}"
echo "COGNITO_CLIENT_ID=${COGNITO_CLIENT_ID}"

ISSUER="https://cognito-idp.${AWS_REGION}.amazonaws.com/${COGNITO_USER_POOL_ID}"
echo "ISSUER=${ISSUER}"

echo "===== Generate CORS Configuration ====="
CORS_FILE="/tmp/vamserlike-api-gateway-cors.json"

export API_GATEWAY_CORS_ALLOW_ORIGINS
export API_GATEWAY_CORS_ALLOW_METHODS
export API_GATEWAY_CORS_ALLOW_HEADERS
export API_GATEWAY_CORS_EXPOSE_HEADERS
export API_GATEWAY_CORS_MAX_AGE

python3 <<'PY' > "${CORS_FILE}"
import json
import os

def split_csv(value: str):
    return [x.strip() for x in value.split(",") if x.strip()]

cors = {
    "AllowOrigins": split_csv(os.environ.get("API_GATEWAY_CORS_ALLOW_ORIGINS", "*")),
    "AllowMethods": split_csv(os.environ.get("API_GATEWAY_CORS_ALLOW_METHODS", "GET,POST,PUT,DELETE,PATCH,OPTIONS")),
    "AllowHeaders": split_csv(os.environ.get("API_GATEWAY_CORS_ALLOW_HEADERS", "authorization,content-type,x-requested-with")),
    "ExposeHeaders": split_csv(os.environ.get("API_GATEWAY_CORS_EXPOSE_HEADERS", "date")),
    "MaxAge": int(os.environ.get("API_GATEWAY_CORS_MAX_AGE", "3600")),
}

print(json.dumps(cors))
PY

cat "${CORS_FILE}"
echo

echo "===== Delete Existing API Gateway If Enabled ====="
EXISTING_API_ID="$(aws apigatewayv2 get-apis \
  --region "${AWS_REGION}" \
  --query "Items[?Name=='${API_GATEWAY_NAME}'].ApiId | [0]" \
  --output text 2>/dev/null || true)"

if [ "${EXISTING_API_ID}" != "None" ] && [ -n "${EXISTING_API_ID}" ]; then
  echo "Existing API found: ${EXISTING_API_ID}"

  if [ "${API_GATEWAY_RECREATE}" = "true" ]; then
    echo "Delete existing API: ${EXISTING_API_ID}"
    aws apigatewayv2 delete-api \
      --region "${AWS_REGION}" \
      --api-id "${EXISTING_API_ID}"
  else
    echo "[ERROR] Existing API already exists and API_GATEWAY_RECREATE=false."
    echo "Set API_GATEWAY_RECREATE=true in vamserlike.env or delete the API manually."
    exit 1
  fi
else
  echo "No existing API found."
fi

echo "===== Create HTTP API ====="
API_ID="$(aws apigatewayv2 create-api \
  --region "${AWS_REGION}" \
  --name "${API_GATEWAY_NAME}" \
  --protocol-type HTTP \
  --cors-configuration "file://${CORS_FILE}" \
  --query 'ApiId' \
  --output text)"

echo "API_ID=${API_ID}"

echo "===== Create Default Stage ====="
aws apigatewayv2 create-stage \
  --region "${AWS_REGION}" \
  --api-id "${API_ID}" \
  --stage-name '$default' \
  --auto-deploy >/dev/null

echo "===== Create Integrations ====="

AUTH_INT="$(aws apigatewayv2 create-integration \
  --region "${AWS_REGION}" \
  --api-id "${API_ID}" \
  --integration-type HTTP_PROXY \
  --integration-method ANY \
  --integration-uri "http://${BACKEND_ALB}/api/Auth/{proxy}" \
  --payload-format-version "1.0" \
  --query 'IntegrationId' \
  --output text)"

AUTH_LOWER_INT="$(aws apigatewayv2 create-integration \
  --region "${AWS_REGION}" \
  --api-id "${API_ID}" \
  --integration-type HTTP_PROXY \
  --integration-method ANY \
  --integration-uri "http://${BACKEND_ALB}/api/auth/{proxy}" \
  --payload-format-version "1.0" \
  --query 'IntegrationId' \
  --output text)"

HEALTH_INT="$(aws apigatewayv2 create-integration \
  --region "${AWS_REGION}" \
  --api-id "${API_ID}" \
  --integration-type HTTP_PROXY \
  --integration-method ANY \
  --integration-uri "http://${BACKEND_ALB}/api/Health" \
  --payload-format-version "1.0" \
  --query 'IntegrationId' \
  --output text)"

HEALTH_LOWER_INT="$(aws apigatewayv2 create-integration \
  --region "${AWS_REGION}" \
  --api-id "${API_ID}" \
  --integration-type HTTP_PROXY \
  --integration-method ANY \
  --integration-uri "http://${BACKEND_ALB}/api/health" \
  --payload-format-version "1.0" \
  --query 'IntegrationId' \
  --output text)"

SWAGGER_INT="$(aws apigatewayv2 create-integration \
  --region "${AWS_REGION}" \
  --api-id "${API_ID}" \
  --integration-type HTTP_PROXY \
  --integration-method ANY \
  --integration-uri "http://${BACKEND_ALB}/swagger/{proxy}" \
  --payload-format-version "1.0" \
  --query 'IntegrationId' \
  --output text)"

SWAGGER_ROOT_INT="$(aws apigatewayv2 create-integration \
  --region "${AWS_REGION}" \
  --api-id "${API_ID}" \
  --integration-type HTTP_PROXY \
  --integration-method ANY \
  --integration-uri "http://${BACKEND_ALB}/swagger" \
  --payload-format-version "1.0" \
  --query 'IntegrationId' \
  --output text)"

API_INT="$(aws apigatewayv2 create-integration \
  --region "${AWS_REGION}" \
  --api-id "${API_ID}" \
  --integration-type HTTP_PROXY \
  --integration-method ANY \
  --integration-uri "http://${BACKEND_ALB}/api/{proxy}" \
  --payload-format-version "1.0" \
  --query 'IntegrationId' \
  --output text)"

CORS_INT="$(aws apigatewayv2 create-integration \
  --region "${AWS_REGION}" \
  --api-id "${API_ID}" \
  --integration-type HTTP_PROXY \
  --integration-method ANY \
  --integration-uri "http://${BACKEND_ALB}/api/Health" \
  --payload-format-version "1.0" \
  --query 'IntegrationId' \
  --output text)"

echo "AUTH_INT=${AUTH_INT}"
echo "AUTH_LOWER_INT=${AUTH_LOWER_INT}"
echo "HEALTH_INT=${HEALTH_INT}"
echo "HEALTH_LOWER_INT=${HEALTH_LOWER_INT}"
echo "SWAGGER_INT=${SWAGGER_INT}"
echo "SWAGGER_ROOT_INT=${SWAGGER_ROOT_INT}"
echo "API_INT=${API_INT}"
echo "CORS_INT=${CORS_INT}"

echo "===== Create Cognito JWT Authorizer ====="
AUTHORIZER_ID="$(aws apigatewayv2 create-authorizer \
  --region "${AWS_REGION}" \
  --api-id "${API_ID}" \
  --name "vamserlike-cognito-jwt-authorizer" \
  --authorizer-type JWT \
  --identity-source '$request.header.Authorization' \
  --jwt-configuration "Audience=${COGNITO_CLIENT_ID},Issuer=${ISSUER}" \
  --query 'AuthorizerId' \
  --output text)"

echo "AUTHORIZER_ID=${AUTHORIZER_ID}"

echo "===== Create Public Routes ====="

aws apigatewayv2 create-route \
  --region "${AWS_REGION}" \
  --api-id "${API_ID}" \
  --route-key 'ANY /api/Auth/{proxy+}' \
  --target "integrations/${AUTH_INT}" >/dev/null

aws apigatewayv2 create-route \
  --region "${AWS_REGION}" \
  --api-id "${API_ID}" \
  --route-key 'ANY /api/auth/{proxy+}' \
  --target "integrations/${AUTH_LOWER_INT}" >/dev/null

aws apigatewayv2 create-route \
  --region "${AWS_REGION}" \
  --api-id "${API_ID}" \
  --route-key 'ANY /api/Health' \
  --target "integrations/${HEALTH_INT}" >/dev/null

aws apigatewayv2 create-route \
  --region "${AWS_REGION}" \
  --api-id "${API_ID}" \
  --route-key 'ANY /api/health' \
  --target "integrations/${HEALTH_LOWER_INT}" >/dev/null

aws apigatewayv2 create-route \
  --region "${AWS_REGION}" \
  --api-id "${API_ID}" \
  --route-key 'ANY /swagger' \
  --target "integrations/${SWAGGER_ROOT_INT}" >/dev/null

aws apigatewayv2 create-route \
  --region "${AWS_REGION}" \
  --api-id "${API_ID}" \
  --route-key 'ANY /swagger/{proxy+}' \
  --target "integrations/${SWAGGER_INT}" >/dev/null

# CORS preflight.
# HTTP API 자체 CORS 설정이 preflight 응답을 처리하지만,
# JWT authorizer가 붙는 /api/{proxy+}와 섞일 때를 대비해서 OPTIONS route를 인증 없이 명시.
aws apigatewayv2 create-route \
  --region "${AWS_REGION}" \
  --api-id "${API_ID}" \
  --route-key 'OPTIONS /api/{proxy+}' \
  --target "integrations/${CORS_INT}" >/dev/null

echo "===== Create Protected Routes ====="

aws apigatewayv2 create-route \
  --region "${AWS_REGION}" \
  --api-id "${API_ID}" \
  --route-key 'ANY /api/{proxy+}' \
  --target "integrations/${API_INT}" \
  --authorization-type JWT \
  --authorizer-id "${AUTHORIZER_ID}" >/dev/null

echo "===== Resolve API Endpoint ====="
API_ENDPOINT="$(aws apigatewayv2 get-api \
  --region "${AWS_REGION}" \
  --api-id "${API_ID}" \
  --query 'ApiEndpoint' \
  --output text)"

echo "API_ENDPOINT=${API_ENDPOINT}"

echo "===== Save API Gateway Output ====="
cat > "${OUTPUT_FILE}" <<EOF
API_GATEWAY_ID=${API_ID}
API_GATEWAY_ENDPOINT=${API_ENDPOINT}
API_GATEWAY_NAME=${API_GATEWAY_NAME}
API_GATEWAY_AUTHORIZER_ID=${AUTHORIZER_ID}
API_GATEWAY_BACKEND_ALB=${BACKEND_ALB}
EOF

cat "${OUTPUT_FILE}"

echo "===== Test API Gateway Health ====="
sleep 5

curl -i "${API_ENDPOINT}/api/Health" || true

echo
echo "===== Test CORS Preflight ====="
curl -i -X OPTIONS "${API_ENDPOINT}/api/Health" \
  -H "Origin: http://localhost:3000" \
  -H "Access-Control-Request-Method: GET" \
  -H "Access-Control-Request-Headers: authorization,content-type" || true

echo
echo "===== Test Protected API Without Token ====="
curl -i "${API_ENDPOINT}/api/players/me" || true

echo
echo "===== Vamserlike API Gateway Setup Done ====="
echo "API_ID=${API_ID}"
echo "API_ENDPOINT=${API_ENDPOINT}"
echo ""
echo "Unity WebGL API Base URL:"
echo "${API_ENDPOINT}"