output "elastic_ip" {
  description = "Point the API and MQTT DNS records (A) here (U-6)."
  value       = aws_eip.host.public_ip
}

output "dns_records_to_create" {
  description = "Records the domain owner must create. Placeholders until U-6 is decided."
  value = {
    (coalesce(var.api_public_host, "<api host - U-6>"))   = "A ${aws_eip.host.public_ip}"
    (coalesce(var.mqtt_public_host, "<mqtt host - U-6>")) = "A ${aws_eip.host.public_ip}"
  }
}

output "instance_id" {
  value = aws_instance.host.id
}

output "ecr_repository_url" {
  value = aws_ecr_repository.backend.repository_url
}

output "backup_bucket" {
  value = aws_s3_bucket.this["backups"].id
}

output "artifacts_bucket" {
  value = aws_s3_bucket.this["artifacts"].id
}

output "runtime_secret_name" {
  description = "Secrets Manager secret (values are write-only; never in state)."
  value       = aws_secretsmanager_secret.runtime.name
}

output "kms_key_arn" {
  value = aws_kms_key.main.arn
}

output "log_group" {
  value = aws_cloudwatch_log_group.app.name
}

output "alarm_topic_arn" {
  value = aws_sns_topic.alarms.arn
}
