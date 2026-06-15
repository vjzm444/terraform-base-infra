#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${SCRIPT_DIR}/vamserlike.env"

if [ ! -f "$ENV_FILE" ]; then
  echo "[ERROR] ${ENV_FILE} not found."
  echo "Copy scripts/vamserlike.env.example to scripts/vamserlike.env and edit values."
  exit 1
fi

# Windows CRLF 방지
sed -i 's/\r$//' "$ENV_FILE" 2>/dev/null || true

source "$ENV_FILE"

AWS_REGION="${AWS_REGION:-ap-northeast-2}"
CLUSTER_NAME="${CLUSTER_NAME:-eks-demo}"
NODEGROUP_NAME="${NODEGROUP_NAME:-vamserlike-node-group}"
VPC_CIDR="${VPC_CIDR:-10.40.0.0/16}"
ECR_REPOSITORY="${ECR_REPOSITORY:-vamserlike-backend}"
ARGOCD_APP_NAME="${ARGOCD_APP_NAME:-vamserlike-backend}"
MANIFEST_PATH="${MANIFEST_PATH:-overlays/dev}"

# Backend Image Build / Push
BACKEND_REPO_URL="${BACKEND_REPO_URL:-https://github.com/rlduddl/Vamserlike-backend.git}"
BACKEND_BRANCH="${BACKEND_BRANCH:-rlduddl5519}"
BACKEND_IMAGE_TAG="${BACKEND_IMAGE_TAG:-latest}"
BACKEND_DOCKERFILE_PATH="${BACKEND_DOCKERFILE_PATH:-Dockerfile}"
BACKEND_BUILD_CONTEXT="${BACKEND_BUILD_CONTEXT:-.}"
BACKEND_SOURCE_DIR="${BACKEND_SOURCE_DIR:-${HOME}/Vamserlike-backend}"

# Monitoring / Grafana
MONITORING_ENABLED="${MONITORING_ENABLED:-true}"
GRAFANA_ADMIN_PASSWORD="${GRAFANA_ADMIN_PASSWORD:-Vamserlike123!}"
GRAFANA_RELEASE_NAME="${GRAFANA_RELEASE_NAME:-vamserlike-monitoring}"
GRAFANA_SERVICE_NAME="${GRAFANA_RELEASE_NAME}-grafana"
GRAFANA_ADMIN_SECRET_NAME="${GRAFANA_ADMIN_SECRET_NAME:-vamserlike-grafana-admin}"
GRAFANA_LB=""

# API Gateway / CORS / Cognito JWT Authorizer
# 기본값 false: 처음 배포에서는 EKS/ALB 정상 확인 후 setup-api-gateway.sh를 수동 실행 권장
# 자동까지 원하면 scripts/vamserlike.env에 API_GATEWAY_ENABLED=true 설정
API_GATEWAY_ENABLED="${API_GATEWAY_ENABLED:-false}"
API_GATEWAY_SCRIPT_PATH="${API_GATEWAY_SCRIPT_PATH:-${SCRIPT_DIR}/setup-api-gateway.sh}"

