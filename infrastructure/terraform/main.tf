terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
  # Uncomment to store state in S3 (recommended for teams)
  # backend "s3" {
  #   bucket = "your-terraform-state-bucket"
  #   key    = "trading-strategy/terraform.tfstate"
  #   region = "us-east-1"
  # }
}

provider "aws" {
  region = var.aws_region
}

# ──────────────────────────────────────────────────────────────
# ECR — Docker image registry
# ──────────────────────────────────────────────────────────────
resource "aws_ecr_repository" "backend" {
  name                 = "trading-strategy-backend"
  image_tag_mutability = "MUTABLE"
  image_scanning_configuration { scan_on_push = true }
  tags = { Project = "trading-strategy" }
}

resource "aws_ecr_lifecycle_policy" "backend" {
  repository = aws_ecr_repository.backend.name
  policy = jsonencode({
    rules = [{
      rulePriority = 1
      description  = "Keep last 5 images"
      selection    = { tagStatus = "any", countType = "imageCountMoreThan", countNumber = 5 }
      action       = { type = "expire" }
    }]
  })
}

# ──────────────────────────────────────────────────────────────
# Networking — use default VPC for simplicity
# ──────────────────────────────────────────────────────────────
data "aws_vpc" "default" { default = true }

data "aws_ami" "amazon_linux" {
  most_recent = true
  owners      = ["amazon"]
  filter {
    name   = "name"
    values = ["al2023-ami-*-x86_64"]
  }
}

resource "aws_security_group" "backend" {
  name        = "trading-strategy-backend"
  description = "Backend API traffic"
  vpc_id      = data.aws_vpc.default.id

  ingress {
    description = "API"
    from_port   = 8000
    to_port     = 8000
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }
  ingress {
    description = "SSH (restrict to your IP in production)"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = var.ssh_allowed_cidr
  }
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
  tags = { Name = "trading-strategy-backend" }
}

# ──────────────────────────────────────────────────────────────
# IAM — EC2 can pull from ECR without explicit credentials
# ──────────────────────────────────────────────────────────────
resource "aws_iam_role" "backend" {
  name = "trading-strategy-backend-ec2"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{ Effect = "Allow", Principal = { Service = "ec2.amazonaws.com" }, Action = "sts:AssumeRole" }]
  })
}

resource "aws_iam_role_policy_attachment" "ecr_read" {
  role       = aws_iam_role.backend.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly"
}

resource "aws_iam_instance_profile" "backend" {
  name = "trading-strategy-backend-ec2"
  role = aws_iam_role.backend.name
}

# ──────────────────────────────────────────────────────────────
# EC2 — t3.small, runs backend Docker container
# ──────────────────────────────────────────────────────────────
resource "aws_key_pair" "deployer" {
  key_name   = "trading-strategy-deployer"
  public_key = var.ssh_public_key
}

resource "aws_instance" "backend" {
  ami                    = data.aws_ami.amazon_linux.id
  instance_type          = "t3.small"
  key_name               = aws_key_pair.deployer.key_name
  vpc_security_group_ids = [aws_security_group.backend.id]
  iam_instance_profile   = aws_iam_instance_profile.backend.name

  user_data = <<-EOF
    #!/bin/bash
    set -e
    yum update -y
    yum install -y docker
    systemctl start docker
    systemctl enable docker
    usermod -aG docker ec2-user

    # AWS CLI v2
    curl -s https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip -o /tmp/awscliv2.zip
    unzip -q /tmp/awscliv2.zip -d /tmp
    /tmp/aws/install
    rm -rf /tmp/aws /tmp/awscliv2.zip

    # Wait for EBS and mount it
    while [ ! -b /dev/xvdf ]; do sleep 2; done
    if ! blkid /dev/xvdf; then mkfs -t ext4 /dev/xvdf; fi
    mkdir -p /mnt/strategy-data
    mount /dev/xvdf /mnt/strategy-data || true
    echo "/dev/xvdf /mnt/strategy-data ext4 defaults,nofail 0 2" >> /etc/fstab
    mkdir -p /mnt/strategy-data/trading-strategies
  EOF

  tags = { Name = "trading-strategy-backend", Project = "trading-strategy" }
}

# Elastic IP — stable address even after stop/start
resource "aws_eip" "backend" {
  instance = aws_instance.backend.id
  domain   = "vpc"
  tags     = { Name = "trading-strategy-backend" }
}

# EBS — 8 GB persistent volume for strategy data
resource "aws_ebs_volume" "strategy_data" {
  availability_zone = aws_instance.backend.availability_zone
  size              = 8
  type              = "gp3"
  tags              = { Name = "trading-strategy-data" }
}

resource "aws_volume_attachment" "strategy_data" {
  device_name  = "/dev/xvdf"
  volume_id    = aws_ebs_volume.strategy_data.id
  instance_id  = aws_instance.backend.id
  force_detach = true
}

# ──────────────────────────────────────────────────────────────
# S3 — frontend static assets (private, CloudFront only)
# ──────────────────────────────────────────────────────────────
resource "aws_s3_bucket" "frontend" {
  bucket = var.frontend_bucket_name
  tags   = { Name = "trading-strategy-ui", Project = "trading-strategy" }
}

resource "aws_s3_bucket_public_access_block" "frontend" {
  bucket                  = aws_s3_bucket.frontend.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_cloudfront_origin_access_control" "frontend" {
  name                              = "trading-strategy-ui-oac"
  origin_access_control_origin_type = "s3"
  signing_behavior                  = "always"
  signing_protocol                  = "sigv4"
}

resource "aws_s3_bucket_policy" "frontend" {
  bucket = aws_s3_bucket.frontend.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "cloudfront.amazonaws.com" }
      Action    = "s3:GetObject"
      Resource  = "${aws_s3_bucket.frontend.arn}/*"
      Condition = { StringEquals = { "AWS:SourceArn" = aws_cloudfront_distribution.frontend.arn } }
    }]
  })
  depends_on = [aws_cloudfront_distribution.frontend]
}

# ──────────────────────────────────────────────────────────────
# CloudFront — CDN for frontend
# ──────────────────────────────────────────────────────────────
resource "aws_cloudfront_distribution" "frontend" {
  enabled             = true
  default_root_object = "index.html"
  price_class         = "PriceClass_100" # US + Europe (cheapest)
  comment             = "trading-strategy-ui"

  origin {
    domain_name              = aws_s3_bucket.frontend.bucket_regional_domain_name
    origin_id                = "s3-trading-strategy-ui"
    origin_access_control_id = aws_cloudfront_origin_access_control.frontend.id
  }

  default_cache_behavior {
    allowed_methods        = ["GET", "HEAD"]
    cached_methods         = ["GET", "HEAD"]
    target_origin_id       = "s3-trading-strategy-ui"
    viewer_protocol_policy = "redirect-to-https"
    compress               = true
    forwarded_values {
      query_string = false
      cookies { forward = "none" }
    }
    min_ttl     = 0
    default_ttl = 3600
    max_ttl     = 86400
  }

  # SPA routing: serve index.html for any 403/404
  custom_error_response {
    error_code         = 403
    response_code      = 200
    response_page_path = "/index.html"
  }
  custom_error_response {
    error_code         = 404
    response_code      = 200
    response_page_path = "/index.html"
  }

  restrictions { geo_restriction { restriction_type = "none" } }
  viewer_certificate { cloudfront_default_certificate = true }

  tags = { Name = "trading-strategy-ui", Project = "trading-strategy" }
}
