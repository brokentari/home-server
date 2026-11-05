# home-server (nyx)

Docker Compose configs for my home server, nyx. One Compose project per folder. Web-facing
containers join the shared `arr_network` so Caddy can reach them by name; the admin tools sit on
a separate `admin_network` that only Caddy and Homepage can reach. `media/` is its own private
repo; this one only has the hooks for it (a Caddy import, Homepage labels, backup excludes).

| Folder    | What                                         | URL                          |
|-----------|----------------------------------------------|------------------------------|
| `proxy/`  | Caddy, one `*.saulreyna.com` cert via Cloudflare DNS-01 | -                 |
| `media/`  | Jellyfin and related apps (separate private repo) | `media.` (Jellyfin)     |
| `immich/` | Immich (photos)                              | `photos.`                    |
| `cloud/`  | ownCloud Infinite Scale (documents)          | `cloud.`                     |
| `dashboard/` | Homepage (landing page with live status)  | `home.` (Authelia from outside) |
| `gitea/`  | Gitea, MySQL, Actions runner (SSH on 2222)   | `git.`                       |
| `firefly/` | Firefly III, MariaDB, Redis, data importer, daily cron | `firefly.`, `importer.` |
| `apps/`   | Vikunja, Kavita, Speedtest Tracker           | `todo.`, `kavita.`, `speed.` |
| `diun/`   | Diun: weekly new-image notices to ntfy       | -                            |
| `auth/`   | Authelia: sign-in (password + 2FA) for apps without their own | `auth.`     |
| `admin/`  | Dozzle (logs), Scrutiny (disk health), Backrest (browse/restore backups), behind Authelia | `logs.`, `disks.`, `backups.` |
| `docs/`   | Interactive map of the setup (GitHub Pages)  | [brokentari.github.io/home-server](https://brokentari.github.io/home-server/) |
| `scripts/` | Backups, SnapRAID job, ntfy helpers, root setup, `update.sh` | -           |

The Raspberry Pi (`raspberrypi`, 192.168.50.143) runs Vaultwarden (`vw.`), Uptime Kuma (`kuma.`,
watching nyx from outside so it still alerts when nyx is down), ntfy (`ntfy.`), AdGuard Home
(`adguard.`, the home DNS) and Diun, behind its own Caddy in `~/home-server` on the Pi. nyx SSHes
to it with `~/.ssh/id_ed25519`; the backup scripts use passwordless sudo there.

Only configs are tracked (allowlist `.gitignore`). Each `*.env.example` lists a stack's settings
with the values removed; the real files are in the offsite backup.

## Storage

```
/mnt/storage/            mergerfs pool (disk1-3), parity1 for SnapRAID
├── data/                media stack (DATA_ROOT); data/media/books is Kavita's library
├── photos/              Immich library and its nightly DB dumps
├── cloud/               oCIS user files
└── backups/             SnapRAID-protected and offsite
    ├── vaultwarden/     nightly Vaultwarden archives from the Pi (30 days) + backup.log
    ├── dumps/           DB dumps, SQLite copies, oCIS mirror, Pi configs (refreshed nightly)
    └── offsite.log      restic log
```

Four 2 TB WD drives in a TerraMaster USB enclosure: `/mnt/disk1-3` data, `/mnt/parity1` parity.

App configs and databases stay on the NVMe inside each stack folder (`*/config`,
`immich/postgres`, `cloud/config`, `cloud/data`, `gitea/db`, `firefly/db`, `apps/*`). Databases
and oCIS metadata must not go on mergerfs.

## Setup on nyx

```bash
# Folders on the pool
sudo mkdir -p /mnt/storage/{data,photos,cloud,backups}
sudo chown -R 1000:1000 /mnt/storage

# Start Docker only after the pool is mounted, so containers never write to the empty mountpoint
sudo mkdir -p /etc/systemd/system/docker.service.d
printf '[Unit]\nRequiresMountsFor=/mnt/storage\n' | sudo tee /etc/systemd/system/docker.service.d/storage.conf
sudo systemctl daemon-reload && sudo systemctl restart docker

# Shared networks. arr_network has a fixed subnet because a firewall rule in media/ refers to it.
docker network create --subnet 172.19.0.0/16 arr_network
docker network create admin_network

# Start everything, proxy first
for s in proxy auth media immich cloud gitea firefly apps admin dashboard diun; do (cd ~/home-server/$s && docker compose up -d --build); done

# Security updates, Tailscale auto-update, Docker log limits, smartd alerts, SnapRAID timer
sudo bash ~/home-server/scripts/setup-nyx-root.sh
```

## DNS and router

- Cloudflare: one A record per app on nyx, pointing at its LAN IP (192.168.50.144), DNS only.
  `vw`, `kuma`, `ntfy` and `adguard` point at the Pi (192.168.50.143).
- Both IPs are DHCP reservations on the router, and both machines are on ethernet with Wi-Fi
  off. nyx uses `enp89s0` (DHCP, `/etc/network/interfaces`); its Wi-Fi stanza is kept with
  `allow-hotplug wlo1` commented out, so `sudo ifup wlo1` brings it up in an emergency (with a
  different address). The Pi has a static address on "Wired connection 1" in NetworkManager
  (gateway .1, DNS .143 and 1.1.1.1) and `nmcli radio wifi off`.
- No port forwarding: certificates use DNS-01 and remote access goes through Tailscale. If 80/443
  were ever forwarded to nyx, remove the forward.
- Adding an app on nyx: create the A record, add a `handle` block to `proxy/Caddyfile`, validate
  with `docker cp proxy/Caddyfile caddy:/tmp/Caddyfile.new && docker exec caddy caddy validate
  --config /tmp/Caddyfile.new --adapter caddyfile`, then `docker restart caddy` (briefly drops
  Jellyfin streams) and add an Uptime Kuma monitor. `caddy reload` doesn't work here: the
  Caddyfile is a single-file bind mount, so the container keeps seeing the old copy after an
  edit. An app on the Pi also needs an AdGuard rewrite to the Pi (Filters > DNS rewrites).

### Home DNS (AdGuard Home on the Pi)

The router hands out the Pi as the DNS server. AdGuard answers `*.saulreyna.com` itself, so home
access keeps working when the internet or Cloudflare is down: `*.saulreyna.com` goes to nyx,
`vw`/`kuma`/`ntfy`/`adguard` to the Pi, and `me` (the personal site on Cloudflare Workers,
github.com/brokentari/personal-page) is passed through to public DNS (a rewrite whose answer is
its own name). The bare domain has no web record (only mail); the old Vercel names `www` and
`hestia` are gone. `asusrouter.com`, `www.asusrouter.com` and `router.asus.com` point at
the router (192.168.50.1). Everything else goes upstream over DNS-over-HTTPS (Cloudflare and
Quad9) with the AdGuard DNS blocklist; query log and stats keep 7 days.

Rate limiting is off (Settings > DNS settings > Rate limit = 0). The default 20 queries/s is per
/24, so the whole home network shared it and busy moments dropped lookups. Kuma's "AdGuard DNS"
monitor alerts if it stops answering. If the Pi is down, devices fall back to the router's
secondary DNS: no ad blocking, but the public records point at the same LAN IPs.

## Remote access (Tailscale)

The Pi and nyx are both Tailscale subnet routers for `192.168.50.0/24` (route approved, key
expiry off). One is active and the other takes over in about 15 s if it goes offline. Any device
on the tailnet can reach the LAN IPs, so every `*.saulreyna.com` address works away from home
with the same certificates. Through the Pi, traffic arrives from a LAN address; through nyx it
keeps the device's `100.x` address. Caddy lets both into Homepage without a sign-in.

- Installed from Tailscale's apt repo and started with
  `sudo tailscale up --advertise-routes=192.168.50.0/24 --hostname=<nyx|raspberrypi>`.
- Leave `--accept-routes` off on nyx and the Pi, or they route their own LAN through each other.
  The "accept-routes is false" health warning is expected.
- Doesn't work from another network that also uses `192.168.50.x` (a common ASUS default).

## App setup

- **Kavita**: turn on Folder Watching (Server Settings > General) so new files show up right away.
- **Jellyfin**: libraries under `/data/media/...`; Playback > Transcoding > Intel QuickSync (QSV).
- **Immich**: Administration > Video Transcoding > Hardware acceleration > QSV.
- **oCIS**: log in as `admin` with `OCIS_ADMIN_PASSWORD` from `cloud/.env`, then change it.
- **Email**: Immich, oCIS, Vikunja, Authelia and Vaultwarden send through Mailjet
  (`in-v3.mailjet.com:587`, STARTTLS). Immich: Administration > Settings > Notification Settings >
  Email (from `photos@`). oCIS: `NOTIFICATIONS_SMTP_*` in `cloud/docker-compose.yml`, login in
  `cloud/.env` (from `cloud@`).
- **Gitea**: git over SSH is port 2222. In `~/.ssh/config`: `Host git.saulreyna.com` /
  `Port 2222`.
- **Firefly III**: `firefly/firefly.env` holds `APP_KEY`, which encrypts the data. Never change or
  lose it. Images are pinned; bump them deliberately.
- **Homepage**: tiles and widgets in `dashboard/config/services.yaml`, API keys in
  `dashboard/.env` (`HOMEPAGE_VAR_*`); edits apply on page reload. Containers in other compose
  projects can add their own tiles with `homepage.*` labels (`weight` sets the order within a
  group). The Jellyfin widget needs `version: 2`. No login of its own: home network and Tailscale
  (`100.64.0.0/10`) go straight in, anyone else signs in with Authelia (admins + 2FA).

## Single sign-on (Authelia) and admin tools

`https://auth.saulreyna.com` (`auth/`). Caddy's `import authelia` (see `proxy/Caddyfile`) sends
anyone not signed in to Authelia first. The rule in `auth/configuration.yml` (default deny)
covers every `*.saulreyna.com` host that imports it: `admins` group and two factors. A health-check
path that has to skip the sign-in gets its own `handle` in that app's Caddy block instead.

It guards the apps with no login of their own and no published port, like the admin tools in
`admin/`: **Dozzle** (`logs.`, read-only container logs), **Scrutiny** (`disks.`) and **Backrest**
(`backups.`). These are on `admin_network` rather than `arr_network`: Backrest has no login and
can read every secret in the backups, and Dozzle trusts the `Remote-User` header, so only Caddy
and Homepage (for the Scrutiny widget) can reach them.
- Users are in `auth/data/users_database.yml` (template `auth/users_database.example.yml`) and
  reload on edit. Change a password with "Reset password" on the sign-in page.
- 2FA: Authelia emails a one-time code to confirm adding a passkey, security key or TOTP app. A
  registered passkey signs in on its own. "Remember me" lasts a month.
- Sessions are in Redis (`authelia-redis`, on a private network only Authelia can reach), so
  restarting Authelia doesn't sign anyone out. `auth/redis/` only holds sessions and is left out
  of the offsite backup.
- `auth/secrets/` holds one secret per file. `storage-encryption-key` encrypts the 2FA devices in
  `data/db.sqlite3`; lose it and every device has to be registered again.
- Locked out: 5 wrong passwords in 2 min locks the user for 10 min. To reset 2FA:
  `docker exec authelia authelia storage user webauthn delete <user> --all --config /config/configuration.yml`
  (or `totp delete <user>`).
- Protecting another app: `import authelia` in its Caddy `handle` block. The wildcard rule
  already covers its hostname.

**OpenID Connect** ("Sign in with Authelia") is set up for Immich, Gitea and Vikunja
(`identity_providers.oidc` in `auth/configuration.yml`). Their password logins still work.
Consent is asked once per app and remembered for a year.

- Secrets in `auth/secrets/`: `oidc-jwks-rsa.key` (signing key), `oidc-hmac-secret`, and per app
  `oidc-<app>-secret` (plain, entered in the app) and `oidc-<app>-secret.digest` (hash, read by
  Authelia). `X_AUTHELIA_CONFIG_FILTERS=template` lets the config read them, so don't put double
  braces anywhere else in `configuration.yml`, comments included.
- Immich: Administration > Settings > Authentication > OAuth (issuer `https://auth.saulreyna.com`,
  client `immich`, auto-register off). Accounts are matched by email. The phone app works too
  (`app.immich:///oauth-callback`). Authelia sends no role, so Immich admin rights don't change.
- Gitea: login source `authelia` (added with `gitea admin auth add-oauth`, client `gitea`). The
  first time, Gitea asks to link it to the existing account. Sign-ups are off, so it can't
  create a second account.
- Vikunja: `apps/vikunja-config.yml` (provider `authelia`, client `vikunja`), mounted as
  `/etc/vikunja/config.yml`, with the secret from `auth/secrets/oidc-vikunja-secret`.
  `emailfallback` signs in to the existing account with the same email. It has to be YAML:
  Vikunja ignores `true` from env vars for that setting.
- Adding an app: generate a client secret and digest with `docker run --rm
  authelia/authelia:4.39.28 authelia crypto hash generate pbkdf2 --variant sha512 --random
  --random.length 72 --random.charset alphanumeric`, add a client under `clients:`, then
  `docker compose up -d` in `auth/`.

**Scrutiny** reads SMART data daily at 5:30 from the four pool drives (mapped by id in
`admin/.env`, `-d sat` in `admin/scrutiny/collector.yaml`) and the NVMe, and sends failures to
ntfy `disks`. smartd still runs the self-tests and temperature alerts. History in
`admin/scrutiny/influxdb` isn't backed up. New drive: add it to `admin/docker-compose.yml`,
`admin/.env` and `collector.yaml`.

**Backrest** uses the same R2 repo and keys as `backup-offsite.sh` (`env_file:
../scripts/restic.env`) but only for browsing and restoring; its own prune/check schedules are
off. Restores go to `/restore` in the container, `/mnt/storage/restore` on nyx.

**Dozzle** shows nyx's containers and the Pi's, through a `dozzle-agent` container on the Pi (port
7007). The agent only accepts clients holding the same certificate (`admin/dozzle/{cert,key}.pem`
on nyx, `~/home-server/dozzle/` on the Pi).

## Notifications (ntfy on the Pi)

`https://ntfy.saulreyna.com`, deny-all by default. One admin user for the phone app; a
`publisher` user that can only post, with its token in `scripts/notify.env` (also used by Kuma and
Diun). Topics: `alerts` (Kuma up/down), `backups` (backup failures), `disks` (smartd, Scrutiny,
SnapRAID), `updates` (Diun and other notices). `NTFY_UPSTREAM_BASE_URL=https://ntfy.sh` gives
instant iOS push; only a poll request goes through ntfy.sh, never the message.

Uptime Kuma sends every monitor's up/down to `alerts`. Its Backups group has push monitors
(Vaultwarden backup, offsite backup, SnapRAID sync) that go down if a job hasn't reported success
within 25 h.

## Updates

Diun (one on nyx, one on the Pi) checks Saturdays at 9:00 and posts to `updates`; it never
updates anything. Images on a moving tag (`latest`, `v3`, `8`) are reported when that tag gets a
new image; pinned versions use `diun.*` labels to report newer version tags. To update one stack:
`cd <stack> && docker compose pull && docker compose up -d` (change a pinned tag first). Caddy is
built locally: `cd proxy && docker compose build --pull && docker compose up -d`.

**Everything at once:** run `scripts/update.sh` from another computer (without a clone there:
`bash <(ssh nyx cat home-server/scripts/update.sh)`). It upgrades the Debian packages, reboots if
needed, waits for nyx to come back, then pulls and recreates every stack (rebuilding Caddy),
prunes old images and lists any container that isn't running or healthy. The work runs on nyx in
the background, so a dropped connection doesn't stop it. Options: `--os-only`,
`--containers-only`, `--no-reboot`. Logs on nyx: `/var/log/home-update-os.log` and
`~/.local/state/home-update/containers.log`.

unattended-upgrades installs security updates on both machines; kernel updates still need a
reboot. Tailscale updates itself.

## Backups

SnapRAID protects against a dead drive, not deletions. `data/downloads/` is excluded from it.

| When | What | Where |
|------|------|-------|
| 3:15 | `scripts/backup-vaultwarden.sh` | `/mnt/storage/backups/vaultwarden/` |
| 3:30 | `scripts/snapraid-nightly.sh` (systemd timer, root) | parity disk |
| 4:30 | `scripts/backup-offsite.sh` (restic) | Cloudflare R2 |

**SnapRAID** (`snapraid-nightly.timer` runs `/usr/local/bin/snapraid-nightly`, a copy of
`scripts/snapraid-nightly.sh`): refuses to sync if more than 50 files were deleted since the last
sync (so `sudo snapraid fix -m` can still bring them back), syncs, scrubs 8% on Sundays, then
checks `snapraid status` for bad blocks. Failures go to ntfy `disks`; success pings Kuma. Last
run: `/var/log/snapraid-nightly.log`. After editing the script:
`sudo install -m 755 ~/home-server/scripts/snapraid-nightly.sh /usr/local/bin/snapraid-nightly`.

**Offsite (restic on R2)** keeps 7 daily, 5 weekly and 12 monthly snapshots (prune on Sundays, 5%
data check on the 1st). It holds `home-server/` (configs, `.env` secrets, small app data),
`/mnt/storage/backups` and Immich's DB dumps. Before each snapshot it refreshes `backups/dumps/`:
Gitea and Firefly SQL dumps, Gitea's SSH host keys, consistent copies of every SQLite DB, a
mirror of oCIS (stopped for a few seconds), and the Pi's configs plus the Kuma and ntfy
databases. It skips media, photos/videos, images, caches, logs and anything over 100 MB
(`scripts/restic-excludes.txt`, plus any `<stack>/restic-excludes.txt`).

- Credentials: `scripts/restic.env` (R2 keys) and `scripts/restic-password`. The password is
  also in Vaultwarden; without it the backups can't be decrypted.
- Browse/restore in a browser with Backrest (`backups.`), or by hand:
  `set -a; . scripts/restic.env; set +a; restic snapshots`, then
  `restic restore latest --target /tmp/restore --include /mnt/storage/backups/dumps`.
- Restoring a stack: copy its folder back, load its SQL dump (`gunzip -c ... | docker exec -i
  <db> mysql ...`) or put the SQLite copy back, then `docker compose up -d`.

**Disks:** smartd runs a short self-test daily at 2:00 and a long one Saturdays at 3:00, and sends
warnings (failing attributes, new bad sectors, over 45°C) to ntfy `disks` through
`/usr/local/bin/smartd-ntfy`. Scrutiny keeps the SMART history.

**Vaultwarden** (on the Pi): `scripts/backup-vaultwarden.sh` runs from cron at 3:15 and writes
`/mnt/storage/backups/vaultwarden/vaultwarden-<date>.tar.gz` (kept 30 days, log in `backup.log`).
Each archive has a consistent DB snapshot (`db_*.sqlite3`), `config.json`, `rsa_key.pem`,
attachments and sends. To restore: stop Vaultwarden, extract into its data folder, rename
`db_*.sqlite3` to `db.sqlite3`, start it.

## Later

- **Drives:** watch disk3's reallocated sector count and replace it first if it grows. Long term,
  two larger modern drives instead of four old ones.
- **UPS** with NUT for clean shutdowns (protects the enclosure's drives and the Pi's SD card).
- **Pi on an SSD** instead of the SD card.
- **Pi's Caddy** is a custom xcaddy binary with no update path. Switch it to the same Docker build
  as `proxy/Dockerfile`.
