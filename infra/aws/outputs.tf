output "frontend_url" {
  value = "https://${aws_cloudfront_distribution.frontend.domain_name}"
}

output "backend_url" {
  value = "https://${aws_cloudfront_distribution.backend.domain_name}"
}

output "backend_ecr_uri" {
  value = aws_ecr_repository.backend.repository_url
}

output "frontend_ecr_uri" {
  value = aws_ecr_repository.frontend.repository_url
}

output "cluster_name" {
  value = aws_ecs_cluster.main.name
}

output "backend_service" {
  value = aws_ecs_service.backend.name
}

output "frontend_service" {
  value = aws_ecs_service.frontend.name
}

output "aws_region" {
  value = var.aws_region
}

output "database_url" {
  value     = "postgresql://raguser:${random_password.db.result}@${aws_db_instance.pg.address}:5432/ragdb"
  sensitive = true
}

output "db_endpoint" {
  value = aws_db_instance.pg.address
}

output "name_prefix" {
  value = var.name_prefix
}

output "build_bucket" {
  value = aws_s3_bucket.build_artifacts.bucket
}

output "codebuild_backend_project" {
  value = aws_codebuild_project.backend.name
}

output "codebuild_frontend_project" {
  value = aws_codebuild_project.frontend.name
}
