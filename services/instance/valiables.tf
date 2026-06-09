#반드시 바꿔야함.키값
variable "key_name" {
  description = "EC2 인스턴스에 사용할 키 페어 이름"
  default     = "thdguswn0005_seoul_v2"
}

#반드시 바꿔야함. 파이프라인 -> 연결 arn변경(vamserlike-unity에 초대받은 Github계정이 연결되어있어야함.)
variable "github_connection_arn" {
  description = "AWS CodeStar Connection ARN"
  type        = string
  default     = "arn:aws:codeconnections:ap-northeast-2:899255965373:connection/a9ad0cc9-d9bc-4eed-a91c-f8c9152cca92"
}

#반드시 바꿔야함.고유값으로(버킷만들때 사용)
variable "bucket_prefix" {
  description = "버킷 이름 앞에 붙을 접두사 (예: vjzm44)"
  type        = string
  default     = "vjzm44" # 기본값 설정
}

variable "server_port" {
  description = "The port the web server will listen on"
  type        = number
  default     = 80
}

variable "nat_sg_name" {
  description = "NAT 인스턴스용 보안그룹 이름"
  default     = "nat-security-group"
}

variable "k8s_sg_name" {
  description = "k8s 인스턴스용 보안그룹 이름"
  default     = "k8s-security-group"
}

variable "backend_sg_name" {
  description = "뱀서라이크 백엔드용 private보안그룹(테스트용)"
  default     = "backend_sg_name"
}
