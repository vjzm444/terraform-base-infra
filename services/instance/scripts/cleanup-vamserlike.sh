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
VPC_CIDR="${VPC_CIDR:-10.40.0.0/16}"

# Backend / ECR
ECR_REPOSITORY="${ECR_REPOSITORY:-vamserlike-backend}"
BACKEND_IMAGE_TAG="${BACKEND_IMAGE_TAG:-latest}"
BACKEND_SOURCE_DIR="${BACKEND_SOURCE_DIR:-${HOME}/Vamserlike-backend}"

# cleanup 기본 정책
# ECR repository 자체는 Terraform destroy가 삭제함.
# cleanup에서는 기본적으로 ECR 이미지는 보존.
DELETE_ECR_IMAGES="${DELETE_ECR_IMAGES:-false}"
CLEAN_LOCAL_DOCKER_IMAGES="${CLEAN_LOCAL_DOCKER_IMAGES:-true}"
CLEAN_BACKEND_SOURCE_DIR="${CLEAN_BACKEND_SOURCE_DIR:-false}"

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

VPC_ID="${VPC_ID:-}"
ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text 2>/dev/null || true)"

if [ -n "${ACCOUNT_ID}" ]; then
  ECR_REGISTRY="${ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com"
  ECR_REPOSITORY_URI="${ECR_REGISTRY}/${ECR_REPOSITORY}"
  BACKEND_FULL_IMAGE="${ECR_REPOSITORY_URI}:${BACKEND_IMAGE_TAG}"
else
  ECR_REGISTRY=""
  ECR_REPOSITORY_URI=""
  BACKEND_FULL_IMAGE=""
fi

echo "===== Vamserlike Cleanup Start ====="
echo "AWS_REGION=${AWS_REGION}"
echo "CLUSTER_NAME=${CLUSTER_NAME}"
echo "ARGOCD_APP_NAME=${ARGOCD_APP_NAME}"
echo "VPC_CIDR=${VPC_CIDR}"
echo "ECR_REPOSITORY=${ECR_REPOSITORY}"
echo "BACKEND_IMAGE_TAG=${BACKEND_IMAGE_TAG}"
echo "BACKEND_SOURCE_DIR=${BACKEND_SOURCE_DIR}"
echo "DELETE_ECR_IMAGES=${DELETE_ECR_IMAGES}"
echo "CLEAN_LOCAL_DOCKER_IMAGES=${CLEAN_LOCAL_DOCKER_IMAGES}"
echo "CLEAN_BACKEND_SOURCE_DIR=${CLEAN_BACKEND_SOURCE_DIR}"
echo "MONITORING_ENABLED=${MONITORING_ENABLED}"
echo "GRAFANA_RELEASE_NAME=${GRAFANA_RELEASE_NAME}"
echo "GRAFANA_SERVICE_NAME=${GRAFANA_SERVICE_NAME}"
echo "GRAFANA_ADMIN_SECRET_NAME=${GRAFANA_ADMIN_SECRET_NAME}"
echo "DELETE_CLOUDWATCH_LOG_GROUP=${DELETE_CLOUDWATCH_LOG_GROUP}"
echo "BACKEND_LOG_GROUP_NAME=${BACKEND_LOG_GROUP_NAME}"
echo "ACCOUNT_ID=${ACCOUNT_ID}"
echo "BACKEND_FULL_IMAGE=${BACKEND_FULL_IMAGE}"

echo "===== Set AWS Region ====="
aws configure set default.region "${AWS_REGION}" || true

echo "===== Check AWS Identity ====="
aws sts get-caller-identity || true

echo "===== Check EKS Cluster Exists ====="
if aws eks describe-cluster --region "${AWS_REGION}" --name "${CLUSTER_NAME}" >/dev/null 2>&1; then
  CLUSTER_EXISTS="true"
  echo "EKS cluster exists: ${CLUSTER_NAME}"

  VPC_ID="$(aws eks describe-cluster \
    --region "${AWS_REGION}" \
    --name "${CLUSTER_NAME}" \
    --query "cluster.resourcesVpcConfig.vpcId" \
    --output text 2>/dev/null || true)"
