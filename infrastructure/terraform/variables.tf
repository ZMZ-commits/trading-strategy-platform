variable "aws_region" {
  description = "AWS region to deploy into"
  type        = string
  default     = "us-east-1"
}

variable "frontend_bucket_name" {
  description = "Globally unique S3 bucket name for the frontend build artifacts"
  type        = string
  # Example: "trading-strategy-ui-yourname-2026"
}

variable "ssh_public_key" {
  description = "SSH public key content for EC2 access (paste output of: cat ~/.ssh/id_rsa.pub)"
  type        = string
}

variable "ssh_allowed_cidr" {
  description = "CIDR blocks allowed to SSH into the EC2 instance. Restrict to your IP."
  type        = list(string)
  default     = ["0.0.0.0/0"] # Change to ["YOUR.IP.ADDRESS/32"] before production
}
