# Single pilot host: Amazon Linux 2023 (x86_64), Docker, CloudWatch agent, SSM agent.
# All four services (Caddy/API, ingest, Mosquitto, PostgreSQL+TimescaleDB) run on it via
# Docker Compose (Phase 0 ADR-12). No SSH key, no port 22: administration via SSM.

data "aws_ssm_parameter" "al2023" {
  name = "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64"
}

locals {
  production         = var.environment == "production"
  host_env_parameter = "/gossy/${var.environment}/host-env"
  env_file = {
    GOSSY_ENVIRONMENT                    = var.environment
    GOSSY_AWS_REGION                     = var.region
    GOSSY_IMAGE_REPO                     = aws_ecr_repository.backend.repository_url
    GOSSY_LOG_GROUP                      = aws_cloudwatch_log_group.app.name
    GOSSY_SECRET_ID                      = aws_secretsmanager_secret.runtime.name
    GOSSY_BACKUP_BUCKET                  = aws_s3_bucket.this["backups"].id
    GOSSY_KMS_KEY_ARN                    = aws_kms_key.main.arn
    GOSSY_API_PUBLIC_HOST                = coalesce(var.api_public_host, "unset.invalid")
    GOSSY_MQTT_PUBLIC_HOST               = coalesce(var.mqtt_public_host, "unset-mqtt.invalid")
    GOSSY_ACME_EMAIL                     = var.acme_email == null ? "" : var.acme_email
    GOSSY_CONFIG_PARAMETER               = local.host_env_parameter
    GOSSY_TLS_PROFILE                    = "acme"
    GOSSY_AUTH_TEST_MODE                 = local.production ? "false" : "true"
    GOSSY_AUTH_TEST_PHONE_NUMBERS        = local.production ? "" : "+99900000001,+99900000002,+99900000009"
    GOSSY_AUTH_TEST_OTP_CODE_FILE        = local.production ? "" : "/run/gossy-secrets/auth/test-otp.code"
    GOSSY_INGEST_RETRY_PROLONGED_AFTER_S = "300"
  }
}

# /etc/gossy/gossy.env (NON-secret settings) is kept in an SSM parameter, not baked into
# user-data: user-data runs only on the first boot, so a later change (e.g. the hostnames once
# U-6 is decided) would never reach an existing host. bin/render-config.sh refreshes the file
# from this parameter at the start of every deployment.
resource "aws_ssm_parameter" "host_env" {
  name        = local.host_env_parameter
  description = "Smart Gossyculture ${var.environment} host settings (non-secret) -> /etc/gossy/gossy.env"
  type        = "String"
  value       = join("\n", concat([for k, v in local.env_file : "${k}=${v}"], [""]))
}

resource "aws_instance" "host" {
  ami                         = data.aws_ssm_parameter.al2023.value
  instance_type               = var.instance_type
  subnet_id                   = aws_subnet.public.id
  vpc_security_group_ids      = [aws_security_group.host.id]
  iam_instance_profile        = aws_iam_instance_profile.host.name
  associate_public_ip_address = false
  disable_api_termination     = local.production
  monitoring                  = false

  metadata_options {
    http_tokens                 = "required" # IMDSv2 only
    http_put_response_hop_limit = 1          # containers cannot reach instance credentials
    http_endpoint               = "enabled"
  }

  root_block_device {
    volume_type           = "gp3"
    volume_size           = var.root_volume_gb
    encrypted             = true
    kms_key_id            = aws_kms_key.main.arn
    delete_on_termination = true
  }

  user_data_replace_on_change = false
  user_data = templatefile("${path.module}/user_data.sh.tftpl", {
    host_env_parameter     = aws_ssm_parameter.host_env.name
    data_volume_id         = aws_ebs_volume.data.id
    artifacts_bucket       = aws_s3_bucket.this["artifacts"].id
    deploy_bundle_key      = var.deploy_bundle_key == null ? "" : var.deploy_bundle_key
    docker_compose_version = var.docker_compose_version
    docker_compose_sha256  = var.docker_compose_sha256
    region                 = var.region
  })

  lifecycle {
    # AMI updates are a deliberate host replacement, not a drift. user-data is first-boot
    # bootstrap only: changing it on a running host would stop/start the instance without
    # re-running it, so later changes apply at the next host replacement.
    ignore_changes = [ami, user_data]
  }

  tags = { Name = "gossy-${var.environment}-host" }
}

# Data (PostgreSQL, broker store, TLS state) lives on its own encrypted volume, independent of
# the instance: a host replacement re-attaches it.
resource "aws_ebs_volume" "data" {
  availability_zone = aws_subnet.public.availability_zone
  size              = var.data_volume_gb
  type              = "gp3"
  encrypted         = true
  kms_key_id        = aws_kms_key.main.arn
  final_snapshot    = local.production
  tags              = { Name = "gossy-${var.environment}-data" }
}

resource "aws_volume_attachment" "data" {
  device_name = "/dev/sdf"
  volume_id   = aws_ebs_volume.data.id
  instance_id = aws_instance.host.id
}

resource "aws_eip" "host" {
  domain   = "vpc"
  instance = aws_instance.host.id
  tags     = { Name = "gossy-${var.environment}" }
}
