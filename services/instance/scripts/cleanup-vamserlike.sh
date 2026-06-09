#!/usr/bin/env bash
set -euo pipefail

AWS_REGION="${AWS_REGION:-ap-northeast-2}"
CLUSTER_NAME="${CLUSTER_NAME:-eks-demo}"

echo "===== Vamserlike Cleanup Start ====="

echo "Delete Argo CD Application and backend namespace..."
kubectl delete application vamserlike-backend -n argocd --ignore-not-found || true
kubectl delete namespace vamserlike --ignore-not-found || true

echo "Delete Argo CD namespace..."
kubectl delete namespace argocd --ignore-not-found || true

echo "Waiting briefly for LoadBalancers to be removed..."
sleep 60

echo "Current ALB list:"
aws elbv2 describe-load-balancers \
  --region "${AWS_REGION}" \
  --query "LoadBalancers[*].[LoadBalancerName,DNSName,State.Code]" \
  --output table || true

echo "Current Classic ELB list:"
aws elb describe-load-balancers \
  --region "${AWS_REGION}" \
  --query "LoadBalancerDescriptions[*].[LoadBalancerName,DNSName]" \
  --output table || true

echo "Delete EKS cluster..."
eksctl delete cluster \
  --name "${CLUSTER_NAME}" \
  --region "${AWS_REGION}" \
  --wait

echo "===== EKS Cleanup Done ====="
echo "Now run terraform destroy from the same local folder/state used for terraform apply:"
echo "C:\\Vamserlike\\terraform-base-infra\\services\\instance"
