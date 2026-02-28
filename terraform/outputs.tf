# ──────────────────────────────────────────────
# Outputs — printed after terraform apply
# ──────────────────────────────────────────────

# ─── EventBridge ───

output "sfn_schedule_name" {
  description = "EventBridge schedule for Step Functions pipeline"
  value       = aws_scheduler_schedule.monthly_migration.name
}

output "lambda_chain_schedule_name" {
  description = "EventBridge schedule for Lambda chain pipeline"
  value       = aws_scheduler_schedule.monthly_migration_lambda_chain.name
}

output "scheduler_dlq_url" {
  value = aws_sqs_queue.scheduler_dlq.url
}

# ─── S3 ───

output "s3_bucket_name" {
  value = aws_s3_bucket.data_archive.id
}

output "s3_backup_path" {
  value = "s3://${aws_s3_bucket.data_archive.id}/backups/"
}

# ─── ECS ───

output "ecr_repository_url" {
  value = aws_ecr_repository.export_image.repository_url
}

output "ecs_cluster_name" {
  value = aws_ecs_cluster.migration.name
}

output "ecs_task_definition_arn" {
  value = aws_ecs_task_definition.export_task.arn
}

# ─── Step Functions Pipeline ───

output "step_functions_arn" {
  value = aws_sfn_state_machine.migration_pipeline.arn
}

output "sns_topic_arn" {
  value = aws_sns_topic.migration_alerts.arn
}

# ─── Lambda Chain Pipeline ───

output "orchestrator_lambda_name" {
  value = aws_lambda_function.orchestrator.function_name
}

output "verify_lambda_name" {
  value = aws_lambda_function.verify_backup.function_name
}

output "drop_partition_lambda_name" {
  value = aws_lambda_function.drop_partition.function_name
}

# ─── Quick Start Commands ───

output "backfill_via_step_functions" {
  description = "Trigger backfill using Step Functions"
  value       = "aws stepfunctions start-execution --state-machine-arn ${aws_sfn_state_machine.migration_pipeline.arn} --input '{\"year\":\"2025\",\"month\":\"02\"}'"
}

output "backfill_via_lambda_chain" {
  description = "Trigger backfill using Lambda chain"
  value       = "aws lambda invoke --function-name ${aws_lambda_function.orchestrator.function_name} --payload '{\"year\":\"2025\",\"month\":\"02\"}' --region ${var.aws_region} /tmp/output.json"
}