echo "===== Vamserlike Bootstrap Start ====="
echo "AWS_REGION=${AWS_REGION}"
echo "CLUSTER_NAME=${CLUSTER_NAME}"
echo "NODEGROUP_NAME=${NODEGROUP_NAME}"
echo "VPC_CIDR=${VPC_CIDR}"
echo "ECR_REPOSITORY=${ECR_REPOSITORY}"
echo "ARGOCD_APP_NAME=${ARGOCD_APP_NAME}"
echo "MANIFEST_REPO_URL=${MANIFEST_REPO_URL}"
echo "MANIFEST_PATH=${MANIFEST_PATH}"
echo "BACKEND_REPO_URL=${BACKEND_REPO_URL}"
echo "BACKEND_BRANCH=${BACKEND_BRANCH}"
echo "BACKEND_IMAGE_TAG=${BACKEND_IMAGE_TAG}"
echo "BACKEND_DOCKERFILE_PATH=${BACKEND_DOCKERFILE_PATH}"
echo "BACKEND_BUILD_CONTEXT=${BACKEND_BUILD_CONTEXT}"
echo "MONITORING_ENABLED=${MONITORING_ENABLED}"
echo "GRAFANA_RELEASE_NAME=${GRAFANA_RELEASE_NAME}"
echo "GRAFANA_SERVICE_NAME=${GRAFANA_SERVICE_NAME}"
echo "GRAFANA_ADMIN_SECRET_NAME=${GRAFANA_ADMIN_SECRET_NAME}"
echo "API_GATEWAY_ENABLED=${API_GATEWAY_ENABLED}"
echo "API_GATEWAY_SCRIPT_PATH=${API_GATEWAY_SCRIPT_PATH}"

ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)"
ECR_REGISTRY="${ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com"
ECR_REPOSITORY_URI="${ECR_REGISTRY}/${ECR_REPOSITORY}"
BACKEND_FULL_IMAGE="${ECR_REPOSITORY_URI}:${BACKEND_IMAGE_TAG}"

echo "ACCOUNT_ID=${ACCOUNT_ID}"
echo "ECR_REGISTRY=${ECR_REGISTRY}"
echo "ECR_REPOSITORY_URI=${ECR_REPOSITORY_URI}"
echo "BACKEND_FULL_IMAGE=${BACKEND_FULL_IMAGE}"

echo "===== Check IAM Role ====="
aws sts get-caller-identity

echo "===== Set AWS Region ====="
aws configure set default.region "${AWS_REGION}"

echo "===== Check Required Commands ====="
for cmd in aws eksctl kubectl helm jq curl git; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "[ERROR] required command not found: $cmd"
    exit 1
  fi
done

echo "===== Check Required Env Values ====="
REQUIRED_VARS=(
  PUBLIC_SUBNET_2A_NAME
  PUBLIC_SUBNET_2C_NAME
  PRIVATE_SUBNET_2A_NAME
  PRIVATE_SUBNET_2C_NAME
  COGNITO_USER_POOL_ID
  COGNITO_CLIENT_ID
  MYSQL_CONNECTION_STRING
  MANIFEST_REPO_URL
  MANIFEST_PATH
  ARGOCD_APP_NAME
  BACKEND_REPO_URL
  BACKEND_BRANCH
  BACKEND_IMAGE_TAG
  BACKEND_DOCKERFILE_PATH
  BACKEND_BUILD_CONTEXT
)

for var in "${REQUIRED_VARS[@]}"; do
  if [ -z "${!var:-}" ]; then
    echo "[ERROR] required env value is empty: ${var}"
    exit 1
  fi
done

echo "===== Install / Start Docker ====="
if ! command -v docker >/dev/null 2>&1; then
  sudo dnf install -y docker
fi

sudo systemctl enable --now docker
sudo usermod -aG docker ec2-user || true

echo "===== Prepare ECR Repository ====="
if ! aws ecr describe-repositories \
  --region "${AWS_REGION}" \
  --repository-names "${ECR_REPOSITORY}" >/dev/null 2>&1; then
  echo "ECR repository not found. Creating: ${ECR_REPOSITORY}"
  aws ecr create-repository \
    --region "${AWS_REGION}" \
    --repository-name "${ECR_REPOSITORY}" >/dev/null
else
  echo "ECR repository exists: ${ECR_REPOSITORY}"
fi

echo "===== ECR Login ====="
aws ecr get-login-password --region "${AWS_REGION}" | \
  sudo docker login --username AWS --password-stdin "${ECR_REGISTRY}"

echo "===== Clone / Update Backend Repository ====="
if [ ! -d "${BACKEND_SOURCE_DIR}/.git" ]; then
  rm -rf "${BACKEND_SOURCE_DIR}"
  git clone -b "${BACKEND_BRANCH}" "${BACKEND_REPO_URL}" "${BACKEND_SOURCE_DIR}"
else
  cd "${BACKEND_SOURCE_DIR}"
  git fetch origin
  git checkout "${BACKEND_BRANCH}"
  git pull origin "${BACKEND_BRANCH}"
