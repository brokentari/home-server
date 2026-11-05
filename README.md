# home-server

Docker Compose configs for nyx, my home server. One Compose project per folder. `media/` is a
separate private repo.

| Folder | Apps | URL |
|---|---|---|
| `proxy/` | Caddy, one wildcard cert via Cloudflare DNS-01 | - |
| `media/` | Jellyfin and friends (private repo) | `media.` |
| `immich/` | Immich | `photos.` |
| `cloud/` | ownCloud Infinite Scale | `cloud.` |
| `dashboard/` | Homepage | `home.` |
| `gitea/` | Gitea, MySQL, Actions runner | `git.` |
| `firefly/` | Firefly III and its data importer | `firefly.`, `importer.` |
| `apps/` | Vikunja, Kavita, Speedtest Tracker | `todo.`, `kavita.`, `speed.` |
| `auth/` | Authelia | `auth.` |
| `admin/` | Dozzle, Scrutiny, Backrest | `logs.`, `disks.`, `backups.` |
| `diun/` | Diun | - |
| `docs/` | [Interactive map](https://brokentari.github.io/home-server/) | - |
| `scripts/` | Backups, SnapRAID, updates, root setup | - |

The Raspberry Pi (192.168.50.143) runs Vaultwarden (`vw.`), Uptime Kuma (`kuma.`), ntfy
(`ntfy.`), AdGuard Home (`adguard.`) and Diun. nyx reaches it over SSH with passwordless sudo.

Only configs are tracked. Each `*.env.example` lists a stack's settings without values.

## Storage

```
/mnt/storage/       mergerfs pool (disk1-3) + SnapRAID parity1
├── data/           media (DATA_ROOT); data/media/books is Kavita's library
├── photos/         Immich
├── cloud/          oCIS
└── backups/        Vaultwarden archives, DB dumps, offsite.log
```

Four 2 TB WD drives in a USB enclosure. Configs and databases stay on the NVMe inside each stack
folder; databases never go on mergerfs.

## Setup

```bash
sudo mkdir -p /mnt/storage/{data,photos,cloud,backups}
sudo chown -R 1000:1000 /mnt/storage

# Docker waits for the pool
sudo mkdir -p /etc/systemd/system/docker.service.d
printf '[Unit]\nRequiresMountsFor=/mnt/storage\n' | sudo tee /etc/systemd/system/docker.service.d/storage.conf
sudo systemctl daemon-reload && sudo systemctl restart docker

# arr_network's subnet is fixed: a firewall rule in media/ uses it
docker network create --subnet 172.19.0.0/16 arr_network
docker network create admin_network

for s in proxy auth media immich cloud gitea firefly apps admin dashboard diun; do (cd ~/home-server/$s && docker compose up -d --build); done

sudo bash ~/home-server/scripts/setup-nyx-root.sh
```

## Network

- Each app has a Cloudflare A record (DNS only) for nyx's LAN IP, 192.168.50.144. Both machines
  have DHCP reservations and use ethernet; `sudo ifup wlo1` brings up nyx's Wi-Fi in an emergency.
- No port forwarding. Certificates use DNS-01 and remote access is Tailscale.
- New app: add the A record and a `handle` block in `proxy/Caddyfile`, validate with
  `docker cp proxy/Caddyfile caddy:/tmp/Caddyfile.new && docker exec caddy caddy validate --config /tmp/Caddyfile.new --adapter caddyfile`,
  then `docker restart caddy` (Jellyfin streams drop briefly). `caddy reload` misses edits
  because the Caddyfile is bind-mounted on its own. Apps on the Pi also need an AdGuard rewrite.
- AdGuard on the Pi is the home DNS. It answers `*.saulreyna.com` locally, so names work without
  internet, and passes `me` through to public DNS. Upstream is DoH to Cloudflare and Quad9. Rate
  limiting is off: the default 20 queries/s per /24 dropped lookups.
- nyx and the Pi are both Tailscale subnet routers for `192.168.50.0/24`; either takes over if
  the other drops. Keep `--accept-routes` off on both. It fails on networks that also use
  `192.168.50.x`.

## App notes

- Jellyfin and Immich transcode with QuickSync (QSV).
- Kavita: turn on Folder Watching so new books appear right away.
- oCIS: first login is `admin` with `OCIS_ADMIN_PASSWORD` from `cloud/.env`.
- Gitea: SSH is on port 2222.
- Firefly III: `APP_KEY` in `firefly/firefly.env` encrypts the data. Never change or lose it.
- Email goes through Mailjet (`in-v3.mailjet.com:587`).
- Homepage: tiles come from `dashboard/config/services.yaml` and from `homepage.*` labels on
  containers; keys are in `dashboard/.env`. The home network and Tailscale skip sign-in.

## Authelia

Any app whose Caddy block has `import authelia` needs the `admins` group and 2FA. A health-check
path that must skip sign-in gets its own `handle` in that block.

- Users are in `auth/data/users_database.yml` and reload on edit.
- `auth/secrets/` holds one secret per file. Losing `storage-encryption-key` means registering
  every 2FA device again.
- Sessions live in Redis, so restarts don't sign anyone out.
- 5 wrong passwords in 2 min locks a user for 10 min. Reset 2FA with
  `docker exec authelia authelia storage user webauthn delete <user> --all --config /config/configuration.yml`
  (or `totp delete <user>`).
- OpenID Connect clients: Immich, Gitea, Vikunja. Each app holds `oidc-<app>-secret`; Authelia
  reads the `.digest`. The template filter reads them, so `configuration.yml` must contain no
  other double braces, comments included. New secret:
  `docker run --rm authelia/authelia:4.39.28 authelia crypto hash generate pbkdf2 --variant sha512 --random --random.length 72 --random.charset alphanumeric`.

## Admin tools

Dozzle, Scrutiny and Backrest have no login. They sit behind Authelia on `admin_network`, which
only Caddy and Homepage join, because Backrest can read every secret in the backups.

- Scrutiny reads SMART data at 5:30. Drives are mapped by id in `admin/.env`.
- Backrest browses and restores the restic repo; restores land in `/mnt/storage/restore`.
- Dozzle also shows the Pi's containers through `dozzle-agent` on port 7007.

## Notifications

ntfy on the Pi denies everything by default. Scripts post with a write-only token from
`scripts/notify.env` to `alerts`, `backups`, `disks` or `updates`. Uptime Kuma's push monitors go
down when a backup hasn't reported in 25 h.

## Updates

Diun checks every Saturday at 9:00 and posts to `updates`. It never updates anything.

- One stack: `cd <stack> && docker compose pull && docker compose up -d`. Caddy needs
  `docker compose build --pull` first.
- Everything: run `scripts/update.sh` from another computer, or
  `bash <(ssh nyx cat home-server/scripts/update.sh)`. It upgrades Debian, reboots if needed,
  then pulls and recreates every stack. Options: `--os-only`, `--containers-only`, `--no-reboot`.
- unattended-upgrades installs security updates; kernel updates wait for a reboot.

## Backups

| When | Job | Target |
|---|---|---|
| 3:15 | `backup-vaultwarden.sh` | `/mnt/storage/backups/vaultwarden/`, 30 days |
| 3:30 | `snapraid-nightly.sh` (root, systemd timer) | parity disk |
| 4:30 | `backup-offsite.sh` (restic) | Cloudflare R2 |

- SnapRAID covers a dead drive, not deletions. It won't sync after more than 50 deletions, so
  `sudo snapraid fix -m` can still restore them. After editing the script:
  `sudo install -m 755 ~/home-server/scripts/snapraid-nightly.sh /usr/local/bin/snapraid-nightly`.
- Offsite holds `home-server/`, `/mnt/storage/backups` and Immich's DB dumps, with 7 daily, 5
  weekly and 12 monthly snapshots. It skips media, images and files over 100 MB. The password in
  `scripts/restic-password` is also in Vaultwarden.
- Restore with Backrest, or:
  `set -a; . scripts/restic.env; set +a; restic restore latest --target /tmp/restore --include /mnt/storage/backups/dumps`.
- Vaultwarden: stop it, extract the archive into its data folder, rename `db_*.sqlite3` to
  `db.sqlite3`.
- smartd runs a short test daily and a long one on Saturdays, and alerts to `disks`.