else
  CLUSTER_EXISTS="false"
  echo "[WARN] EKS cluster not found: ${CLUSTER_NAME}"
fi

if [ -z "${VPC_ID}" ] || [ "${VPC_ID}" = "None" ]; then
  VPC_ID="$(aws ec2 describe-vpcs \
    --region "${AWS_REGION}" \
    --filters "Name=cidr-block,Values=${VPC_CIDR}" \
    --query "Vpcs[0].VpcId" \
    --output text 2>/dev/null || true)"
fi

if [ -z "${VPC_ID}" ] || [ "${VPC_ID}" = "None" ]; then
  echo "[WARN] VPC not found by EKS cluster or VPC_CIDR. VPC cleanup checks will be skipped."
  VPC_ID=""
else
  echo "VPC_ID=${VPC_ID}"
fi

wait_for_load_balancers() {
  if [ -z "${VPC_ID}" ]; then
    echo "VPC_ID is empty. Skip LoadBalancer wait."
    return 0
  fi

  echo "===== Wait for LoadBalancers in VPC to be deleted ====="

  for i in {1..40}; do
    REMAINING_LBS="$(aws elbv2 describe-load-balancers \
      --region "${AWS_REGION}" \
      --query "LoadBalancers[?VpcId=='${VPC_ID}'].LoadBalancerArn" \
      --output text 2>/dev/null || true)"

    if [ -z "${REMAINING_LBS}" ] || [ "${REMAINING_LBS}" = "None" ]; then
      echo "No LoadBalancers remain in VPC."
      return 0
    fi

    echo "Waiting for LoadBalancers to disappear... ${i}/40"

    aws elbv2 describe-load-balancers \
      --region "${AWS_REGION}" \
      --query "LoadBalancers[?VpcId=='${VPC_ID}'].[LoadBalancerName,DNSName,Scheme,Type,State.Code]" \
      --output table || true

    sleep 15
  done

  echo "[WARN] Some LoadBalancers may still remain in VPC."
}

cleanup_leftover_k8s_security_groups() {
  if [ -z "${VPC_ID}" ]; then
    echo "VPC_ID is empty. Skip leftover k8s security group cleanup."
    return 0
  fi

  echo "===== Cleanup Leftover Kubernetes LoadBalancer Security Groups ====="

  K8S_SECURITY_GROUPS="$(aws ec2 describe-security-groups \
    --region "${AWS_REGION}" \
    --filters "Name=vpc-id,Values=${VPC_ID}" \
    --query "SecurityGroups[?GroupName!='default' && starts_with(GroupName, 'k8s-')].GroupId" \
    --output text 2>/dev/null || true)"

  if [ -z "${K8S_SECURITY_GROUPS}" ] || [ "${K8S_SECURITY_GROUPS}" = "None" ]; then
    echo "No leftover k8s security groups found."
  else
    for SG_ID in ${K8S_SECURITY_GROUPS}; do
      echo "Cleaning security group: ${SG_ID}"

      INGRESS_RULE_IDS="$(aws ec2 describe-security-group-rules \
        --region "${AWS_REGION}" \
        --filters "Name=group-id,Values=${SG_ID}" \
        --query 'SecurityGroupRules[?IsEgress==`false`].SecurityGroupRuleId' \
        --output text 2>/dev/null || true)"

      if [ -n "${INGRESS_RULE_IDS}" ] && [ "${INGRESS_RULE_IDS}" != "None" ]; then
        for RULE_ID in ${INGRESS_RULE_IDS}; do
          echo "Revoke ingress rule: ${RULE_ID}"
          aws ec2 revoke-security-group-ingress \
            --region "${AWS_REGION}" \
            --group-id "${SG_ID}" \
            --security-group-rule-ids "${RULE_ID}" || true
        done
      fi

      EGRESS_RULE_IDS="$(aws ec2 describe-security-group-rules \
        --region "${AWS_REGION}" \
        --filters "Name=group-id,Values=${SG_ID}" \
        --query 'SecurityGroupRules[?IsEgress==`true`].SecurityGroupRuleId' \
        --output text 2>/dev/null || true)"

      if [ -n "${EGRESS_RULE_IDS}" ] && [ "${EGRESS_RULE_IDS}" != "None" ]; then
        for RULE_ID in ${EGRESS_RULE_IDS}; do
          echo "Revoke egress rule: ${RULE_ID}"
          aws ec2 revoke-security-group-egress \
            --region "${AWS_REGION}" \
            --group-id "${SG_ID}" \
            --security-group-rule-ids "${RULE_ID}" || true
        done
      fi

      echo "Delete security group: ${SG_ID}"

      for attempt in {1..10}; do
        if aws ec2 delete-security-group \
          --region "${AWS_REGION}" \
          --group-id "${SG_ID}"; then
          echo "Deleted security group: ${SG_ID}"
          break
        fi

        echo "Retry delete security group ${SG_ID}... ${attempt}/10"
        sleep 10
      done
    done
  fi

  echo "===== Remaining Security Groups In VPC ====="
  aws ec2 describe-security-groups \
    --region "${AWS_REGION}" \
    --filters "Name=vpc-id,Values=${VPC_ID}" \
    --query "SecurityGroups[*].[GroupId,GroupName,Description]" \
    --output table || true
}

