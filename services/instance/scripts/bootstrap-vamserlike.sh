#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${SCRIPT_DIR}/vamserlike.env"

if [ ! -f "$ENV_FILE" ]; then
  echo "[ERROR] ${ENV_FILE} not found."
  echo "Copy scripts/vamserlike.env.example to scripts/vamserlike.env and edit values."
  exit 1
fi

source "$ENV_FILE"

AWS_REGION="${AWS_REGION:-ap-northeast-2}"
CLUSTER_NAME="${CLUSTER_NAME:-eks-demo}"
NODEGROUP_NAME="${NODEGROUP_NAME:-vamserlike-node-group}"
VPC_CIDR="${VPC_CIDR:-10.40.0.0/16}"
ECR_REPOSITORY="${ECR_REPOSITORY:-vamserlike-backend}"

echo "===== Vamserlike Bootstrap Start ====="
echo "AWS_REGION=${AWS_REGION}"
echo "CLUSTER_NAME=${CLUSTER_NAME}"
echo "NODEGROUP_NAME=${NODEGROUP_NAME}"
echo "VPC_CIDR=${VPC_CIDR}"

ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)"
echo "ACCOUNT_ID=${ACCOUNT_ID}"

echo "===== Check IAM Role ====="
aws sts get-caller-identity

echo "===== Set AWS Region ====="
aws configure set default.region "${AWS_REGION}"

echo "===== Check Required Commands ====="
for cmd in aws eksctl kubectl helm jq curl; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "[ERROR] required command not found: $cmd"
    exit 1
  fi
done

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

kubectl rollout status deployment/aws-load-balancer-controller -n kube-system

echo "===== Create DB Secret ====="
kubectl create namespace vamserlike --dry-run=client -o yaml | kubectl apply -f -

kubectl create secret generic vamserlike-db-secret \
  -n vamserlike \
  --from-literal=connectionString="${MYSQL_CONNECTION_STRING}" \
  --dry-run=client -o yaml | kubectl apply -f -

echo "===== Install Argo CD ====="
kubectl create namespace argocd --dry-run=client -o yaml | kubectl apply -f -

kubectl apply -n argocd \
  -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml

kubectl rollout status deployment/argocd-server -n argocd --timeout=300s || true

kubectl patch svc argocd-server -n argocd \
  -p '{"spec": {"type": "LoadBalancer"}}'

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

echo "===== Output ====="
ARGOCD_LB="$(kubectl get svc argocd-server -n argocd -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || true)"
ARGOCD_PW="$(kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' 2>/dev/null | base64 -d || true)"

echo "Argo CD URL: https://${ARGOCD_LB}"
echo "Argo CD ID : admin"
echo "Argo CD PW : ${ARGOCD_PW}"

echo "Wait a few minutes, then check:"
echo "kubectl get applications -n argocd"
echo "kubectl get pods -n vamserlike"
echo "kubectl get ingress -n vamserlike"

echo "===== Vamserlike Bootstrap Done ====="
