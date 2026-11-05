# Helpers for the backup scripts (sourced). Reads notify.env next to this file.
# shellcheck shell=bash

# shellcheck source=/dev/null
. "$(dirname "${BASH_SOURCE[0]}")/notify.env"

# ntfy <topic> <title> <message> [priority] [tags]
# Topics: alerts, backups, disks, updates. Never fails the caller.
ntfy() {
  curl -fsS -m 20 -H "Authorization: Bearer $NTFY_TOKEN" -H "Title: $2" \
    -H "Priority: ${4:-default}" -H "Tags: ${5:-}" -d "$3" "$NTFY_URL/$1" >/dev/null 2>&1 || true
}

# kuma_push <token> <message>: report success to an Uptime Kuma push monitor. Never fails the caller.
kuma_push() {
  curl -fsS -m 20 -G --data-urlencode "status=up" --data-urlencode "msg=$2" \
    "https://kuma.saulreyna.com/api/push/$1" >/dev/null 2>&1 || true
}