fi

echo "===== Build Backend Docker Image ====="
cd "${BACKEND_SOURCE_DIR}"

sudo docker build \
  -f "${BACKEND_DOCKERFILE_PATH}" \
  -t "${ECR_REPOSITORY}:${BACKEND_IMAGE_TAG}" \
  "${BACKEND_BUILD_CONTEXT}"

sudo docker tag \
  "${ECR_REPOSITORY}:${BACKEND_IMAGE_TAG}" \
  "${BACKEND_FULL_IMAGE}"

echo "===== Push Backend Docker Image to ECR ====="
sudo docker push "${BACKEND_FULL_IMAGE}"

echo "===== Verify ECR Image ====="
aws ecr describe-images \
  --region "${AWS_REGION}" \
  --repository-name "${ECR_REPOSITORY}" \
  --image-ids imageTag="${BACKEND_IMAGE_TAG}" \
  --query "imageDetails[0].[repositoryName,imageTags,imagePushedAt,imageSizeInBytes]" \
  --output table

echo "===== Discover VPC/Subnets ====="
VPC_ID="$(aws ec2 describe-vpcs \
  --region "${AWS_REGION}" \
  --filters "Name=cidr-block,Values=${VPC_CIDR}" \
  --query "Vpcs[0].VpcId" \
  --output text)"

PUBLIC_SUBNET_2A="$(aws ec2 describe-subnets \
  --region "${AWS_REGION}" \
  --filters "Name=vpc-id,Values=${VPC_ID}" "Name=tag:Name,Values=${PUBLIC_SUBNET_2A_NAME}" \
  --query "Subnets[0].SubnetId" \
  --output text)"

PUBLIC_SUBNET_2C="$(aws ec2 describe-subnets \
  --region "${AWS_REGION}" \
  --filters "Name=vpc-id,Values=${VPC_ID}" "Name=tag:Name,Values=${PUBLIC_SUBNET_2C_NAME}" \
  --query "Subnets[0].SubnetId" \
  --output text)"

PRIVATE_SUBNET_2A="$(aws ec2 describe-subnets \
  --region "${AWS_REGION}" \
  --filters "Name=vpc-id,Values=${VPC_ID}" "Name=tag:Name,Values=${PRIVATE_SUBNET_2A_NAME}" \
  --query "Subnets[0].SubnetId" \
  --output text)"

PRIVATE_SUBNET_2C="$(aws ec2 describe-subnets \
  --region "${AWS_REGION}" \
  --filters "Name=vpc-id,Values=${VPC_ID}" "Name=tag:Name,Values=${PRIVATE_SUBNET_2C_NAME}" \
  --query "Subnets[0].SubnetId" \
  --output text)"

echo "VPC_ID=${VPC_ID}"
echo "PUBLIC_SUBNET_2A=${PUBLIC_SUBNET_2A}"
echo "PUBLIC_SUBNET_2C=${PUBLIC_SUBNET_2C}"
echo "PRIVATE_SUBNET_2A=${PRIVATE_SUBNET_2A}"
echo "PRIVATE_SUBNET_2C=${PRIVATE_SUBNET_2C}"

if [[ "$VPC_ID" == "None" || "$PUBLIC_SUBNET_2A" == "None" || "$PUBLIC_SUBNET_2C" == "None" || "$PRIVATE_SUBNET_2A" == "None" || "$PRIVATE_SUBNET_2C" == "None" ]]; then
  echo "[ERROR] Failed to discover VPC/Subnet IDs."
  exit 1
fi

echo "===== Generate eksctl cluster config ====="
cat > "${HOME}/${CLUSTER_NAME}-cluster.yaml" <<EOF
apiVersion: eksctl.io/v1alpha5
kind: ClusterConfig

metadata:
  name: ${CLUSTER_NAME}
  region: ${AWS_REGION}

iam:
  withOIDC: true

