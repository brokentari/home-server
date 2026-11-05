#!/usr/bin/env bash
# Updates nyx's Debian packages (rebooting if needed), then every Docker stack. Run it from
# another computer: the work runs on nyx in the background and survives a dropped connection.
#
#   scripts/update.sh [--os-only | --containers-only] [--no-reboot] [host]
#   bash <(ssh nyx cat home-server/scripts/update.sh)     # without a clone
#
# Logs on nyx: /var/log/home-update-os.log, ~/.local/state/home-update/containers.log

set -eo pipefail # no `set -u`: bash 3.2 treats empty arrays as unset

HOST=nyx
DO_OS=yes
DO_CONTAINERS=yes
REBOOT=yes

OS_UNIT=home-update-os
OS_LOG=/var/log/home-update-os.log
C_LOG='~/.local/state/home-update/containers.log' # for messages only

usage() {
	cat <<'EOF'
Usage: update.sh [--os-only | --containers-only] [--no-reboot] [host]

Updates nyx's Debian packages (rebooting if needed), then pulls and recreates every Docker
stack in ~/home-server. Run it from another computer; host defaults to "nyx".
EOF
}

while [ $# -gt 0 ]; do
	case $1 in
	--os-only) DO_CONTAINERS=no ;;
	--containers-only) DO_OS=no ;;
	--no-reboot) REBOOT=no ;;
	-h | --help) usage && exit 0 ;;
	-*) echo "unknown option: $1" >&2 && usage >&2 && exit 2 ;;
	*) HOST=$1 ;;
	esac
	shift
done
if [ "$DO_OS" = no ] && [ "$DO_CONTAINERS" = no ]; then
	echo "--os-only and --containers-only together leave nothing to do" >&2
	exit 2
fi

# Runs on nyx, sent over ssh with `declare -f`

# Root, in a transient systemd unit so it doesn't depend on ssh. --with-new-pkgs never removes
# a package; anything that would is kept back.
os_job() {
	set -e
	export DEBIAN_FRONTEND=noninteractive APT_LISTCHANGES_FRONTEND=none
	echo "== apt-get update"
	apt-get -o DPkg::Lock::Timeout=600 update
	echo
	echo "== apt-get upgrade"
	apt-get -y -o DPkg::Lock::Timeout=600 \
		-o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold \
		--with-new-pkgs upgrade
	if [ -e /run/reboot-required ]; then
		echo "== done, reboot needed"
		if [ "$1" = yes ]; then
			echo "== rebooting"
			systemctl reboot
		fi
	else
		echo "== done"
	fi
}

# Every stack, proxy first (same order as the README). Runs as you, detached from ssh.
containers_job() {
	cd "$HOME/home-server" || return 1
	local order="proxy auth media immich cloud gitea firefly apps admin dashboard diun"
	local stacks="" failed="" s f bad i=0
	for s in $order; do
		if [ -f "$s/docker-compose.yml" ]; then stacks="$stacks $s"; fi
	done
	for f in */docker-compose.yml; do # a new stack not in the list above goes last
		s=${f%/docker-compose.yml}
		case " $order " in *" $s "*) ;; *) stacks="$stacks $s" ;; esac
	done

	for s in $stacks; do
		echo
		echo "== $s"
		if ! (cd "$s" &&
			docker compose pull --quiet --ignore-buildable &&
			{ ! grep -qE '^\s+build:' docker-compose.yml || docker compose build --pull; } &&
			docker compose up -d); then
			echo "!! $s failed"
			failed="$failed $s"
		fi
	done

	echo
	echo "== removing old images"
	docker image prune -f | tail -n 1

	echo
	echo "== waiting for health checks"
	while [ -n "$(docker ps -q --filter health=starting)" ] && [ $i -lt 36 ]; do
		sleep 5
		i=$((i + 1))
	done
	bad=$(docker ps -a --format '{{.Names}}  {{.Status}}' |
		grep -E '  (Exited|Created|Restarting|Dead|Paused)|\((unhealthy|health: starting)\)' || true)
	if [ -n "$bad" ]; then
		echo "!! not running or not healthy:"
		echo "$bad" | sed 's/^/   /'
		failed="$failed containers"
	else
		echo "all $(docker ps -q | wc -l) containers running"
	fi
	echo "== done, failed:${failed:- none}"
}

