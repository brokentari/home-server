#!/usr/bin/env bash
# One-time root setup on nyx, safe to re-run:  sudo bash ~/home-server/scripts/setup-nyx-root.sh
set -euo pipefail
[ "$(id -u)" = 0 ] || { echo "run with sudo"; exit 1; }

echo "== 1. unattended-upgrades"
DEBIAN_FRONTEND=noninteractive apt-get install -y -qq unattended-upgrades >/dev/null
printf 'APT::Periodic::Update-Package-Lists "1";\nAPT::Periodic::Unattended-Upgrade "1";\n' > /etc/apt/apt.conf.d/20auto-upgrades
echo "   security updates install daily (apt-daily-upgrade.timer)"

echo "== 2. tailscale auto-update"
tailscale set --auto-update && echo "   on"

echo "== 3. docker log limits"
want='{
  "log-driver": "json-file",
  "log-opts": { "max-size": "10m", "max-file": "3" }
}'
if [ -f /etc/docker/daemon.json ] && [ "$(cat /etc/docker/daemon.json)" = "$want" ]; then
  echo "   already set"
else
  [ -f /etc/docker/daemon.json ] && cp /etc/docker/daemon.json /etc/docker/daemon.json.bak
  printf '%s\n' "$want" > /etc/docker/daemon.json
  systemctl restart docker && echo "   set; docker restarted"
fi

echo "== 4. smartd alerts"
# Runs as root, so it reads values from saul's notify.env instead of sourcing it
cat > /usr/local/bin/smartd-ntfy <<'EOF'
#!/bin/sh
# smartd "-M exec" hook: disk warnings to ntfy topic "disks". Installed by setup-nyx-root.sh.
env=/home/saul/home-server/scripts/notify.env
val() { sed -n "s/^$1=//p" "$env" 2>/dev/null | tail -n 1; }
curl -fsS -m 20 -H "Authorization: Bearer $(val NTFY_TOKEN)" \
  -H "Title: nyx disk warning: ${SMARTD_DEVICEINFO:-$SMARTD_DEVICE}" -H "Priority: urgent" -H "Tags: rotating_light" \
  -d "${SMARTD_FAILTYPE}: ${SMARTD_MESSAGE}" "$(val NTFY_URL)/disks" >/dev/null
EOF
chmod 755 /usr/local/bin/smartd-ntfy

conf=/etc/smartd.conf
[ -f "$conf.bak-before-ntfy" ] || cp "$conf" "$conf.bak-before-ntfy"
# HDDs in the TerraMaster enclosure: keep the existing test schedule, add temperature limits and alerts
sed -i -E '/^\/dev\/disk\/by-id\/usb-TerraMas/{/-M exec/!s|$| -W 4,45,55 -m <nomailer> -M exec /usr/local/bin/smartd-ntfy|}' "$conf"
# System NVMe: health, errors and NVMe temperature limits. By id, skipping the eui./namespace/partition aliases.
nvme=$(ls /dev/disk/by-id/ | grep -E '^nvme-' | grep -vE '^nvme-eui\.|-part[0-9]+$|_[0-9]$' | head -n 1)
if [ -n "$nvme" ]; then
  nvme=/dev/disk/by-id/$nvme
  grep -q "^$nvme " "$conf" || echo "$nvme -a -W 0,70,80 -m <nomailer> -M exec /usr/local/bin/smartd-ntfy" >> "$conf"
fi
grep -E '^/dev/' "$conf" | sed 's/^/   /'
systemctl restart smartmontools && echo "   smartd restarted"

SMARTD_DEVICE=test SMARTD_DEVICEINFO="test" SMARTD_FAILTYPE="Test" \
  SMARTD_MESSAGE="Test alert from setup-nyx-root.sh: smartd alerts from nyx are working." /usr/local/bin/smartd-ntfy \
  && echo "   test alert sent to ntfy topic 'disks'"

echo "== 5. SnapRAID nightly job"
install -m 755 /home/saul/home-server/scripts/snapraid-nightly.sh /usr/local/bin/snapraid-nightly
cat > /etc/systemd/system/snapraid-nightly.service <<'EOF'
[Unit]
Description=SnapRAID nightly sync/scrub
RequiresMountsFor=/mnt/disk1 /mnt/disk2 /mnt/disk3 /mnt/parity1
[Service]
Type=oneshot
ExecStart=/usr/local/bin/snapraid-nightly
Nice=19
IOSchedulingClass=idle
EOF
cat > /etc/systemd/system/snapraid-nightly.timer <<'EOF'
[Timer]
OnCalendar=*-*-* 03:30
Persistent=true
[Install]
WantedBy=timers.target
EOF
systemctl daemon-reload && systemctl enable --now snapraid-nightly.timer >/dev/null 2>&1
echo "   installed; next run: $(systemctl show snapraid-nightly.timer -p NextElapseUSecRealtime --value)"

echo "== done"
