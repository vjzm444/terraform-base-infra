#반드시 바꿔야함.
variable "key_name" {
  description = "EC2 인스턴스에 사용할 키 페어 이름"
  default     = "thdguswn0005_seoul_v2"
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
