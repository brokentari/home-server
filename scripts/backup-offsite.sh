#!/usr/bin/env bash
# Nightly restic backup of the small, irreplaceable data to Cloudflare R2 (cron, 4:30, after
# the SnapRAID sync). Pings Uptime Kuma on success, ntfy "backups" on failure.
#
#   /home/saul/home-server        compose files, configs, .env secrets, small app data
#   /mnt/storage/backups          Vaultwarden archives and the dumps below
#   /mnt/storage/photos/backups   Immich's database dumps (not the photos)
# Refreshed in /mnt/storage/backups/dumps first:
#   gitea.sql.gz, firefly.sql.gz  database dumps (live DB folders are excluded)
#   gitea-ssh.tar.gz              Gitea's SSH host keys (root-only in its container)
#   sqlite/                       consistent copies of every SQLite DB under home-server
#   ocis/                         oCIS config, metadata and files (oCIS stopped for a few seconds)
#   pi/                           the Pi's compose file, Caddyfile, .env, Kuma and ntfy databases
# Skipped: media, photos/videos, images, caches, logs, files over 100 MB (restic-excludes.txt,
# plus any <stack>/restic-excludes.txt).
set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=notify.sh
. "$HERE/notify.sh"
set -a
# shellcheck source=/dev/null
. "$HERE/restic.env"
set +a

STAGE=/mnt/storage/backups/dumps
HS=/home/saul/home-server
PI=saul@192.168.50.143
LOG=/mnt/storage/backups/offsite.log
OCIS_STOPPED=0

STEP="Setup"
ERRF=$(mktemp)
exec 2> >(tee -a "$ERRF" >&2)   # keep stderr for the alert text too

# Alert with the failed step and the reason, or else its last error line
fail() {
  local why=${1:-}
  if [ -z "$why" ]; then sleep 0.3; why=$(grep -v '^[[:space:]]*$' "$ERRF" | tail -n 1 | cut -c1-200); fi
  local msg="$STEP failed${why:+: $why}"
  echo "$(date -Is) FAILED: $msg" >&2
  ntfy backups "Offsite backup FAILED" "$msg. Log: $LOG" high warning
  exit 1
}
cleanup() {
  if [ "$OCIS_STOPPED" = 1 ]; then docker start ocis >/dev/null 2>&1 || true; fi
  rm -f "$ERRF"
}
trap 'fail' ERR
trap cleanup EXIT

[ -n "${AWS_ACCESS_KEY_ID:-}" ] && [ -n "${AWS_SECRET_ACCESS_KEY:-}" ] || fail "R2 keys missing in scripts/restic.env"
umask 077
mkdir -p "$STAGE/sqlite" "$STAGE/ocis" "$STAGE/pi"
echo "$(date -Is) start"

# 1) MySQL/MariaDB dumps, kept only if complete
STEP="Gitea database dump"
docker exec gitea-db sh -c 'exec mysqldump -uroot -p"$MYSQL_ROOT_PASSWORD" --single-transaction --routines --triggers --events --no-tablespaces --set-gtid-purged=OFF gitea' \
  2> >(grep -v "Using a password" >&2) | gzip > "$STAGE/gitea.sql.gz.part"
gunzip -c "$STAGE/gitea.sql.gz.part" | tail -1 | grep -q "Dump completed" || fail "dump incomplete"
mv "$STAGE/gitea.sql.gz.part" "$STAGE/gitea.sql.gz"

STEP="Firefly database dump"
docker exec firefly-db sh -c 'exec mariadb-dump -u"$MYSQL_USER" -p"$MYSQL_PASSWORD" --single-transaction --routines --triggers "$MYSQL_DATABASE"' \
  | gzip > "$STAGE/firefly.sql.gz.part"
gunzip -c "$STAGE/firefly.sql.gz.part" | tail -1 | grep -q "Dump completed" || fail "dump incomplete"
mv "$STAGE/firefly.sql.gz.part" "$STAGE/firefly.sql.gz"

# Without these, clients get a "host key changed" warning after a restore
STEP="Gitea SSH key copy"
docker exec gitea tar -C /data -czf - ssh git/.ssh > "$STAGE/gitea-ssh.tar.gz.part"
mv "$STAGE/gitea-ssh.tar.gz.part" "$STAGE/gitea-ssh.tar.gz"

# 2) SQLite online backup API: consistent copies while the apps keep running
STEP="SQLite copies"
python3 -I - "$HS" "$STAGE/sqlite" <<'EOF'
import os, sqlite3, sys
root, dest = sys.argv[1], sys.argv[2]
skip = {os.path.join(root, p) for p in ("gitea/db", "firefly/db", "immich/postgres", "proxy/data", "diun/data",
                                          "admin/scrutiny/influxdb", "admin/backrest/cache")}
