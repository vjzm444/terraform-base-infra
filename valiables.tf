
variable "server_port" {
  description = "Server Port"
  type        = number
  default = 80
}

variable "security_group_name" {
  description = "The name of the security group"
  type        = string
  default = "terraform-example-instance"
}