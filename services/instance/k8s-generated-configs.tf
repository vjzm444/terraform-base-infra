# =========================================================
# Vamserlike Project - Generated EKS / Backend YAML files
# 기존 main.tf는 수정하지 않고, EKS/Backend 설정 파일만 별도 생성
# =========================================================

data "aws_caller_identity" "vamserlike_current" {}

locals {
  vamserlike_cluster_name = "eks-demo"
  vamserlike_region       = "ap-northeast-2"

  vamserlike_backend_image = "${data.aws_caller_identity.vamserlike_current.account_id}.dkr.ecr.ap-northeast-2.amazonaws.com/vamserlike-backend:latest"
}

# 실제 RDS/Azure MySQL endpoint가 정해지면 terraform apply 때 -var로 주입
# 예:
# terraform apply -var 'vamserlike_mysql_connection_string=Server=xxx;Port=3306;Database=vamserlike;User=admin;Password=xxx;SslMode=Preferred;AllowPublicKeyRetrieval=True;'
variable "vamserlike_mysql_connection_string" {
  description = "Vamserlike backend MySQL connection string. Do not commit real DB password."
  type        = string
  default     = "Server=CHANGE_ME;Port=3306;Database=vamserlike;User=CHANGE_ME;Password=CHANGE_ME;SslMode=Preferred;AllowPublicKeyRetrieval=True;"
}

# ---------------------------------------------------------
# eksctl cluster config 생성
# - 기존 Terraform이 만든 VPC/Subnet을 그대로 사용
# - Worker Node는 Private Subnet에 생성
# - OIDC 활성화
# - ALB Controller / Autoscaler / CloudWatch addon policy 포함
# ---------------------------------------------------------
resource "local_file" "eks_demo_cluster_yaml" {
  filename = "${path.module}/generated/eks-demo-cluster.yaml"

  content = <<-YAML
apiVersion: eksctl.io/v1alpha5
kind: ClusterConfig

metadata:
  name: ${local.vamserlike_cluster_name}
  region: ${local.vamserlike_region}

iam:
  withOIDC: true

vpc:
  id: "${aws_vpc.lz_vpc.id}"
  subnets:
    public:
      ap-northeast-2a:
        id: "${aws_subnet.public_subnet.id}"
      ap-northeast-2c:
        id: "${aws_subnet.public_subnet2.id}"
    private:
      ap-northeast-2a:
        id: "${aws_subnet.private_subnet.id}"
      ap-northeast-2c:
        id: "${aws_subnet.private_subnet2.id}"

managedNodeGroups:
  - name: vamserlike-node-group
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
      k8s.io/cluster-autoscaler/${local.vamserlike_cluster_name}: "owned"
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
YAML
}

# ---------------------------------------------------------
# Vamserlike Backend Kubernetes manifest 생성
# - Namespace
# - Deployment
# - Service
# - Ingress(ALB)
# - HPA
# ---------------------------------------------------------
resource "local_file" "backend_app_yaml" {
  filename = "${path.module}/generated/backend-app.yaml"

  content = <<-YAML
apiVersion: v1
kind: Namespace
metadata:
  name: vamserlike
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: vamserlike-backend
  namespace: vamserlike
  labels:
    app: vamserlike-backend
spec:
  replicas: 2
  selector:
    matchLabels:
      app: vamserlike-backend
  template:
    metadata:
      labels:
        app: vamserlike-backend
    spec:
      containers:
        - name: vamserlike-backend
          image: ${local.vamserlike_backend_image}
          imagePullPolicy: Always
          ports:
            - containerPort: 8080
          env:
            - name: ASPNETCORE_URLS
              value: "http://+:8080"
            - name: ASPNETCORE_ENVIRONMENT
              value: "Production"
            - name: MySql__ConnectionString
              value: "${var.vamserlike_mysql_connection_string}"
          readinessProbe:
            httpGet:
              path: /api/Health
              port: 8080
            initialDelaySeconds: 15
            periodSeconds: 10
            timeoutSeconds: 3
            failureThreshold: 3
          livenessProbe:
            httpGet:
              path: /api/Health
              port: 8080
            initialDelaySeconds: 30
            periodSeconds: 20
            timeoutSeconds: 3
            failureThreshold: 3
          resources:
            requests:
              cpu: "250m"
              memory: "256Mi"
            limits:
              cpu: "500m"
              memory: "512Mi"
---
apiVersion: v1
kind: Service
metadata:
  name: vamserlike-backend-service
  namespace: vamserlike
  labels:
    app: vamserlike-backend
spec:
  type: NodePort
  selector:
    app: vamserlike-backend
  ports:
    - name: http
      port: 80
      targetPort: 8080
      protocol: TCP
---
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: vamserlike-backend-ingress
  namespace: vamserlike
  labels:
    app: vamserlike-backend
  annotations:
    kubernetes.io/ingress.class: alb
    alb.ingress.kubernetes.io/scheme: internet-facing
    alb.ingress.kubernetes.io/target-type: ip
    alb.ingress.kubernetes.io/healthcheck-path: /api/Health
    alb.ingress.kubernetes.io/success-codes: "200-399"
    alb.ingress.kubernetes.io/listen-ports: '[{"HTTP":80}]'
    alb.ingress.kubernetes.io/subnets: "${aws_subnet.public_subnet.id},${aws_subnet.public_subnet2.id}"
    alb.ingress.kubernetes.io/group.name: vamserlike-backend
spec:
  ingressClassName: alb
  rules:
    - http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: vamserlike-backend-service
                port:
                  number: 80
---
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata:
  name: vamserlike-backend-hpa
  namespace: vamserlike
  labels:
    app: vamserlike-backend
spec:
  scaleTargetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: vamserlike-backend
  minReplicas: 2
  maxReplicas: 5
  metrics:
    - type: Resource
      resource:
        name: cpu
        target:
          type: Utilization
          averageUtilization: 60
YAML
}

# ---------------------------------------------------------
# 생성 파일 위치 안내
# ---------------------------------------------------------
output "vamserlike_generated_eks_cluster_yaml" {
  value       = local_file.eks_demo_cluster_yaml.filename
  description = "Generated eksctl cluster config file path"
}

output "vamserlike_generated_backend_app_yaml" {
  value       = local_file.backend_app_yaml.filename
  description = "Generated backend Kubernetes manifest file path"
}
