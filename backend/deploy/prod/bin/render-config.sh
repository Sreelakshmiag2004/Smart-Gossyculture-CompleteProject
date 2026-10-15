#!/usr/bin/env bash
# Refresh /etc/gossy/gossy.env (NON-secret settings) from the SSM parameter that Terraform
# maintains (deploy/aws/terraform/compute.tf, aws_ssm_parameter.host_env). Run by bin/deploy.sh
# before every deployment, so a settings change (e.g. the public hostnames once U-6 is decided)
# reaches an existing host: EC2 user-data only runs on the first boot.
#
# Without GOSSY_CONFIG_PARAMETER in the current file (LOCAL REHEARSAL: no AWS) the file is kept.
set -euo pipefail
ENV_FILE=${GOSSY_ENV_FILE:-/etc/gossy/gossy.env}
[ -f "$ENV_FILE" ] || { echo "config: $ENV_FILE missing (written by user-data)" >&2; exit 1; }
set -a; . "$ENV_FILE"; set +a
if [ -z "${GOSSY_CONFIG_PARAMETER:-}" ]; then
  echo "config: no GOSSY_CONFIG_PARAMETER - keeping $ENV_FILE as it is"
  exit 0
fi

TMP=$(mktemp "$ENV_FILE.XXXXXX")
trap 'rm -f "$TMP"' EXIT
aws ssm get-parameter --region "${GOSSY_AWS_REGION:?}" --name "$GOSSY_CONFIG_PARAMETER" --query Parameter.Value --output text > "$TMP"
# A host never switches environment: refuse a parameter that belongs to another one.
grep -qx "GOSSY_ENVIRONMENT=${GOSSY_ENVIRONMENT:?}" "$TMP" || { echo "config: $GOSSY_CONFIG_PARAMETER is not for environment $GOSSY_ENVIRONMENT" >&2; exit 1; }
if cmp -s "$TMP" "$ENV_FILE"; then
  echo "config: $ENV_FILE unchanged"
  exit 0
fi
chmod 0640 "$TMP"
mv "$TMP" "$ENV_FILE"
trap - EXIT
echo "config: $ENV_FILE refreshed from $GOSSY_CONFIG_PARAMETER"
