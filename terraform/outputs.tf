output "alb_dns_name" {
  value = aws_lb.app.dns_name
}

output "ecr_repository_url" {
  value = aws_ecr_repository.app.repository_url
}

output "deploy_role_arn" {
  description = "Set as AWS_DEPLOY_ROLE_ARN in the matching GitHub Environment"
  value       = aws_iam_role.deploy.arn
}

output "db_secret_arn" {
  description = "ARN only. The password lives in Secrets Manager, never in state"
  value       = aws_db_instance.db.master_user_secret[0].secret_arn
}
