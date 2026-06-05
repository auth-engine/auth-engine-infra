output "vpc_id" {
  description = "VPC ID"
  value       = aws_vpc.main.id
}

output "ec2_public_ip" {
  description = "Elastic IP for API server — point api.<domain> DNS here (or via Cloudflare)"
  value       = aws_eip.api.public_ip
}

output "ec2_instance_id" {
  description = "EC2 instance ID (for SSM Session Manager)"
  value       = aws_instance.api.id
}

output "rds_endpoint" {
  description = "RDS hostname (use in POSTGRES_URL on EC2)"
  value       = aws_db_instance.postgres.address
  sensitive   = true
}

output "rds_port" {
  description = "RDS port"
  value       = aws_db_instance.postgres.port
}

output "postgres_url_template" {
  description = "Asyncpg URL template — replace PASSWORD"
  value       = "postgresql+asyncpg://${var.db_username}:<PASSWORD>@${aws_db_instance.postgres.address}:${aws_db_instance.postgres.port}/${var.db_name}"
  sensitive   = true
}

output "ecr_api_repository_url" {
  description = "ECR URL for auth-engine API image"
  value       = aws_ecr_repository.api.repository_url
}

output "ecr_frontend_repository_url" {
  description = "ECR URL for auth-engine-dashboard image (optional EC2/ECS deploy)"
  value       = aws_ecr_repository.frontend.repository_url
}

output "suggested_urls" {
  description = "DNS targets for hybrid setup"
  value = {
    idp       = "https://${var.idp_subdomain}.${var.root_domain}"
    api       = "https://${var.api_subdomain}.${var.root_domain}"
    dashboard = "https://${var.dashboard_subdomain}.${var.root_domain}"
    docs      = "https://${var.docs_subdomain}.${var.root_domain}"
    api_dns   = "A records @, api, auth, app.${var.root_domain} → ${aws_eip.api.public_ip}; CNAME docs → GitHub Pages"
    ui_note   = "EC2 Docker for ${var.dashboard_subdomain}.${var.root_domain}; docs at ${var.docs_subdomain}.${var.root_domain} via GitHub Pages"
  }
}

output "hybrid_services_not_in_terraform" {
  description = "Configure these manually (free tiers)"
  value = {
    redis = "Upstash — REDIS_URL"
    mongo = "MongoDB Atlas M0 — MONGODB_URL"
  }
}