start_containers() {
	mkdir -p "$HU_DIR"
	setsid -f flock "$HU_DIR/containers.lock" bash -c "$(declare -f containers_job); containers_job" \
		>"$HU_DIR/containers.log" 2>&1 </dev/null
	local i=0 # wait until it holds the lock, so the first poll sees it running
	while flock -n "$HU_DIR/containers.lock" true && [ $i -lt 50 ]; do
		sleep 0.1
		i=$((i + 1))
	done
}

job_state() { # which update is running: os, containers or idle
	if systemctl is-active --quiet "$OS_UNIT"; then
		echo os
	elif [ -e "$HU_DIR/containers.lock" ] && ! flock -n "$HU_DIR/containers.lock" true; then
		echo containers
	else
		echo idle
	fi
}

poll() { # $1: os|containers, $2: bytes of its log already shown. Prints running|stopped, then the rest.
	local log=$OS_LOG
	if [ "$1" = containers ]; then log=$HU_DIR/containers.log; fi
	if [ "$(job_state)" = "$1" ]; then echo running; else echo stopped; fi
	tail -c +$(($2 + 1)) "$log" 2>/dev/null || true
}

REMOTE="OS_UNIT=$OS_UNIT; OS_LOG=$OS_LOG; HU_DIR=\$HOME/.local/state/home-update
$(declare -f os_job containers_job start_containers job_state poll)"

# Everything from here runs on this computer.

TMP=$(mktemp -d "${TMPDIR:-/tmp}/home-update.XXXXXX")
# One shared connection (so polling every 2s doesn't reconnect), dropped quickly when nyx goes away.
SSH_OPTS=(-o ControlMaster=auto -o "ControlPath=$TMP/ssh" -o ControlPersist=60
	-o ConnectTimeout=10 -o ServerAliveInterval=5 -o ServerAliveCountMax=3)

cleanup() {
	ssh -o "ControlPath=$TMP/ssh" -O exit "$HOST" >/dev/null 2>&1 || true
	rm -rf "$TMP"
}
trap cleanup EXIT
trap 'echo; echo "Stopped watching. Whatever already started keeps running on $HOST. Logs there:";
	echo "  $OS_LOG"; echo "  $C_LOG"; exit 130' INT

