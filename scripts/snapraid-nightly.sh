#!/usr/bin/env bash
# Nightly SnapRAID job, run as root by snapraid-nightly.timer at 3:30. Installed as
# /usr/local/bin/snapraid-nightly; after editing:
#   sudo install -m 755 ~/home-server/scripts/snapraid-nightly.sh /usr/local/bin/snapraid-nightly
#
#   1. Refuse to sync if more than THRESHOLD files were deleted, so an accidental wipe doesn't
#      overwrite the parity that could restore them
#   2. Sync
#   3. Sundays: scrub 8% (blocks not checked in 10 days)
#   4. Alert on any bad blocks in snapraid status
# Pings Uptime Kuma on success, ntfy "disks" on failure. Log: /var/log/snapraid-nightly.log
set -uo pipefail

THRESHOLD=50
LOG=${SNAPRAID_LOG:-/var/log/snapraid-nightly.log}
NOTIFY_ENV=${NOTIFY_ENV:-/home/saul/home-server/scripts/notify.env}

# notify.env is owned by saul: read values from it rather than sourcing it as root
val() { sed -n "s/^$1=//p" "$NOTIFY_ENV" 2>/dev/null | tail -n 1; }
NTFY_URL=$(val NTFY_URL)
NTFY_TOKEN=$(val NTFY_TOKEN)
KUMA_PUSH=$(val KUMA_PUSH_SNAPRAID)

exec > >(tee "$LOG") 2>&1   # log file and journal

STEP="Setup"
# Alert with the failed step and the reason, or else its last line
fail() {
  local why=${1:-}
  if [ -z "$why" ]; then sleep 0.3; why=$(grep -v '^[[:space:]]*$' "$LOG" | tail -n 1 | cut -c1-200); fi
  local msg="$STEP failed${why:+: $why}"
  msg=${msg%.}
  echo "$(date -Is) FAILED: $msg"
  curl -fsS -m 20 -H "Authorization: Bearer $NTFY_TOKEN" -H "Title: SnapRAID (parity) FAILED" \
    -H "Priority: high" -H "Tags: warning" -d "$msg. Log: $LOG" "$NTFY_URL/disks" >/dev/null 2>&1 || true
  exit 1
}

echo "$(date -Is) start"

# 1) snapraid diff exits 0 (no changes), 2 (changes) or anything else (error)
STEP="Safety check"
diff_out=$(snapraid diff 2>&1); rc=$?
grep -E '^ *[0-9]+ (equal|added|removed|updated|moved|copied|restored)$' <<<"$diff_out"
if [ "$rc" != 0 ] && [ "$rc" != 2 ]; then
  fail "snapraid diff exited with $rc: $(grep -v '^[[:space:]]*$' <<<"$diff_out" | tail -n 1 | cut -c1-200)"
fi
removed=$(awk '$2=="removed"{print $1}' <<<"$diff_out")
if [ "${removed:-0}" -gt "$THRESHOLD" ]; then
  fail "$removed files deleted since the last sync (limit $THRESHOLD), so parity was left alone. If that was on purpose: sudo snapraid sync. If not, bring them back: sudo snapraid fix -m"
fi

# 2) Sync
STEP="Sync"
snapraid sync || fail

# 3) Weekly scrub
if [ "$(date +%u)" = 7 ]; then
  STEP="Scrub"
  snapraid scrub -p 8 -o 10 || fail
fi

# 4) Bad blocks from any earlier scrub stay listed until fixed
STEP="Status check"
status_out=$(snapraid status 2>&1) || fail "snapraid status exited with $?"
if grep -q "DANGER" <<<"$status_out"; then
  fail "$(grep -m 1 "DANGER" <<<"$status_out" | cut -c1-120) Details: sudo snapraid status. Repair: sudo snapraid -e fix"
fi

summary=$(awk '$2=="added"||$2=="removed"||$2=="updated"{printf "%s%s %s", sep, $1, $2; sep=", "}' <<<"$diff_out")
msg="OK${summary:+, $summary}"
echo "$(date -Is) $msg"
if [ -n "$KUMA_PUSH" ]; then
  curl -fsS -m 20 -G --data-urlencode "status=up" --data-urlencode "msg=$msg" \
    "https://kuma.saulreyna.com/api/push/$KUMA_PUSH" >/dev/null 2>&1 || true
fi
exit 0
