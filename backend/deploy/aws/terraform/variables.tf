variable "environment" {
  description = "staging or production. Each has its own state, VPC, host, secrets, bucket and alarms."
  type        = string
  validation {
    condition     = contains(["staging", "production"], var.environment)
    error_message = "environment must be staging or production (development runs locally with Docker Compose)."
  }
}

variable "region" {
  description = "AWS region. Locked to Mumbai by Phase 0 ADR-01."
  type        = string
  default     = "ap-south-1"
  validation {
    condition     = var.region == "ap-south-1"
    error_message = "Phase 0 ADR-01 locks hosting to ap-south-1 (Mumbai)."
  }
}

variable "vpc_cidr" {
  type    = string
  default = "10.40.0.0/16"
}

variable "instance_type" {
  description = "Single host for the pilot (API, ingest, Mosquitto, PostgreSQL/TimescaleDB). x86_64: the image is built for linux/amd64."
  type        = string
  default     = "t3.medium"
}

variable "root_volume_gb" {
  type    = number
  default = 20
}

variable "data_volume_gb" {
  description = "Encrypted gp3 volume mounted at /srv/gossy (database, broker store, TLS state). Sizing depends on U-15 (pilot scale/retention)."
  type        = number
  default     = 50
}

variable "api_ingress_cidrs" {
  description = "Sources allowed to reach HTTPS/WSS 443 (farmers' phones: the internet)."
  type        = list(string)
  default     = ["0.0.0.0/0"]
}

variable "mqtt_ingress_cidrs" {
  description = "Sources allowed to reach MQTT/TLS 8883. Field devices on mobile networks have no fixed addresses, so this is open unless a fixed uplink is chosen (U-9)."
  type        = list(string)
  default     = ["0.0.0.0/0"]
}

variable "api_public_host" {
  description = "Public API hostname. DECISION NEEDED (U-6): no domain exists; null keeps a placeholder and prodcheck refuses a production deployment."
  type        = string
  default     = null
}

variable "mqtt_public_host" {
  description = "Public MQTT hostname (U-6)."
  type        = string
  default     = null
}

variable "acme_email" {
  description = "Mailbox for Let's Encrypt account/expiry notices."
  type        = string
  default     = null
}

variable "alarm_email" {
  description = "Optional e-mail subscription for alarms (confirmation required). null = SNS topic without subscribers."
  type        = string
  default     = null
}

variable "backup_retention_days" {
  description = "Days daily database dumps are kept. Retention policy is U-15 (DPDP review); 35 is a recommended default, not a decision."
  type        = number
  default     = 35
}

variable "log_retention_days" {
  type    = number
  default = 30
}

variable "secret_version" {
  description = "Increment to regenerate ALL runtime secrets (write-only; old values are not kept in state). Requires re-rendering on the host and restarting the stack."
  type        = number
  default     = 1
}

variable "staging_test_devices" {
  description = "STAGING ONLY: temporary simulator device accounts (sim-*) for infrastructure testing while U-7 is open. Ignored in production."
  type        = list(string)
  default     = ["sim-0001", "sim-0002"]
}

variable "deploy_bundle_key" {
  description = "Object key of the deploy bundle in the artifacts bucket (scripts/package-bundle.sh). null = install later via SSM."
  type        = string
  default     = null
}

variable "docker_compose_version" {
  description = "Docker Compose CLI plugin release installed on the host (not packaged by Amazon Linux 2023)."
  type        = string
  default     = "v2.40.3"
}

variable "docker_compose_sha256" {
  description = "SHA-256 of docker-compose-linux-x86_64 for docker_compose_version (from the release's checksums file). Required at apply time; the host refuses an unverified download."
  type        = string
}
