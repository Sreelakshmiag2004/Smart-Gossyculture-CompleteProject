# Plan-level policy tests. The AWS provider is MOCKED (no AWS account or credentials needed), so
# these check the CONFIGURATION - what Terraform would create - not real AWS behaviour. They do
# not replace `terraform plan` against the real account.
#
#   cd deploy/aws/terraform && terraform init -backend=false
#   terraform test -var-file=environments/staging.tfvars
#   terraform test -var-file=environments/production.tfvars
#
# The account id, AMI id and checksum below are mock inputs for the test run only.

mock_provider "aws" {
  mock_data "aws_availability_zones" {
    defaults = { names = ["ap-south-1a", "ap-south-1b", "ap-south-1c"] }
  }
  mock_data "aws_caller_identity" {
    defaults = { account_id = "000000000000" }
  }
  mock_data "aws_partition" {
    defaults = { partition = "aws" }
  }
  mock_data "aws_ssm_parameter" {
    defaults = { value = "ami-00000000000000000" }
  }
}

variables {
  docker_compose_sha256 = "0000000000000000000000000000000000000000000000000000000000000000"
}

run "network_least_privilege" {
  command = plan

  assert {
    condition = toset(concat(
      [for r in aws_vpc_security_group_ingress_rule.https : "${r.ip_protocol}/${r.from_port}-${r.to_port}"],
      [for r in aws_vpc_security_group_ingress_rule.mqtt_tls : "${r.ip_protocol}/${r.from_port}-${r.to_port}"],
    )) == toset(["tcp/443-443", "tcp/8883-8883"])
    error_message = "Inbound must be exactly 443/tcp and 8883/tcp (no 22, 80, 1883, 5432, 2375, 8000, 8001)."
  }
  assert {
    condition     = aws_vpc_security_group_egress_rule.https_out.from_port == 443 && aws_vpc_security_group_egress_rule.https_out.to_port == 443 && aws_vpc_security_group_egress_rule.https_out.ip_protocol == "tcp"
    error_message = "Outbound must be 443/tcp only."
  }
  assert {
    condition     = aws_subnet.public.map_public_ip_on_launch == false && aws_instance.host.associate_public_ip_address == false
    error_message = "The only public address is the explicit Elastic IP."
  }
  assert {
    condition     = aws_flow_log.rejects.traffic_type == "REJECT"
    error_message = "Rejected traffic must be logged."
  }
}

run "host_hardening" {
  command = plan

  assert {
    condition     = aws_instance.host.metadata_options[0].http_tokens == "required" && aws_instance.host.metadata_options[0].http_put_response_hop_limit == 1
    error_message = "IMDSv2 only, hop limit 1 (containers must not reach instance credentials)."
  }
  # (No SSH key pair is configured - key_name is absent from compute.tf. It is provider-computed,
  # so it cannot be asserted at plan time; port 22 being closed is asserted above.)
  assert {
    condition     = aws_instance.host.root_block_device[0].encrypted && aws_ebs_volume.data.encrypted
    error_message = "Root and data volumes must be encrypted."
  }
  assert {
    condition     = aws_instance.host.disable_api_termination == (var.environment == "production")
    error_message = "Production host must have termination protection."
  }
  assert {
    condition     = aws_ebs_volume.data.final_snapshot == (var.environment == "production")
    error_message = "Production data volume must take a final snapshot on deletion."
  }
}

