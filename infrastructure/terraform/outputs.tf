output "backend_ip" {
  description = "Elastic IP of the backend EC2 instance"
  value       = aws_eip.backend.public_ip
}

output "backend_url" {
  description = "Backend API base URL"
  value       = "http://${aws_eip.backend.public_ip}:8000"
}

output "ecr_repository_url" {
  description = "ECR repository URL — use this as ECR_REGISTRY in GitHub Actions secrets"
  value       = aws_ecr_repository.backend.repository_url
}

output "cloudfront_domain" {
  description = "CloudFront URL for the frontend (your public app link)"
  value       = "https://${aws_cloudfront_distribution.frontend.domain_name}"
}

output "cloudfront_distribution_id" {
  description = "CloudFront distribution ID — needed for cache invalidation in CI"
  value       = aws_cloudfront_distribution.frontend.id
}

output "s3_bucket_name" {
  description = "S3 bucket name — set as S3_BUCKET in GitHub Actions secrets"
  value       = aws_s3_bucket.frontend.bucket
}
