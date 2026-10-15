# Host role: least privilege for exactly this environment's resources.

resource "aws_iam_role" "host" {
  name = "gossy-${var.environment}-host"
  assume_role_policy = jsonencode({
    Version   = "2012-10-17"
    Statement = [{ Effect = "Allow", Principal = { Service = "ec2.amazonaws.com" }, Action = "sts:AssumeRole" }]
  })
}

resource "aws_iam_instance_profile" "host" {
  name = "gossy-${var.environment}-host"
  role = aws_iam_role.host.name
}

# Session Manager (shell + Run Command) instead of SSH.
resource "aws_iam_role_policy_attachment" "ssm" {
  role       = aws_iam_role.host.name
  policy_arn = "arn:${data.aws_partition.current.partition}:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_role_policy" "host" {
  name = "gossy-${var.environment}-host"
  role = aws_iam_role.host.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      { Sid = "EcrAuth", Effect = "Allow", Action = "ecr:GetAuthorizationToken", Resource = "*" },
      {
        Sid      = "EcrPull"
        Effect   = "Allow"
        Action   = ["ecr:BatchGetImage", "ecr:GetDownloadUrlForLayer", "ecr:BatchCheckLayerAvailability"]
        Resource = aws_ecr_repository.backend.arn
      },
      { Sid = "RuntimeSecret", Effect = "Allow", Action = "secretsmanager:GetSecretValue", Resource = aws_secretsmanager_secret.runtime.arn },
      { Sid = "HostSettings", Effect = "Allow", Action = "ssm:GetParameter", Resource = aws_ssm_parameter.host_env.arn },
      { Sid = "Kms", Effect = "Allow", Action = ["kms:Decrypt", "kms:GenerateDataKey"], Resource = aws_kms_key.main.arn },
      {
        Sid      = "BackupsWriteRead"
        Effect   = "Allow"
        Action   = ["s3:PutObject", "s3:GetObject"]
        Resource = "${aws_s3_bucket.this["backups"].arn}/${var.environment}/db/*"
      },
      {
        Sid       = "BackupsList"
        Effect    = "Allow"
        Action    = "s3:ListBucket"
        Resource  = aws_s3_bucket.this["backups"].arn
        Condition = { StringLike = { "s3:prefix" = ["${var.environment}/db/*"] } }
      },
      { Sid = "Bundles", Effect = "Allow", Action = "s3:GetObject", Resource = "${aws_s3_bucket.this["artifacts"].arn}/bundles/*" },
      {
        Sid    = "Logs"
        Effect = "Allow"
        Action = ["logs:CreateLogStream", "logs:PutLogEvents", "logs:DescribeLogStreams"]
        Resource = [
          "${aws_cloudwatch_log_group.app.arn}:*",
          "${aws_cloudwatch_log_group.prometheus.arn}:*",
        ]
      },
      {
        Sid       = "Metrics"
        Effect    = "Allow"
        Action    = "cloudwatch:PutMetricData"
        Resource  = "*"
        Condition = { StringLike = { "cloudwatch:namespace" = ["Gossy", "Gossy/*"] } }
      },
      { Sid = "AgentDescribe", Effect = "Allow", Action = ["ec2:DescribeTags", "ec2:DescribeVolumes"], Resource = "*" },
    ]
  })
}
