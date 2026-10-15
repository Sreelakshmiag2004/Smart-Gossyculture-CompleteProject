# Logs, metrics and alarms (CloudWatch). Application metrics come from the services' /metrics
# endpoints, scraped on the host by the CloudWatch agent (deploy/prod/cloudwatch) into namespace
# Gossy/App; host metrics into Gossy/Host; the backup job publishes Gossy/BackupSucceeded.

resource "aws_cloudwatch_log_group" "app" {
  name              = "/gossy/${var.environment}/app"
  retention_in_days = var.log_retention_days
  kms_key_id        = aws_kms_key.main.arn
}

resource "aws_cloudwatch_log_group" "prometheus" {
  name              = "/gossy/${var.environment}/app-prometheus"
  retention_in_days = 7
  kms_key_id        = aws_kms_key.main.arn
}

resource "aws_sns_topic" "alarms" {
  name              = "gossy-${var.environment}-alarms"
  kms_master_key_id = aws_kms_key.main.arn
}

resource "aws_sns_topic_subscription" "email" {
  count     = var.alarm_email == null ? 0 : 1
  topic_arn = aws_sns_topic.alarms.arn
  protocol  = "email"
  endpoint  = var.alarm_email
}

locals {
  env_dim = { Environment = var.environment }
  actions = [aws_sns_topic.alarms.arn]

  # Ingestion condition alarms. The ingest service classifies its own state (tested in
  # tests/unit/test_metrics.py); exactly one condition series is 1 at any time.
  ingest_condition_alarms = {
    retrying  = { severity = "WARNING", periods = 2, text = "Temporary retry: transient database errors; messages wait unacknowledged at the broker. No action if it clears." }
    prolonged = { severity = "CRITICAL", periods = 1, text = "Prolonged blockage: retrying for >= 300 s. Ingestion is stopped; check the database. Broker queue is filling (max_queued_messages)." }
    blocked   = { severity = "CRITICAL", periods = 1, text = "Permanent blockage: an outcome cannot be made durable (even the dead letter failed). Operator action required; see ingest logs 'rejection_store_failed_message_not_acknowledged'." }
  }
}

resource "aws_cloudwatch_metric_alarm" "ingest_condition" {
  for_each            = local.ingest_condition_alarms
  alarm_name          = "gossy-${var.environment}-${lower(each.value.severity)}-ingest-${each.key}"
  alarm_description   = "[${each.value.severity}] ${each.value.text}"
  namespace           = "Gossy/App"
  metric_name         = "gossy_ingest_condition"
  dimensions          = merge(local.env_dim, { condition = each.key })
  statistic           = "Maximum"
  period              = 60
  evaluation_periods  = each.value.periods
  comparison_operator = "GreaterThanOrEqualToThreshold"
  threshold           = 1
  treat_missing_data  = "notBreaching" # absence is covered by ingest_metrics_missing
  alarm_actions       = local.actions
  ok_actions          = local.actions
}

resource "aws_cloudwatch_metric_alarm" "ingest_dead_letter" {
  alarm_name          = "gossy-${var.environment}-critical-ingest-dead-letter"
  alarm_description   = "[CRITICAL] A valid message was dead-lettered (non-transient error). It is stored with its full payload in rejected_messages (reason processing_failed) and needs investigation/replay. Ingestion continues."
  namespace           = "Gossy/App"
  metric_name         = "gossy_ingest_dead_letters_total"
  dimensions          = local.env_dim
  statistic           = "Sum"
  period              = 300
  evaluation_periods  = 1
  comparison_operator = "GreaterThanThreshold"
  threshold           = 0
  treat_missing_data  = "notBreaching"
  alarm_actions       = local.actions
}

resource "aws_cloudwatch_metric_alarm" "ingest_metrics_missing" {
  alarm_name          = "gossy-${var.environment}-critical-ingest-metrics-missing"
  alarm_description   = "[CRITICAL] No ingest metrics for 5 minutes: the ingest service, the host or the CloudWatch agent is down."
  namespace           = "Gossy/App"
  metric_name         = "gossy_ingest_mqtt_connected"
  dimensions          = local.env_dim
  statistic           = "SampleCount"
  period              = 300
  evaluation_periods  = 1
  comparison_operator = "LessThanThreshold"
  threshold           = 1
  treat_missing_data  = "breaching"
  alarm_actions       = local.actions
  ok_actions          = local.actions
}

resource "aws_cloudwatch_metric_alarm" "ingest_mqtt_disconnected" {
  alarm_name          = "gossy-${var.environment}-critical-ingest-mqtt-disconnected"
  alarm_description   = "[CRITICAL] Ingest has not been connected to the broker for 5 minutes (broker down or credentials/TLS problem)."
  namespace           = "Gossy/App"
  metric_name         = "gossy_ingest_mqtt_connected"
  dimensions          = local.env_dim
  statistic           = "Maximum"
  period              = 60
  evaluation_periods  = 5
  comparison_operator = "LessThanThreshold"
  threshold           = 1
  treat_missing_data  = "notBreaching"
  alarm_actions       = local.actions
  ok_actions          = local.actions
}