vpc:
  id: "${VPC_ID}"
  subnets:
    public:
      ${AWS_REGION}a:
        id: "${PUBLIC_SUBNET_2A}"
      ${AWS_REGION}c:
        id: "${PUBLIC_SUBNET_2C}"
    private:
      ${AWS_REGION}a:
        id: "${PRIVATE_SUBNET_2A}"
      ${AWS_REGION}c:
        id: "${PRIVATE_SUBNET_2C}"

managedNodeGroups:
  - name: ${NODEGROUP_NAME}
    instanceType: t3.medium
    desiredCapacity: 2
    minSize: 2
    maxSize: 5
    volumeSize: 30
    privateNetworking: true
    labels:
      role: worker
      project: vamserlike
    tags:
      nodegroup-role: worker
      k8s.io/cluster-autoscaler/enabled: "true"
      k8s.io/cluster-autoscaler/${CLUSTER_NAME}: "owned"
    iam:
      withAddonPolicies:
        imageBuilder: true
        albIngress: true
        cloudWatch: true
        autoScaler: true

cloudWatch:
  clusterLogging:
    enableTypes:
      - api
      - audit
      - authenticator
      - controllerManager
      - scheduler
EOF

echo "Generated: ${HOME}/${CLUSTER_NAME}-cluster.yaml"

if aws eks describe-cluster --region "${AWS_REGION}" --name "${CLUSTER_NAME}" >/dev/null 2>&1; then
  echo "EKS cluster already exists: ${CLUSTER_NAME}"
else
  echo "===== Create EKS cluster ====="
  eksctl create cluster -f "${HOME}/${CLUSTER_NAME}-cluster.yaml"
fi

echo "===== Update kubeconfig ====="
aws eks update-kubeconfig --region "${AWS_REGION}" --name "${CLUSTER_NAME}"

echo "===== Associate OIDC provider ====="
eksctl utils associate-iam-oidc-provider \
  --cluster "${CLUSTER_NAME}" \
  --region "${AWS_REGION}" \
  --approve

echo "===== Install AWS Load Balancer Controller ====="
cd "${HOME}"

curl -sS -O https://raw.githubusercontent.com/kubernetes-sigs/aws-load-balancer-controller/v2.14.1/docs/install/iam_policy.json

POLICY_ARN="$(aws iam list-policies \
  --query "Policies[?PolicyName=='AWSLoadBalancerControllerIAMPolicy'].Arn" \
  --output text)"

if [ -z "$POLICY_ARN" ]; then
  POLICY_ARN="$(aws iam create-policy \
    --policy-name AWSLoadBalancerControllerIAMPolicy \
    --policy-document file://iam_policy.json \
    --query Policy.Arn \
    --output text)"
fi

echo "POLICY_ARN=${POLICY_ARN}"

eksctl create iamserviceaccount \
  --cluster="${CLUSTER_NAME}" \
  --region="${AWS_REGION}" \
  --namespace=kube-system \
  --name=aws-load-balancer-controller \
  --attach-policy-arn="${POLICY_ARN}" \
  --override-existing-serviceaccounts \
  --approve

helm repo add eks https://aws.github.io/eks-charts || true
helm repo update

helm upgrade --install aws-load-balancer-controller eks/aws-load-balancer-controller \
  -n kube-system \
  --set clusterName="${CLUSTER_NAME}" \
  --set serviceAccount.create=false \
  --set serviceAccount.name=aws-load-balancer-controller \
  --set region="${AWS_REGION}" \
  --set vpcId="${VPC_ID}"

kubectl rollout status deployment/aws-load-balancer-controller -n kube-system --timeout=300s

echo "===== Install AWS for Fluent Bit CloudWatch Logging ====="

kubectl create namespace amazon-cloudwatch --dry-run=client -o yaml | kubectl apply -f -

eksctl create iamserviceaccount \
  --cluster="${CLUSTER_NAME}" \
  --region="${AWS_REGION}" \
  --namespace=amazon-cloudwatch \
  --name=aws-for-fluent-bit \
  --attach-policy-arn=arn:aws:iam::aws:policy/CloudWatchAgentServerPolicy \
  --override-existing-serviceaccounts \
  --approve

helm repo add eks https://aws.github.io/eks-charts || true
helm repo update

