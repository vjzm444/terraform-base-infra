variable "server_port" {
  description = "The port the web server will listen on"
  type        = number
  default     = 80
}




variable "nat_sg_name" {
  description = "NAT 인스턴스용 보안그룹 이름"
  default     = "nat-security-group"
}

variable "giyeong_sg_name" {
  description = "기영이 인스턴스용 보안그룹 이름"
  default     = "giyeong-web-sg"
}