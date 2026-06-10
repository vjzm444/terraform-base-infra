#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${SCRIPT_DIR}/vamserlike.env"

# env 파일이 있으면 사용하고, 없으면 기본값으로 진행
if [ -f "$ENV_FILE" ]; then
  sed -i 's/\r$//' "$ENV_FILE" 2>/dev/null || true
  source "$ENV_FILE"
else
  echo "[WARN] ${ENV_FILE} not found. Cleanup will use default values."
fi

AWS_REGION="${AWS_REGION:-ap-northeast-2}"
CLUSTER_NAME="${CLUSTER_NAME:-eks-demo}"
ARGOCD_APP_NAME="${ARGOCD_APP_NAME:-vamserlike-backend}"

# Monitoring / Grafana
MONITORING_ENABLED="${MONITORING_ENABLED:-true}"
GRAFANA_RELEASE_NAME="${GRAFANA_RELEASE_NAME:-vamserlike-monitoring}"
GRAFANA_SERVICE_NAME="${GRAFANA_RELEASE_NAME}-grafana"
GRAFANA_ADMIN_SECRET_NAME="${GRAFANA_ADMIN_SECRET_NAME:-vamserlike-grafana-admin}"

# CloudWatch Log Group 삭제 여부
# 기본값 false: 로그는 증빙/확인용으로 남겨둠
# 완전 삭제하려면 env에 DELETE_CLOUDWATCH_LOG_GROUP=true 추가
DELETE_CLOUDWATCH_LOG_GROUP="${DELETE_CLOUDWATCH_LOG_GROUP:-false}"
BACKEND_LOG_GROUP_NAME="${BACKEND_LOG_GROUP_NAME:-/ec2/vamserlike-backend}"

echo "===== Vamserlike Cleanup Start ====="
echo "AWS_REGION=${AWS_REGION}"
echo "CLUSTER_NAME=${CLUSTER_NAME}"
echo "ARGOCD_APP_NAME=${ARGOCD_APP_NAME}"
echo "MONITORING_ENABLED=${MONITORING_ENABLED}"
echo "GRAFANA_RELEASE_NAME=${GRAFANA_RELEASE_NAME}"
echo "GRAFANA_SERVICE_NAME=${GRAFANA_SERVICE_NAME}"
echo "GRAFANA_ADMIN_SECRET_NAME=${GRAFANA_ADMIN_SECRET_NAME}"
echo "DELETE_CLOUDWATCH_LOG_GROUP=${DELETE_CLOUDWATCH_LOG_GROUP}"
echo "BACKEND_LOG_GROUP_NAME=${BACKEND_LOG_GROUP_NAME}"

echo "===== Set AWS Region ====="
aws configure set default.region "${AWS_REGION}"

echo "===== Check AWS Identity ====="
aws sts get-caller-identity || true

echo "===== Check EKS Cluster Exists ====="
if aws eks describe-cluster --region "${AWS_REGION}" --name "${CLUSTER_NAME}" >/dev/null 2>&1; then
  CLUSTER_EXISTS="true"
  echo "EKS cluster exists: ${CLUSTER_NAME}"
else
  CLUSTER_EXISTS="false"
  echo "[WARN] EKS cluster not found: ${CLUSTER_NAME}"
fi