helm upgrade --install aws-for-fluent-bit eks/aws-for-fluent-bit \
  -n amazon-cloudwatch \
  --set serviceAccount.create=false \
  --set serviceAccount.name=aws-for-fluent-bit \
  --set cloudWatchLogs.enabled=true \
  --set cloudWatchLogs.region="${AWS_REGION}" \
  --set cloudWatchLogs.logGroupName="/ec2/vamserlike-backend" \
  --set cloudWatchLogs.logStreamPrefix="vamserlike-" \
  --set cloudWatchLogs.logKey="log" \
  --set cloudWatchLogs.autoCreateGroup=true \
  --set cloudWatch.enabled=false \
  --set firehose.enabled=false \
  --set kinesis.enabled=false \
  --set kinesis_streams.enabled=false \
  --set elasticsearch.enabled=false \
  --set s3.enabled=false

kubectl rollout status daemonset/aws-for-fluent-bit -n amazon-cloudwatch --timeout=300s

echo "===== Install Prometheus and Grafana Monitoring Stack ====="

if [ "${MONITORING_ENABLED}" = "true" ]; then
  kubectl create namespace monitoring --dry-run=client -o yaml | kubectl apply -f -

  echo "===== Create Grafana Admin Secret ====="
  kubectl create secret generic "${GRAFANA_ADMIN_SECRET_NAME}" \
    -n monitoring \
    --from-literal=admin-user=admin \
    --from-literal=admin-password="${GRAFANA_ADMIN_PASSWORD}" \
    --dry-run=client -o yaml | kubectl apply -f -

  helm repo add prometheus-community https://prometheus-community.github.io/helm-charts || true
  helm repo update

  helm upgrade --install "${GRAFANA_RELEASE_NAME}" prometheus-community/kube-prometheus-stack \
    -n monitoring \
    --set grafana.enabled=true \
    --set grafana.image.repository=grafana/grafana \
    --set grafana.image.tag=10.4.10 \
    --set grafana.admin.existingSecret="${GRAFANA_ADMIN_SECRET_NAME}" \
    --set grafana.admin.userKey=admin-user \
    --set grafana.admin.passwordKey=admin-password \
    --set grafana.service.type=LoadBalancer \
    --set-string grafana.service.annotations."service\.beta\.kubernetes\.io/aws-load-balancer-type"="external" \
    --set-string grafana.service.annotations."service\.beta\.kubernetes\.io/aws-load-balancer-nlb-target-type"="ip" \
    --set-string grafana.service.annotations."service\.beta\.kubernetes\.io/aws-load-balancer-scheme"="internet-facing" \
    --set grafana.defaultDashboardsEnabled=true \
    --set grafana.defaultDashboardsTimezone=browser \
    --set prometheus.enabled=true \
    --set prometheus.prometheusSpec.retention=2d \
    --set prometheus.prometheusSpec.retentionSize=2GB \
    --set alertmanager.enabled=false \
    --set kubeStateMetrics.enabled=true \
    --set nodeExporter.enabled=true \
    --wait \
    --timeout 10m

  echo "===== Reset Grafana Admin Password ====="
  GRAFANA_POD="$(kubectl get pod -n monitoring \
    -l app.kubernetes.io/name=grafana \
    -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"

  if [ -n "$GRAFANA_POD" ]; then
    kubectl exec -n monitoring "$GRAFANA_POD" -c grafana -- \
      grafana cli admin reset-admin-password "${GRAFANA_ADMIN_PASSWORD}" || \
    kubectl exec -n monitoring "$GRAFANA_POD" -c grafana -- \
      grafana-cli admin reset-admin-password "${GRAFANA_ADMIN_PASSWORD}" || \
    echo "[WARN] Grafana admin password reset command failed. Check Grafana secret or reset manually."
  else
    echo "[WARN] Grafana pod not found. Skip password reset."
  fi

  echo "===== Wait for Grafana LoadBalancer ====="

  for i in {1..40}; do
    GRAFANA_LB="$(kubectl get svc "${GRAFANA_SERVICE_NAME}" -n monitoring -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || true)"

    if [ -n "$GRAFANA_LB" ]; then
      echo "Grafana LB: ${GRAFANA_LB}"
      break
    fi

    echo "Waiting for Grafana LoadBalancer... ${i}/40"
    sleep 15
  done

  if [ -z "$GRAFANA_LB" ]; then
    echo "[WARN] Grafana LoadBalancer hostname is still empty."
  fi
