variable "aws_region" {
  description = "AWS region for all resources"
  type        = string
  default     = "ap-south-1"
}

variable "project_name" {
  description = "Prefix for resource names"
  type        = string
  default     = "authengine"
}

variable "environment" {
  description = "Environment label (staging, production)"
  type        = string
  default     = "production"
}

variable "vpc_cidr" {
  description = "VPC CIDR block"
  type        = string
  default     = "10.0.0.0/16"
}

variable "ec2_instance_type" {
  description = "EC2 instance type (t4g.micro for free tier ARM)"
  type        = string
  default     = "t4g.micro"
}

variable "ec2_key_name" {
  description = "Optional EC2 SSH key pair name (leave empty to use SSM only)"
  type        = string
  default     = ""
}

variable "allowed_ssh_cidr" {
  description = "CIDR allowed to SSH to EC2 (your IP/32). Use empty string to disable SSH."
  type        = string
  default     = ""
}

variable "rds_instance_class" {
  description = "RDS instance class (db.t4g.micro for free tier)"
  type        = string
  default     = "db.t4g.micro"
}

variable "db_name" {
  description = "PostgreSQL database name"
  type        = string
  default     = "authengine"
}

variable "db_username" {
  description = "PostgreSQL master username"
  type        = string
  default     = "authengine"
}

variable "db_password" {
  description = "PostgreSQL master password (min 8 chars)"
  type        = string
  sensitive   = true
}

variable "api_subdomain" {
  description = "API subdomain label (full host: api.example.com)"
  type        = string
  default     = "api"
}

variable "idp_subdomain" {
  description = "Identity Provider subdomain (auth.example.com)"
  type        = string
  default     = "auth"
}

variable "dashboard_subdomain" {
  description = "Dashboard subdomain (app.example.com)"
  type        = string
  default     = "app"
}

variable "docs_subdomain" {
  description = "Documentation site subdomain (docs.example.com)"
  type        = string
  default     = "docs"
}

variable "root_domain" {
  description = "Root domain for documentation outputs (e.g. authengine.org)"
  type        = string
  default     = "authengine.org"
}
