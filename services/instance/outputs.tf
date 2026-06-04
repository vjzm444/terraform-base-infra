# 1. VPC ID
output "vpc_id" {
  value       = aws_vpc.lz_vpc.id
  description = "VPC ID"
}

# 2. 서브넷 ID 목록 (쿠버네티스 클러스터 생성 시 바로 복붙 가능)
output "public_subnet_ids" {
  value       = [aws_subnet.public_subnet.id, aws_subnet.public_subnet2.id]
  description = "퍼블릭 서브넷(a, c) ID 목록"
}

output "private_subnet_ids" {
  value       = [aws_subnet.private_subnet.id, aws_subnet.private_subnet2.id]
  description = "프라이빗 서브넷(a, c) ID 목록"
}

# 3. 주요 인스턴스 IP (관리용)
output "k8s_manager_public_ip" {
  value       = aws_instance.k8s_manager_instance.public_ip
  description = "K8s 관리자 인스턴스 퍼블릭 IP"
}

output "nat_instance_public_ip" {
  value       = aws_instance.nat_bastion_instance.public_ip
  description = "NAT 인스턴스 퍼블릭 IP"
}