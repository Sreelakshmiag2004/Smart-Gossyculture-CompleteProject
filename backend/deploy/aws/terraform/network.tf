# Pilot network: one VPC, one public subnet in one AZ, one host with an Elastic IP.
# Single-AZ is a documented pilot limitation (no multi-AZ failover; restore from backup instead).

data "aws_availability_zones" "available" {
  state = "available"
}

resource "aws_vpc" "main" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true
  tags                 = { Name = "gossy-${var.environment}" }
}

resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id
  tags   = { Name = "gossy-${var.environment}" }
}

resource "aws_subnet" "public" {
  vpc_id                  = aws_vpc.main.id
  cidr_block              = cidrsubnet(var.vpc_cidr, 8, 1)
  availability_zone       = data.aws_availability_zones.available.names[0]
  map_public_ip_on_launch = false # the host gets an Elastic IP explicitly
  tags                    = { Name = "gossy-${var.environment}-public" }
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.main.id
  }
  tags = { Name = "gossy-${var.environment}-public" }
}

resource "aws_route_table_association" "public" {
  subnet_id      = aws_subnet.public.id
  route_table_id = aws_route_table.public.id
}

# The default security group of the VPC allows nothing.
resource "aws_default_security_group" "default" {
  vpc_id = aws_vpc.main.id
}

# ------------------------------------------------------------------ host firewall
# Inbound: 443/tcp (HTTPS REST + WSS, and the TLS-ALPN ACME challenge) and 8883/tcp (MQTT/TLS).
# NOT open: 22 (administration is via SSM Session Manager), 80, 1883, 5432, 2375/2376,
# 8000/8001 (loopback only on the host). Outbound: 443/tcp only (ECR, S3, Secrets Manager,
# CloudWatch, SSM, Let's Encrypt, OS packages). The VPC DNS resolver, IMDS and the Amazon Time
# Sync Service (169.254.169.123) are link-local and not subject to security groups.
resource "aws_security_group" "host" {
  name        = "gossy-${var.environment}-host"
  description = "Smart Gossyculture host: 443 and 8883 in, 443 out"
  vpc_id      = aws_vpc.main.id
  tags        = { Name = "gossy-${var.environment}-host" }
}

resource "aws_vpc_security_group_ingress_rule" "https" {
  for_each          = toset(var.api_ingress_cidrs)
  security_group_id = aws_security_group.host.id
  description       = "HTTPS REST/WSS + ACME TLS-ALPN"
  ip_protocol       = "tcp"
  from_port         = 443
  to_port           = 443
  cidr_ipv4         = each.value
}

resource "aws_vpc_security_group_ingress_rule" "mqtt_tls" {
  for_each          = toset(var.mqtt_ingress_cidrs)
  security_group_id = aws_security_group.host.id
  description       = "MQTT over TLS from devices"
  ip_protocol       = "tcp"
  from_port         = 8883
  to_port           = 8883
  cidr_ipv4         = each.value
}

resource "aws_vpc_security_group_egress_rule" "https_out" {
  security_group_id = aws_security_group.host.id
  description       = "HTTPS to AWS APIs, container registry, Let's Encrypt, OS packages"
  ip_protocol       = "tcp"
  from_port         = 443
  to_port           = 443
  cidr_ipv4         = "0.0.0.0/0"
}

# ------------------------------------------------------------------ VPC flow logs (rejected traffic)
resource "aws_cloudwatch_log_group" "flow" {
  name              = "/gossy/${var.environment}/vpc-flow"
  retention_in_days = var.log_retention_days
  kms_key_id        = aws_kms_key.main.arn
}

resource "aws_flow_log" "rejects" {
  vpc_id               = aws_vpc.main.id
  traffic_type         = "REJECT"
  log_destination_type = "cloud-watch-logs"
  log_destination      = aws_cloudwatch_log_group.flow.arn
  iam_role_arn         = aws_iam_role.flow_logs.arn
}

resource "aws_iam_role" "flow_logs" {
  name = "gossy-${var.environment}-flow-logs"
  assume_role_policy = jsonencode({
    Version   = "2012-10-17"
    Statement = [{ Effect = "Allow", Principal = { Service = "vpc-flow-logs.amazonaws.com" }, Action = "sts:AssumeRole" }]
  })
}

resource "aws_iam_role_policy" "flow_logs" {
  role = aws_iam_role.flow_logs.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["logs:CreateLogStream", "logs:PutLogEvents", "logs:DescribeLogStreams"]
      Resource = "${aws_cloudwatch_log_group.flow.arn}:*"
    }]
  })
}