cleanup_backend_local_artifacts() {
  echo "===== Cleanup Local Backend Build Artifacts ====="

  if [ "${CLEAN_LOCAL_DOCKER_IMAGES}" = "true" ]; then
    if command -v docker >/dev/null 2>&1; then
      echo "Remove local Docker images if exist."

      if [ -n "${BACKEND_FULL_IMAGE}" ]; then
        sudo docker rmi "${BACKEND_FULL_IMAGE}" || true
      fi

      sudo docker rmi "${ECR_REPOSITORY}:${BACKEND_IMAGE_TAG}" || true

      echo "Docker image prune."
      sudo docker image prune -f || true
    else
      echo "Docker not found. Skip local Docker image cleanup."
    fi
  else
    echo "CLEAN_LOCAL_DOCKER_IMAGES=false. Skip local Docker image cleanup."
  fi

  if [ "${CLEAN_BACKEND_SOURCE_DIR}" = "true" ]; then
    echo "Remove backend source dir: ${BACKEND_SOURCE_DIR}"
    rm -rf "${BACKEND_SOURCE_DIR}" || true
  else
    echo "CLEAN_BACKEND_SOURCE_DIR=false. Keep backend source dir: ${BACKEND_SOURCE_DIR}"
  fi
}

cleanup_ecr_images_optional() {
  echo "===== Optional ECR Image Cleanup ====="

  if [ "${DELETE_ECR_IMAGES}" != "true" ]; then
    echo "DELETE_ECR_IMAGES=false. Keep ECR images."
    echo "Terraform destroy will delete ECR repository because force_delete=true in vamserlike-ecr.tf."
    return 0
  fi

  if [ -z "${ACCOUNT_ID}" ]; then
    echo "[WARN] ACCOUNT_ID is empty. Skip ECR image cleanup."
    return 0
  fi

  if ! aws ecr describe-repositories \
    --region "${AWS_REGION}" \
    --repository-names "${ECR_REPOSITORY}" >/dev/null 2>&1; then
    echo "ECR repository not found: ${ECR_REPOSITORY}"
    return 0
  fi

  IMAGE_DIGESTS="$(aws ecr list-images \
    --region "${AWS_REGION}" \
    --repository-name "${ECR_REPOSITORY}" \
    --query 'imageIds[*].imageDigest' \
    --output text 2>/dev/null || true)"

  if [ -z "${IMAGE_DIGESTS}" ] || [ "${IMAGE_DIGESTS}" = "None" ]; then
    echo "No ECR images to delete."
    return 0
  fi

  echo "Delete all images in ECR repository: ${ECR_REPOSITORY}"

  for DIGEST in ${IMAGE_DIGESTS}; do
    aws ecr batch-delete-image \
      --region "${AWS_REGION}" \
      --repository-name "${ECR_REPOSITORY}" \
      --image-ids imageDigest="${DIGEST}" || true
  done
}

