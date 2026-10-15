set -a; . /etc/gossy/gossy.env; set +a
C="docker compose --env-file /etc/gossy/gossy.env --env-file /etc/gossy/release.env -f /opt/gossy/compose.yaml $GOSSY_COMPOSE_EXTRA"
cd /opt/gossy
PC="$C --profile ops run --rm --no-deps -T"
echo "== A. PRODUCTION settings with the current placeholders (no domain, no ACME contact - U-6): must be refused"
$PC -e GOSSY_ENVIRONMENT=production -e GOSSY_AUTH_TEST_MODE=false -e GOSSY_AUTH_TEST_PHONE_NUMBERS= -e GOSSY_AUTH_TEST_OTP_CODE_FILE= -e GOSSY_TLS_PROFILE=acme -e GOSSY_API_PUBLIC_HOST=unset.invalid -e GOSSY_MQTT_PUBLIC_HOST=unset-mqtt.invalid prodcheck 2>/dev/null | grep -E '^(FAIL|prodcheck)'; echo "exit=${PIPESTATUS[0]}"
echo "== B. PRODUCTION with staging test mechanisms left on (OTP test mode, internal CA): must be refused"
$PC -e GOSSY_ENVIRONMENT=production prodcheck 2>/dev/null | grep -E '^(FAIL|prodcheck)'; echo "exit=${PIPESTATUS[0]}"
echo "== C. the api service itself refuses to start in production with OTP test mode"
$C run --rm --no-deps -T -e GOSSY_ENVIRONMENT=production api python -c "from gossy.api.app import create_app; create_app()" 2>&1 | grep -v -E '^\s*Container ' | tail -1 | cut -c1-240; echo "exit=${PIPESTATUS[0]}"
echo "== D. staging secret document (test OTP code + test devices) refused on a production host; rendered secrets untouched"
sed 's/^GOSSY_ENVIRONMENT=.*/GOSSY_ENVIRONMENT=production/' /etc/gossy/gossy.env > /tmp/prod.env
BEFORE=$(find /run/gossy-secrets -type f | wc -l); REV=$(cat /run/gossy-secrets/.revision)
GOSSY_ENV_FILE=/tmp/prod.env /opt/gossy/bin/render-secrets.sh --from-file /etc/gossy/rehearsal-secrets.json 2>&1 | tail -1; echo "exit=${PIPESTATUS[0]}"
echo "secret files before/after: $BEFORE/$(find /run/gossy-secrets -type f | wc -l); revision unchanged: $([ "$REV" = "$(cat /run/gossy-secrets/.revision)" ] && echo yes || echo NO)"
echo "== E. development secrets refused"
python3 -c "import json;d=json.load(open('/etc/gossy/rehearsal-secrets.json'));d['db_app_password']='devonly-'+'x'*40;print(json.dumps(d))" > /tmp/dev-secrets.json
/opt/gossy/bin/render-secrets.sh --from-file /tmp/dev-secrets.json 2>&1 | tail -1; echo "exit=${PIPESTATUS[0]}"; rm -f /tmp/dev-secrets.json /tmp/prod.env
echo "== F. production-shaped secret document (same generator shape as Terraform: no test code, no test devices) - value lengths only"
python3 /opt/gossy/rehearsal/make-secrets.py production | python3 -c "import json,sys;d=json.load(sys.stdin);print({k:(len(v) if isinstance(v,str) else v) for k,v in d.items()})"
echo "== G. unpinned image tags refused by deploy.sh"
for t in latest dev; do /opt/gossy/bin/deploy.sh $t 2>&1 | tail -1; done
echo "== H. stack still healthy after the refusals"; curl -fsS http://127.0.0.1:8000/readyz | cut -c1-18; echo; curl -fsS http://127.0.0.1:8001/readyz | cut -c1-18; echo