rcall() { ssh -n "${SSH_OPTS[@]}" "$HOST" "$REMOTE
$*"; } # -n: leave the keyboard alone

if [ -t 1 ]; then B=$(printf '\033[1m') N=$(printf '\033[0m'); else B="" N=""; fi
say() { printf '\n%s==> %s%s\n' "$B" "$*" "$N"; }
die() {
	printf '\nerror: %s\n' "$*" >&2
	exit 1
}

# Shows a job's log as it grows, until the job stops. Rides out dropped connections and reboots.
follow() { # $1: os|containers
	local off=0 n state lost=""
	: >"$TMP/$1.log"
	while true; do
		if rcall poll "$1" "$off" >"$TMP/chunk" 2>/dev/null; then
			if [ -n "$lost" ]; then
				echo "   (reconnected)"
				lost=""
			fi
			state=$(head -n 1 "$TMP/chunk")
			tail -n +2 "$TMP/chunk" | tee -a "$TMP/$1.log"
			n=$(tail -n +2 "$TMP/chunk" | wc -c)
			off=$((off + n))
			[ "$state" = running ] || return 0
		elif [ -z "$lost" ]; then
			lost=$SECONDS
			echo "   (no connection to $HOST, retrying...)"
		elif [ $((SECONDS - lost)) -gt 1800 ]; then
			die "no connection to $HOST for 30 minutes. The update may still be running there."
		fi
		sleep 2
	done
}

wait_for_reboot() { # $1: boot id from before
	local start=$SECONDS id
	printf 'waiting for %s to come back' "$HOST"
	while true; do
		id=$(rcall 'cat /proc/sys/kernel/random/boot_id' 2>/dev/null) || id=""
		if [ -n "$id" ] && [ "$id" != "$1" ]; then break; fi
		if [ $((SECONDS - start)) -gt 900 ]; then
			echo
			die "$HOST isn't back after 15 minutes"
		fi
		printf '.'
		sleep 5
	done
	echo " back after $((SECONDS - start))s"
}

wait_for_docker() { # Docker waits for /mnt/storage after a boot, and restarts when its package updates
	local start=$SECONDS
	until rcall 'systemctl is-active --quiet docker && docker info >/dev/null 2>&1' 2>/dev/null; do
		if [ $((SECONDS - start)) -gt 600 ]; then
			die "Docker isn't up on $HOST after 10 minutes (is /mnt/storage mounted?)"
		fi
		sleep 5
	done
}

say "Connecting to $HOST"
read -r NAME BOOT_ID < <(rcall 'echo "$(hostname) $(cat /proc/sys/kernel/random/boot_id)"') ||
	die "can't ssh to $HOST"
if [ "$DO_OS" = yes ] && [ "$REBOOT" = yes ] && [ -r /proc/sys/kernel/random/boot_id ] &&
	[ "$(cat /proc/sys/kernel/random/boot_id)" = "$BOOT_ID" ]; then
	die "this is $NAME itself, and it may reboot. Run this from another computer, or add --no-reboot."
fi
busy=$(rcall job_state) || die "lost the connection to $HOST"
[ "$busy" = idle ] || die "an update is already running on $NAME ($busy). Logs: $OS_LOG, $C_LOG"
echo "connected to $NAME"

if [ "$DO_OS" = yes ]; then
	say "Debian packages"
	ssh -t "${SSH_OPTS[@]}" "$HOST" "sudo -p '[sudo] password for %u on %h: ' systemd-run --quiet \
		--collect --unit=$OS_UNIT --expand-environment=no -p StandardOutput=truncate:$OS_LOG \
		/bin/bash -c $(printf %q "$(declare -f os_job); os_job $REBOOT")" ||
		die "couldn't start the package update"
	follow os
	grep -q '^== done' "$TMP/os.log" ||
		die "the package update failed (log: $OS_LOG on $NAME). Containers weren't touched."
	if grep -q '^== rebooting' "$TMP/os.log"; then
		say "Rebooting $NAME"
		wait_for_reboot "$BOOT_ID"
	fi
fi

if [ "$DO_CONTAINERS" = yes ]; then
	say "Docker stacks"
	wait_for_docker
	rcall start_containers || die "couldn't start the container update"
	follow containers
fi

say "Summary"
status=0
if [ "$DO_OS" = yes ]; then
	if grep -q '^== rebooting' "$TMP/os.log"; then
		echo "packages: updated, rebooted (kernel $(rcall 'uname -r'))"
	elif grep -q '^== done, reboot needed' "$TMP/os.log"; then
		echo "packages: updated; a reboot is still needed (sudo reboot on $NAME)"
	else
		echo "packages: updated, no reboot needed"
	fi
	if grep -q 'kept back' "$TMP/os.log"; then
		echo "          some were kept back; run 'sudo apt full-upgrade' on $NAME to see why"
	fi
fi
if [ "$DO_CONTAINERS" = yes ]; then
	if grep -q '^== done, failed: none' "$TMP/containers.log"; then
		echo "containers: all stacks updated, everything running"
	elif grep -q '^== done' "$TMP/containers.log"; then
		echo "containers: problems with$(sed -n 's/^== done, failed://p' "$TMP/containers.log") (see above)"
		status=1
	else
		echo "containers: the update stopped early (log: $C_LOG on $NAME)"
		status=1
	fi
	if grep -q -E 'toomanyrequests|429 Too Many Requests' "$TMP/containers.log"; then
		echo "            Docker Hub's rate limit was hit. 'docker login' on $NAME (free account) raises it;"
		echo "            then run again with --containers-only."
	fi
fi
exit $status