else
  echo "Monitoring install skipped. MONITORING_ENABLED=${MONITORING_ENABLED}"
fi

echo "===== Create Backend Secrets ====="
kubectl create namespace vamserlike --dry-run=client -o yaml | kubectl apply -f -

kubectl create secret generic vamserlike-db-secret \
  -n vamserlike \
  --from-literal=connectionString="${MYSQL_CONNECTION_STRING}" \
  --dry-run=client -o yaml | kubectl apply -f -

kubectl create secret generic vamserlike-cognito-secret \
  -n vamserlike \
  --from-literal=userPoolId="${COGNITO_USER_POOL_ID}" \
  --from-literal=clientId="${COGNITO_CLIENT_ID}" \
  --dry-run=client -o yaml | kubectl apply -f -

echo "===== Install Argo CD ====="
kubectl create namespace argocd --dry-run=client -o yaml | kubectl apply -f -

kubectl apply \
  --server-side \
  --force-conflicts \
  -n argocd \
  -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml

echo "===== Wait for Argo CD Rollout ====="
kubectl rollout status deployment/argocd-server -n argocd --timeout=300s
kubectl rollout status deployment/argocd-repo-server -n argocd --timeout=300s
kubectl rollout status statefulset/argocd-application-controller -n argocd --timeout=300s

echo "===== Expose Argo CD Server with LoadBalancer ====="
kubectl patch svc argocd-server -n argocd \
  -p '{"spec": {"type": "LoadBalancer"}}'

echo "===== Wait for Argo CD LoadBalancer ====="
ARGOCD_LB=""

for i in {1..40}; do
  ARGOCD_LB="$(kubectl get svc argocd-server -n argocd -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || true)"

  if [ -n "$ARGOCD_LB" ]; then
    echo "Argo CD LB: ${ARGOCD_LB}"
    break
  fi

  echo "Waiting for Argo CD LoadBalancer... ${i}/40"
  sleep 15
done

if [ -z "$ARGOCD_LB" ]; then
  echo "[WARN] Argo CD LoadBalancer hostname is still empty."
fi

echo "===== Create Argo CD Application ====="
cat > "${HOME}/vamserlike-backend-argocd-app.yaml" <<EOF
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: ${ARGOCD_APP_NAME}
  namespace: argocd
spec:
  project: default

  source:
    repoURL: ${MANIFEST_REPO_URL}
    targetRevision: main
    path: ${MANIFEST_PATH}
    kustomize:
      images:
        - vamserlike-backend=${BACKEND_FULL_IMAGE}

  destination:
    server: https://kubernetes.default.svc
    namespace: vamserlike

  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
EOF

kubectl apply -f "${HOME}/vamserlike-backend-argocd-app.yaml"

echo "===== Wait for Argo CD Application Sync ====="
for i in {1..40}; do
  APP_SYNC_STATUS="$(kubectl get application "${ARGOCD_APP_NAME}" -n argocd -o jsonpath='{.status.sync.status}' 2>/dev/null || true)"
  APP_HEALTH_STATUS="$(kubectl get application "${ARGOCD_APP_NAME}" -n argocd -o jsonpath='{.status.health.status}' 2>/dev/null || true)"

  echo "ArgoCD App status ${i}/40: sync=${APP_SYNC_STATUS}, health=${APP_HEALTH_STATUS}"

  if [ "${APP_SYNC_STATUS}" = "Synced" ]; then
    break
  fi

  sleep 15
done

echo "===== Wait for Backend Deployment Created ====="
for i in {1..40}; do
  if kubectl get deployment vamserlike-backend -n vamserlike >/dev/null 2>&1; then
    echo "Backend deployment found."
    break
  fi

  echo "Waiting for backend deployment... ${i}/40"
  kubectl get all -n vamserlike || true
  sleep 15
