# ──────────────────────────────────────────────
# Outputs
# ──────────────────────────────────────────────

output "s3_bucket_name" {
  value = aws_s3_bucket.data_archive.id
}

output "ecr_repository_url" {
  value = aws_ecr_repository.export_image.repository_url
}

output "ecs_cluster_name" {
  value = aws_ecs_cluster.migration.name
}

output "ecs_task_definition_arn" {
  value = aws_ecs_task_definition.export_task.arn
}

output "fargate_security_group_id" {
  value = aws_security_group.fargate_export.id
}

output "orchestrator_lambda" {
  value = aws_lambda_function.orchestrator.function_name
}

output "verify_lambda" {
  value = aws_lambda_function.verify_backup.function_name
}

output "drop_partition_lambda" {
  value = aws_lambda_function.drop_partition.function_name
}

output "sns_topic_arn" {
  value = aws_sns_topic.migration_alerts.arn
}

output "eventbridge_schedule" {
  value = aws_scheduler_schedule.monthly_migration.name
}

output "eventbridge_state" {
  value = aws_scheduler_schedule.monthly_migration.state
}

output "manual_trigger_command" {
  value = "aws lambda invoke --function-name ${aws_lambda_function.orchestrator.function_name} --payload '{\"year\":\"2025\",\"month\":\"02\"}' --cli-binary-format raw-in-base64-out /tmp/result.json"
}