run "storage_registry_secrets" {
  command = plan

  assert {
    condition     = alltrue([for b in aws_s3_bucket_public_access_block.this : b.block_public_acls && b.block_public_policy && b.ignore_public_acls && b.restrict_public_buckets])
    error_message = "Every bucket must block all public access."
  }
  assert {
    condition     = alltrue([for v in aws_s3_bucket_versioning.this : v.versioning_configuration[0].status == "Enabled"])
    error_message = "Buckets must be versioned."
  }
  assert {
    condition     = alltrue([for e in aws_s3_bucket_server_side_encryption_configuration.this : one(e.rule).apply_server_side_encryption_by_default[0].sse_algorithm == "aws:kms"])
    error_message = "Buckets must use SSE-KMS."
  }
  assert {
    condition     = one(aws_s3_bucket_lifecycle_configuration.backups.rule).expiration[0].days == var.backup_retention_days
    error_message = "Backup retention must follow backup_retention_days."
  }
  assert {
    condition     = aws_ecr_repository.backend.image_tag_mutability == "IMMUTABLE" && aws_ecr_repository.backend.image_scanning_configuration[0].scan_on_push
    error_message = "Registry must have immutable tags and scan on push."
  }
  assert {
    condition     = aws_kms_key.main.enable_key_rotation
    error_message = "KMS key rotation must be on."
  }
  assert {
    condition     = aws_secretsmanager_secret.runtime.name == "gossy/${var.environment}/runtime"
    error_message = "Each environment has its own secret."
  }
}

run "environment_separation" {
  command = plan

  # Temporary test mechanisms (U-4 test OTP numbers, U-7 simulator device accounts) exist in
  # staging only and never in production.
  assert {
    condition     = length(local.test_devices) == (var.environment == "staging" ? length(var.staging_test_devices) : 0)
    error_message = "Test device accounts must not exist in production."
  }
  assert {
    condition     = local.env_file.GOSSY_AUTH_TEST_MODE == (var.environment == "production" ? "false" : "true")
    error_message = "OTP test mode must be off in production."
  }
  assert {
    condition     = local.env_file.GOSSY_AUTH_TEST_PHONE_NUMBERS == "" || var.environment == "staging"
    error_message = "No test phone numbers in production."
  }
  assert {
    condition     = local.env_file.GOSSY_TLS_PROFILE == "acme"
    error_message = "AWS hosts always use publicly trusted certificates (never the internal/dev CA)."
  }
  assert {
    condition     = alltrue([for k, v in local.env_file : !can(regex("(?i)password|secret_key|signing|hmac", k))])
    error_message = "The host env file must contain non-secret settings only."
  }
  assert {
    condition     = aws_ssm_parameter.host_env.name == "/gossy/${var.environment}/host-env" && aws_ssm_parameter.host_env.type == "String"
    error_message = "Host settings live in a per-environment, non-secret SSM parameter."
  }
}

run "ingestion_alerts_distinguish_conditions" {
  command = plan

  assert {
    condition     = toset(keys(aws_cloudwatch_metric_alarm.ingest_condition)) == toset(["retrying", "prolonged", "blocked"])
    error_message = "Temporary retry, prolonged blockage and permanent blockage need separate alarms."
  }
  assert {
    condition     = strcontains(aws_cloudwatch_metric_alarm.ingest_condition["retrying"].alarm_name, "warning") && strcontains(aws_cloudwatch_metric_alarm.ingest_condition["prolonged"].alarm_name, "critical") && strcontains(aws_cloudwatch_metric_alarm.ingest_condition["blocked"].alarm_name, "critical")
    error_message = "Retry is a warning; prolonged and blocked are critical."
  }
  assert {
    condition     = aws_cloudwatch_metric_alarm.ingest_dead_letter.metric_name == "gossy_ingest_dead_letters_total"
    error_message = "Dead letters need their own alarm."
  }
  assert {
    condition     = aws_cloudwatch_metric_alarm.ingest_metrics_missing.treat_missing_data == "breaching" && aws_cloudwatch_metric_alarm.backup_missing.treat_missing_data == "breaching"
    error_message = "Silence (no metrics, no backup) must alarm."
  }
}

run "region_is_locked_to_mumbai" {
  command = plan
  variables {
    region = "us-east-1"
  }
  expect_failures = [var.region]
}

run "development_is_not_an_aws_environment" {
  command = plan
  variables {
    environment = "development"
  }
  expect_failures = [var.environment]
}