if [ "$CLUSTER_EXISTS" = "true" ]; then
  echo "===== Update kubeconfig ====="
  aws eks update-kubeconfig --region "${AWS_REGION}" --name "${CLUSTER_NAME}" || true

  echo "===== Delete Argo CD Application First ====="
  kubectl patch application "${ARGOCD_APP_NAME}" \
    -n argocd \
    --type merge \
    -p '{"metadata":{"finalizers":[]}}' 2>/dev/null || true

  kubectl delete application "${ARGOCD_APP_NAME}" -n argocd --ignore-not-found=true || true

  echo "===== Delete Backend Ingress and Namespace ====="
  kubectl delete ingress vamserlike-backend-ingress -n vamserlike --ignore-not-found=true || true

  echo "Waiting for backend ALB deletion trigger..."
  sleep 30

  kubectl delete namespace vamserlike --ignore-not-found=true || true

  echo "===== Delete Grafana / Prometheus Monitoring Stack ====="
  if [ "${MONITORING_ENABLED}" = "true" ]; then
    kubectl delete svc "${GRAFANA_SERVICE_NAME}" -n monitoring --ignore-not-found=true || true

    helm uninstall "${GRAFANA_RELEASE_NAME}" -n monitoring || true

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

  echo "===== Wait for Kubernetes namespaces to terminate ====="
  for i in {1..40}; do
    REMAINING_NS="$(kubectl get ns --no-headers 2>/dev/null | awk '$1 ~ /^(vamserlike|argocd|monitoring|amazon-cloudwatch)$/ {print $1}' | wc -l | tr -d ' ' || true)"

    if [ "${REMAINING_NS}" -eq 0 ]; then
      echo "Application namespaces removed."
      break
    fi

    echo "Waiting for namespaces to terminate... ${i}/40"
    kubectl get ns | grep -E "vamserlike|argocd|monitoring|amazon-cloudwatch" || true
    sleep 15
  done

  wait_for_load_balancers

  echo "===== Delete AWS Load Balancer Controller ====="
  helm uninstall aws-load-balancer-controller -n kube-system || true

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

echo "===== Cleanup Leftover k8s Security Groups After EKS Delete ====="
cleanup_leftover_k8s_security_groups

cleanup_backend_local_artifacts
cleanup_ecr_images_optional

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
if [ -n "${VPC_ID}" ]; then
  aws elbv2 describe-load-balancers \
    --region "${AWS_REGION}" \
    --query "LoadBalancers[?VpcId=='${VPC_ID}'].[LoadBalancerName,DNSName,Scheme,Type,State.Code]" \
    --output table || true
else
  aws elbv2 describe-load-balancers \
    --region "${AWS_REGION}" \
    --query "LoadBalancers[*].[LoadBalancerName,DNSName,Scheme,Type,State.Code]" \
    --output table || true
fi

echo "===== Remaining Network Interfaces Check ====="
if [ -n "${VPC_ID}" ]; then
  aws ec2 describe-network-interfaces \
    --region "${AWS_REGION}" \
    --filters "Name=vpc-id,Values=${VPC_ID}" \
    --query "NetworkInterfaces[*].[NetworkInterfaceId,Status,InterfaceType,Description,RequesterManaged,SubnetId,Groups[0].GroupId]" \
    --output table || true
fi

echo "===== Remaining Security Groups Check ====="
if [ -n "${VPC_ID}" ]; then
  aws ec2 describe-security-groups \
    --region "${AWS_REGION}" \
    --filters "Name=vpc-id,Values=${VPC_ID}" \
    --query "SecurityGroups[*].[GroupId,GroupName,Description]" \
    --output table || true
fi

echo "===== Remaining ECR Repository Check ====="
aws ecr describe-repositories \
  --region "${AWS_REGION}" \
  --repository-names "${ECR_REPOSITORY}" \
  --query "repositories[*].[repositoryName,repositoryUri,createdAt]" \
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