done

echo "===== Ensure Backend Deployment Uses Current Account ECR Image ====="
kubectl set image deployment/vamserlike-backend \
  vamserlike-backend="${BACKEND_FULL_IMAGE}" \
  -n vamserlike || true

kubectl annotate deployment/vamserlike-backend \
  -n vamserlike \
  vamserlike/backend-image="${BACKEND_FULL_IMAGE}" \
  --overwrite || true

echo "===== Wait for Backend Rollout ====="
kubectl rollout status deployment/vamserlike-backend -n vamserlike --timeout=600s || true

echo "===== Wait for Backend Pods ====="
for i in {1..60}; do
  READY_PODS="$(kubectl get pods -n vamserlike -l app=vamserlike-backend --no-headers 2>/dev/null | awk '$2 ~ /^1\/1/ && $3 == "Running" {count++} END {print count+0}')"

  if [ "$READY_PODS" -ge 1 ]; then
    echo "Backend running pods: ${READY_PODS}"
    break
  fi

  echo "Waiting for backend pods... ${i}/60"
  kubectl get pods -n vamserlike || true
  kubectl describe pods -n vamserlike -l app=vamserlike-backend | tail -120 || true
  sleep 15
done

echo "===== Wait for Backend Ingress ALB ====="
BACKEND_ALB=""

for i in {1..40}; do
  BACKEND_ALB="$(kubectl get ingress vamserlike-backend-ingress -n vamserlike -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || true)"

  if [ -n "$BACKEND_ALB" ]; then
    echo "Backend ALB: ${BACKEND_ALB}"
    break
  fi

  echo "Waiting for backend ALB... ${i}/40"
  kubectl get ingress -n vamserlike || true
  sleep 15
done

if [ -z "$BACKEND_ALB" ]; then
  echo "[ERROR] Backend ALB hostname is empty."
  echo "Check:"
  echo "kubectl describe ingress vamserlike-backend-ingress -n vamserlike"
  echo "kubectl logs -n kube-system deployment/aws-load-balancer-controller --tail=100"
  exit 1
fi

echo "===== Wait for Backend ALB DNS ====="
for i in {1..40}; do
  if getent hosts "$BACKEND_ALB" >/dev/null 2>&1; then
    echo "Backend ALB DNS resolved."
    getent hosts "$BACKEND_ALB"
    break
  fi

  echo "Waiting for backend ALB DNS... ${i}/40"
  sleep 15
done

echo "===== Check Backend Health ====="
HEALTH_OK="false"

for i in {1..30}; do
  echo "Health check try ${i}/30"
  if curl -fsS "http://${BACKEND_ALB}/api/health"; then
    echo
    HEALTH_OK="true"
    break
  fi

  echo
  echo "Current backend pods:"
  kubectl get pods -n vamserlike || true
  sleep 15
done

if [ "$HEALTH_OK" != "true" ]; then
  echo "[ERROR] Backend health check failed."
  echo "Check target health and pod logs:"
  echo "kubectl get pods -n vamserlike"
  echo "kubectl describe pods -n vamserlike -l app=vamserlike-backend"
  echo "kubectl logs -n vamserlike -l app=vamserlike-backend --tail=100"
  echo "kubectl describe ingress vamserlike-backend-ingress -n vamserlike"
  exit 1
fi

echo "===== Optional API Gateway Setup ====="
API_GATEWAY_ENDPOINT=""

