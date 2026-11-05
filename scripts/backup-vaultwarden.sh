#!/usr/bin/env bash
# Nightly Vaultwarden snapshot from the Pi onto the pool (cron, 3:15). Pings Kuma on success,
# ntfy on failure. Restore: stop vaultwarden, extract into its data folder, rename
# db_*.sqlite3 to db.sqlite3.
set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=notify.sh
. "$HERE/notify.sh"

PI=saul@192.168.50.143
DEST=/mnt/storage/backups/vaultwarden
KEEP_DAYS=30

STEP="Setup"
ERRF=$(mktemp)
exec 2> >(tee -a "$ERRF" >&2)   # keep stderr for the alert text too

# Alert with the failed step and the reason, or else its last error line
fail() {
  local why=${1:-}
  if [ -z "$why" ]; then sleep 0.3; why=$(grep -v '^[[:space:]]*$' "$ERRF" | tail -n 1 | cut -c1-200); fi
  local msg="$STEP failed${why:+: $why}"
  echo "$(date -Is) FAILED: $msg" >&2
  ntfy backups "Vaultwarden backup FAILED" "$msg. Log: $DEST/backup.log" high warning
  exit 1
}
trap 'fail' ERR

umask 077
mkdir -p "$DEST"
stamp=$(date +%Y-%m-%d_%H%M)
out="$DEST/vaultwarden-$stamp.tar.gz"
part="$out.part"
trap 'rm -f "$part" "$ERRF"' EXIT

# Online backup, tar the data without the live DB, then delete the snapshot on the Pi
STEP="Snapshot on the Pi"
ssh -o BatchMode=yes -o ConnectTimeout=15 "$PI" 'docker exec vaultwarden sh -euc "
  rm -f /data/db_*.sqlite3
  /vaultwarden backup >&2
  tar -C /data -czf - --exclude=./db.sqlite3 --exclude=./db.sqlite3-wal --exclude=./db.sqlite3-shm \
      --exclude=./icon_cache --exclude=./tmp .
  rm -f /data/db_*.sqlite3
"' > "$part"

STEP="Archive check"
listing=$(tar -tzf "$part")
grep -qE '^\./db_[0-9_]+\.sqlite3$' <<<"$listing" || fail "no database snapshot in archive"
grep -qx './rsa_key.pem' <<<"$listing" || fail "rsa_key.pem missing from archive"

mv "$part" "$out"
find "$DEST" -maxdepth 1 -name 'vaultwarden-*.tar.gz' -mtime +"$KEEP_DAYS" -delete
size=$(du -h "$out" | cut -f1)
echo "$(date -Is) OK $(basename "$out") ($size)"
kuma_push "$KUMA_PUSH_VAULTWARDEN" "OK $(basename "$out") ($size)"
