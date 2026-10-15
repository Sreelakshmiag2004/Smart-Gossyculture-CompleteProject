set -a; . /etc/gossy/gossy.env; set +a
C="docker compose --env-file /etc/gossy/gossy.env --env-file /etc/gossy/release.env -f /opt/gossy/compose.yaml $GOSSY_COMPOSE_EXTRA"
export GOSSY_COMPOSE="$C"
cd /opt/gossy
echo "== secrets on persistent disk? (every rendered secret value >= 16 chars searched as a fixed string under /srv/gossy, /opt/gossy, /etc; pgdata excluded - checked separately)"
find /run/gossy-secrets -type f ! -name '.*' -exec cat {} \; -exec echo \; | grep -E '^.{16,}$' | sort -u > /run/gossy-secrets/.patterns
echo "  patterns: $(wc -l < /run/gossy-secrets/.patterns) distinct secret values"
HITS=$(find /srv/gossy /opt/gossy /etc -xdev -type f -size -20M ! -path '/srv/gossy/pgdata/*' ! -name rehearsal-secrets.json -print0 | xargs -0 grep -l -F -f /run/gossy-secrets/.patterns 2>/dev/null)
if [ -n "$HITS" ]; then echo "$HITS" | sed 's/^/  FOUND: /'; else echo "  none found"; fi
echo "  pgdata: $(find /srv/gossy/pgdata -xdev -type f -size -200M -print0 | xargs -0 grep -l -F -f /run/gossy-secrets/.patterns 2>/dev/null | wc -l) file(s) contain a plaintext secret"
rm -f /run/gossy-secrets/.patterns