if [ "${API_GATEWAY_ENABLED}" = "true" ]; then
  if [ ! -f "${API_GATEWAY_SCRIPT_PATH}" ]; then
    echo "[ERROR] API_GATEWAY_ENABLED=true but setup script not found: ${API_GATEWAY_SCRIPT_PATH}"
    echo "Create scripts/setup-api-gateway.sh first or set API_GATEWAY_ENABLED=false."
    exit 1
  fi

  chmod +x "${API_GATEWAY_SCRIPT_PATH}" || true

  echo "Run API Gateway setup script: ${API_GATEWAY_SCRIPT_PATH}"
  bash "${API_GATEWAY_SCRIPT_PATH}"

  API_GATEWAY_NAME="${API_GATEWAY_NAME:-vamserlike-backend-http-api}"

  API_GATEWAY_ID="$(aws apigatewayv2 get-apis     --region "${AWS_REGION}"     --query "Items[?Name=='${API_GATEWAY_NAME}'].ApiId | [0]"     --output text 2>/dev/null || true)"

  if [ -n "${API_GATEWAY_ID}" ] && [ "${API_GATEWAY_ID}" != "None" ]; then
    API_GATEWAY_ENDPOINT="$(aws apigatewayv2 get-api       --region "${AWS_REGION}"       --api-id "${API_GATEWAY_ID}"       --query 'ApiEndpoint'       --output text 2>/dev/null || true)"
  fi

  if [ -n "${API_GATEWAY_ENDPOINT}" ] && [ "${API_GATEWAY_ENDPOINT}" != "None" ]; then
    echo "API Gateway Endpoint: ${API_GATEWAY_ENDPOINT}"
  else
    echo "[WARN] API Gateway endpoint could not be resolved. Check setup-api-gateway.sh output."
  fi
else
  echo "API Gateway setup skipped. Set API_GATEWAY_ENABLED=true in vamserlike.env to enable it."
  echo "Manual command after bootstrap:"
  echo "bash ${API_GATEWAY_SCRIPT_PATH}"
fi

echo "===== Output ====="
ARGOCD_PW="$(kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' 2>/dev/null | base64 -d || true)"

if [ "${MONITORING_ENABLED}" = "true" ]; then
  GRAFANA_LB="$(kubectl get svc "${GRAFANA_SERVICE_NAME}" -n monitoring -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || true)"
fi

echo "Argo CD URL: http://${ARGOCD_LB}"
echo "Argo CD ID : admin"
echo "Argo CD PW : ${ARGOCD_PW}"
echo "Backend Image: ${BACKEND_FULL_IMAGE}"
echo "Backend ALB: http://${BACKEND_ALB}"
echo "Backend Root: http://${BACKEND_ALB}/"
echo "Backend Swagger: http://${BACKEND_ALB}/swagger"
echo "Backend Health: http://${BACKEND_ALB}/api/health"

if [ -n "${API_GATEWAY_ENDPOINT:-}" ] && [ "${API_GATEWAY_ENDPOINT:-}" != "None" ]; then
  echo "API Gateway Endpoint: ${API_GATEWAY_ENDPOINT}"
  echo "API Gateway Health: ${API_GATEWAY_ENDPOINT}/api/Health"
  echo "API Gateway Swagger: ${API_GATEWAY_ENDPOINT}/swagger"
fi

if [ "${MONITORING_ENABLED}" = "true" ]; then
  echo "Grafana URL: http://${GRAFANA_LB}"
  echo "Grafana ID : admin"
  echo "Grafana PW : ${GRAFANA_ADMIN_PASSWORD}"
fi

echo ""
echo "Check commands:"
echo "kubectl get applications -n argocd"
echo "kubectl get pods -n vamserlike"
echo "kubectl get deployment vamserlike-backend -n vamserlike -o wide"
echo "kubectl get ingress -n vamserlike"
echo "kubectl get pods -n amazon-cloudwatch"
echo "kubectl get pods -n monitoring"
echo "kubectl get svc -n monitoring"
echo "kubectl get secret vamserlike-cognito-secret -n vamserlike -o yaml"
echo "bash ${API_GATEWAY_SCRIPT_PATH}"
echo "aws apigatewayv2 get-apis --region ${AWS_REGION} --output table"
echo "aws ecr describe-images --region ${AWS_REGION} --repository-name ${ECR_REPOSITORY} --output table"
echo "aws logs describe-log-groups --region ${AWS_REGION} --log-group-name-prefix /ec2/vamserlike-backend"

echo "===== Vamserlike Bootstrap Done ====="