copied, unreadable = 0, []
for dp, dns, fns in os.walk(root):
    dns[:] = [d for d in dns if os.path.join(dp, d) not in skip and not d.startswith("cleanup-backup")]
    for fn in fns:
        if not fn.endswith((".db", ".sqlite", ".sqlite3")) or fn.startswith("logs.db"):
            continue
        src = os.path.join(dp, fn)
        try:
            with open(src, "rb") as f:
                if f.read(16) != b"SQLite format 3\x00":
                    continue
        except OSError:
            unreadable.append(src)
            continue
        out = os.path.join(dest, os.path.relpath(src, root))
        os.makedirs(os.path.dirname(out), exist_ok=True)
        s = sqlite3.connect(src, timeout=60)
        d = sqlite3.connect(out + ".part")
        s.backup(d)
        d.close(); s.close()
        os.replace(out + ".part", out)
        copied += 1
print(f"sqlite: {copied} databases copied")
if unreadable:
    sys.exit("unreadable SQLite files: " + ", ".join(unreadable))
EOF

# 3) oCIS has no dump tool: stop it briefly and mirror config, metadata and files
STEP="oCIS copy"
docker stop ocis >/dev/null && OCIS_STOPPED=1
rsync -a --delete --max-size=100M "$HS/cloud/config/" "$STAGE/ocis/config/"
rsync -a --delete --max-size=100M "$HS/cloud/data/" "$STAGE/ocis/data/"
rsync -a --delete --max-size=100M /mnt/storage/cloud/ "$STAGE/ocis/storage-users/"
docker start ocis >/dev/null && OCIS_STOPPED=0

# 4) The Pi: configs and the Kuma and ntfy databases
STEP="Pi config copy"
ssh -o BatchMode=yes -o ConnectTimeout=15 "$PI" 'cd ~/home-server && tar -czf - docker-compose.yaml caddy/Caddyfile .env' > "$STAGE/pi/config.tar.gz.part"
mv "$STAGE/pi/config.tar.gz.part" "$STAGE/pi/config.tar.gz"
ssh -o BatchMode=yes -o ConnectTimeout=15 "$PI" 'sudo python3 - <<"PY"
import sqlite3, tempfile, tarfile, sys, os
tmp = tempfile.mkdtemp()
for src, name in [("/home/saul/home-server/uptime-kuma/data/kuma.db", "kuma.db"),
                  ("/home/saul/home-server/ntfy/user.db", "ntfy-user.db")]:
    s = sqlite3.connect(src, timeout=60); d = sqlite3.connect(os.path.join(tmp, name)); s.backup(d); d.close(); s.close()
with tarfile.open(fileobj=sys.stdout.buffer, mode="w|gz") as t:
    t.add(tmp, arcname="pi-dbs")
PY' > "$STAGE/pi/dbs.tar.gz.part"
mv "$STAGE/pi/dbs.tar.gz.part" "$STAGE/pi/dbs.tar.gz"

# 5) Snapshot to R2
STEP="Upload to R2"
restic unlock >/dev/null 2>&1 || true   # stale locks from an interrupted run
excludes=(--exclude-file "$HERE/restic-excludes.txt")
# Stacks kept in a separate repo can add their own patterns
for f in "$HS"/*/restic-excludes.txt; do
  if [ -f "$f" ] && [ "$f" != "$HERE/restic-excludes.txt" ]; then excludes+=(--exclude-file "$f"); fi
done
out=$(restic backup --tag nightly "${excludes[@]}" --exclude-larger-than 100M \
        "$HS" /mnt/storage/backups /mnt/storage/photos/backups 2>&1) || rc=$?
echo "$out" | grep -vE "^(using parent|open repository|lock repository|load index|start scan|start backup|scan finished|repository [0-9a-f]+ opened)" || true
if [ "${rc:-0}" = 3 ]; then
  ntfy backups "Offsite backup: some files skipped" "restic could not read some files (exit 3). Log: $LOG" default warning
elif [ "${rc:-0}" != 0 ]; then
  fail "restic exited with $rc: $(echo "$out" | grep -v '^[[:space:]]*$' | tail -n 1 | cut -c1-200)"
fi

# 6) Keep 7 daily, 5 weekly, 12 monthly; prune on Sundays
STEP="Retention cleanup"
prune=""; [ "$(date +%u)" = 7 ] && prune="--prune"
restic forget --tag nightly --keep-daily 7 --keep-weekly 5 --keep-monthly 12 $prune --quiet

# 7) Monthly: verify 5% of the stored data
STEP="Monthly integrity check"
if [ "$(date +%d)" = 01 ]; then restic check --read-data-subset=5% --quiet; fi

summary=$(echo "$out" | grep -E "^Added to the repository" | sed 's/^Added to the repository: //' || true)
echo "$(date -Is) OK added: ${summary:-?}"
kuma_push "$KUMA_PUSH_OFFSITE" "OK, added ${summary:-?}"