resource "aws_cloudwatch_metric_alarm" "database_down" {
  alarm_name          = "gossy-${var.environment}-critical-database-down"
  alarm_description   = "[CRITICAL] The ingest service cannot reach PostgreSQL (SELECT 1 fails at scrape time) for 3 minutes, even if no message is currently being retried."
  namespace           = "Gossy/App"
  metric_name         = "gossy_database_up"
  dimensions          = merge(local.env_dim, { job = "gossy-ingest" })
  statistic           = "Maximum"
  period              = 60
  evaluation_periods  = 3
  comparison_operator = "LessThanThreshold"
  threshold           = 1
  treat_missing_data  = "notBreaching" # absence is covered by ingest_metrics_missing
  alarm_actions       = local.actions
  ok_actions          = local.actions
}

resource "aws_cloudwatch_metric_alarm" "api_unhandled_errors" {
  alarm_name          = "gossy-${var.environment}-warning-api-unhandled-errors"
  alarm_description   = "[WARNING] Unhandled application errors (HTTP 500) in the API. See /gossy/${var.environment}/app, event unhandled_error."
  namespace           = "Gossy/App"
  metric_name         = "gossy_api_unhandled_errors_total"
  dimensions          = local.env_dim
  statistic           = "Sum"
  period              = 300
  evaluation_periods  = 1
  comparison_operator = "GreaterThanThreshold"
  threshold           = 0
  treat_missing_data  = "notBreaching"
  alarm_actions       = local.actions
}

resource "aws_cloudwatch_metric_alarm" "api_listener" {
  alarm_name          = "gossy-${var.environment}-warning-api-event-listener-down"
  alarm_description   = "[WARNING] The API's database LISTEN connection is down: live WebSocket updates are paused (clients resume from their cursor)."
  namespace           = "Gossy/App"
  metric_name         = "gossy_api_event_listener_connected"
  dimensions          = local.env_dim
  statistic           = "Maximum"
  period              = 60
  evaluation_periods  = 5
  comparison_operator = "LessThanThreshold"
  threshold           = 1
  treat_missing_data  = "breaching"
  alarm_actions       = local.actions
  ok_actions          = local.actions
}

# ------------------------------------------------------------------ host
resource "aws_cloudwatch_metric_alarm" "host_system_check" {
  alarm_name          = "gossy-${var.environment}-critical-host-system-check-recover"
  alarm_description   = "[CRITICAL] EC2 system status check failed; automatic instance recovery triggered (same volumes and Elastic IP)."
  namespace           = "AWS/EC2"
  metric_name         = "StatusCheckFailed_System"
  dimensions          = { InstanceId = aws_instance.host.id }
  statistic           = "Maximum"
  period              = 60
  evaluation_periods  = 2
  comparison_operator = "GreaterThanOrEqualToThreshold"
  threshold           = 1
  alarm_actions       = concat(local.actions, ["arn:${data.aws_partition.current.partition}:automate:${var.region}:ec2:recover"])
}

resource "aws_cloudwatch_metric_alarm" "host_instance_check" {
  alarm_name          = "gossy-${var.environment}-critical-host-instance-check"
  alarm_description   = "[CRITICAL] EC2 instance status check failed (OS-level problem)."
  namespace           = "AWS/EC2"
  metric_name         = "StatusCheckFailed_Instance"
  dimensions          = { InstanceId = aws_instance.host.id }
  statistic           = "Maximum"
  period              = 60
  evaluation_periods  = 3
  comparison_operator = "GreaterThanOrEqualToThreshold"
  threshold           = 1
  alarm_actions       = local.actions
  ok_actions          = local.actions
}

locals {
  host_alarms = {
    cpu      = { metric = "cpu_usage_active", dims = { InstanceId = aws_instance.host.id, cpu = "cpu-total" }, threshold = 85, text = "CPU above 85% for 15 minutes" }
    memory   = { metric = "mem_used_percent", dims = { InstanceId = aws_instance.host.id }, threshold = 85, text = "Memory above 85% for 15 minutes" }
    disk_os  = { metric = "disk_used_percent", dims = { InstanceId = aws_instance.host.id, path = "/" }, threshold = 80, text = "Root disk above 80%" }
    disk_dat = { metric = "disk_used_percent", dims = { InstanceId = aws_instance.host.id, path = "/srv/gossy" }, threshold = 80, text = "Data volume (/srv/gossy) above 80% - database/broker growth" }
  }
}

resource "aws_cloudwatch_metric_alarm" "host" {
  for_each            = local.host_alarms
  alarm_name          = "gossy-${var.environment}-warning-host-${each.key}"
  alarm_description   = "[WARNING] ${each.value.text}"
  namespace           = "Gossy/Host"
  metric_name         = each.value.metric
  dimensions          = each.value.dims
  statistic           = "Average"
  period              = 300
  evaluation_periods  = 3
  comparison_operator = "GreaterThanThreshold"
  threshold           = each.value.threshold
  treat_missing_data  = "missing"
  alarm_actions       = local.actions
  ok_actions          = local.actions
}

# ------------------------------------------------------------------ backups
resource "aws_cloudwatch_metric_alarm" "backup_missing" {
  alarm_name          = "gossy-${var.environment}-critical-backup-missing"
  alarm_description   = "[CRITICAL] No successful database backup reported in the last 24 hours (gossy-backup.timer, /var/log/gossy/ops.log)."
  namespace           = "Gossy"
  metric_name         = "BackupSucceeded"
  dimensions          = local.env_dim
  statistic           = "Sum"
  period              = 86400
  evaluation_periods  = 1
  comparison_operator = "LessThanThreshold"
  threshold           = 1
  treat_missing_data  = "breaching"
  alarm_actions       = local.actions
  ok_actions          = local.actions
}