if [ "$CLUSTER_EXISTS" = "true" ]; then
  echo "===== Update kubeconfig ====="
  aws eks update-kubeconfig --region "${AWS_REGION}" --name "${CLUSTER_NAME}" || true

  echo "===== Delete Argo CD Application First ====="
  kubectl delete application "${ARGOCD_APP_NAME}" -n argocd --ignore-not-found=true || true

  echo "===== Delete Backend Ingress and Namespace ====="
  kubectl delete ingress vamserlike-backend-ingress -n vamserlike --ignore-not-found=true || true

  echo "Waiting for backend ALB deletion trigger..."
  sleep 30

  kubectl delete namespace vamserlike --ignore-not-found=true || true

  echo "===== Delete Grafana / Prometheus Monitoring Stack ====="
  if [ "${MONITORING_ENABLED}" = "true" ]; then
    # Grafana Service가 internet-facing NLB를 만들기 때문에 먼저 삭제해서 LB 삭제 유도
    kubectl delete svc "${GRAFANA_SERVICE_NAME}" -n monitoring --ignore-not-found=true || true

    # Helm release 삭제
    helm uninstall "${GRAFANA_RELEASE_NAME}" -n monitoring || true

    # Grafana admin secret 삭제
    kubectl delete secret "${GRAFANA_ADMIN_SECRET_NAME}" -n monitoring --ignore-not-found=true || true

    echo "Waiting for Grafana LoadBalancer deletion trigger..."
    sleep 30

    kubectl delete namespace monitoring --ignore-not-found=true || true
  else
    echo "Monitoring cleanup skipped. MONITORING_ENABLED=${MONITORING_ENABLED}"
  fi

  echo "===== Delete Argo CD LoadBalancer and Namespace ====="
  kubectl delete svc argocd-server -n argocd --ignore-not-found=true || true

  echo "Waiting for Argo CD LoadBalancer deletion trigger..."
  sleep 30

  kubectl delete namespace argocd --ignore-not-found=true || true

  echo "===== Delete AWS for Fluent Bit CloudWatch Logging ====="
  helm uninstall aws-for-fluent-bit -n amazon-cloudwatch || true
  kubectl delete namespace amazon-cloudwatch --ignore-not-found=true || true

  echo "===== Delete AWS Load Balancer Controller ====="
  helm uninstall aws-load-balancer-controller -n kube-system || true

  echo "===== Wait for Kubernetes namespaces to terminate ====="
  for i in {1..40}; do
    REMAINING_NS="$(kubectl get ns --no-headers 2>/dev/null | awk '$1 ~ /^(vamserlike|argocd|monitoring|amazon-cloudwatch)$/ {print $1}' | wc -l || true)"

    if [ "$REMAINING_NS" -eq 0 ]; then
      echo "Application namespaces removed."
      break
    fi

    echo "Waiting for namespaces to terminate... ${i}/40"
    kubectl get ns | grep -E "vamserlike|argocd|monitoring|amazon-cloudwatch" || true
    sleep 15
  done

  echo "===== Check Remaining Load Balancers Before Cluster Delete ====="
  aws elbv2 describe-load-balancers \
    --region "${AWS_REGION}" \
    --query "LoadBalancers[?contains(LoadBalancerName, 'k8s')].[LoadBalancerName,DNSName,Scheme,Type,State.Code]" \
    --output table || true

  echo "===== Delete IAM ServiceAccounts ====="
  eksctl delete iamserviceaccount \
    --cluster="${CLUSTER_NAME}" \
    --region="${AWS_REGION}" \
    --namespace=kube-system \
    --name=aws-load-balancer-controller \
    --wait || true

  eksctl delete iamserviceaccount \
    --cluster="${CLUSTER_NAME}" \
    --region="${AWS_REGION}" \
    --namespace=amazon-cloudwatch \
    --name=aws-for-fluent-bit \
    --wait || true

  echo "===== Delete EKS Cluster ====="
  eksctl delete cluster \
    --name="${CLUSTER_NAME}" \
    --region="${AWS_REGION}" \
    --wait || true
else
  echo "Skip Kubernetes/EKS cleanup because cluster does not exist."
fi

echo "===== Confirm EKS Cluster Deleted ====="
if aws eks describe-cluster --region "${AWS_REGION}" --name "${CLUSTER_NAME}" >/dev/null 2>&1; then
  echo "[WARN] EKS cluster still exists: ${CLUSTER_NAME}"
else
  echo "EKS cluster deleted or not found: ${CLUSTER_NAME}"
fi

echo "===== Optional CloudWatch Log Group Cleanup ====="
if [ "${DELETE_CLOUDWATCH_LOG_GROUP}" = "true" ]; then
  echo "Deleting CloudWatch Log Group: ${BACKEND_LOG_GROUP_NAME}"

  aws logs delete-log-group \
    --region "${AWS_REGION}" \
    --log-group-name "${BACKEND_LOG_GROUP_NAME}" || true
else
  echo "CloudWatch Log Group kept for evidence: ${BACKEND_LOG_GROUP_NAME}"
  echo "To delete it, set DELETE_CLOUDWATCH_LOG_GROUP=true in scripts/vamserlike.env and rerun cleanup."
fi

echo "===== Remaining Load Balancers Check ====="
aws elbv2 describe-load-balancers \
  --region "${AWS_REGION}" \
  --query "LoadBalancers[*].[LoadBalancerName,DNSName,Scheme,Type,State.Code]" \
  --output table || true

echo "===== Remaining EKS Clusters Check ====="
aws eks list-clusters \
  --region "${AWS_REGION}" \
  --output table || true

echo "===== Vamserlike Cleanup Done ====="
echo ""
echo "Next step on local PowerShell:"
echo "cd C:\\Vamserlike\\terraform-base-infra\\services\\instance"
echo "terraform destroy"