#!/usr/bin/env bash
# Mailroom bootstrap (F37). Small and stable: no secrets, no application code.
# Publish it anywhere (a public repository, a gist, or upload it with SFTP).
#
#   sudo bash install.sh
#   curl -fsSL <public-url>/install.sh | sudo bash
#
# It checks the system, installs Docker from Docker's official apt repository
# when needed, logs in to ghcr.io with a download token read from hidden input
# (passed only on stdin), pulls the chosen version, records its digest, takes
# the versioned installer out of that image and runs it.
#
# Unattended use (CI rehearsal): MAILROOM_NONINTERACTIVE=1 with
# MAILROOM_REGISTRY_USER, MAILROOM_VERSION and MAILROOM_REGISTRY_TOKEN_FILE
# (path to a mode-600 file holding the token; never a variable or argument).
# A missing answer stops with a reason (docs/INSTALL.md "Unattended answers").
set -euo pipefail

BOOTSTRAP_VERSION=1
IMAGE="ghcr.io/liroodgoran10/mailroom"
# Release entry uses include, !reset and !override: !override needs Compose 2.24.4.
MIN_COMPOSE="2.24.4"
MIN_DISK_GIB=15
ROOT=/opt/mailroom

say() { printf '%s\n' "$*"; }
REASON_SHOWN=0 FAIL_LINE="?" FAIL_CMD="?"
fail() { REASON_SHOWN=1; printf 'STOPPED (bootstrap, %s): %s\n' "$STEP" "$*" >&2; exit 1; }
STEP="start"
# Fix-up 3: a set -e exit never goes unexplained (see the installer).
trap 'FAIL_LINE=$LINENO FAIL_CMD=$BASH_COMMAND' ERR
trap 'rc=$?; [ $rc -eq 0 ] || [ "$REASON_SHOWN" = 1 ] || printf '"'"'STOPPED (bootstrap, %s): checked the command on bootstrap line %s (%s); found it failed with exit code %s and printed no reason of its own; do: read the lines just above, fix that, and run the same command again.\n'"'"' "$STEP" "$FAIL_LINE" "$FAIL_CMD" "$rc" >&2' EXIT
NONINTERACTIVE="${MAILROOM_NONINTERACTIVE:-0}"
# When piped through curl, stdin is the script: read answers from the terminal.
TTY=/dev/tty
[ "$NONINTERACTIVE" = 1 ] || [ -r "$TTY" ] || fail "no terminal to ask questions on. Run: sudo bash install.sh"

answer() { # answer VAR ENVNAME "question" [hidden] — ENVNAME answers unattended
  local __v="$1" env="$2" q="$3" hidden="${4:-}" ans="${!2:-}"
  if [ -z "$ans" ]; then
    [ "$NONINTERACTIVE" != 1 ] || fail "checked the answer to \"$q\"; found $env is not set in this unattended run; do: set $env and run again."
    if [ -n "$hidden" ]; then read -r -s -p "$q" ans <"$TTY" || true; printf '\n' >&2; else read -r -p "$q" ans <"$TTY" || true; fi
  fi
  printf -v "$__v" '%s' "$ans"
}

version_ge() { [ "$(printf '%s\n%s\n' "$2" "$1" | sort -V | head -n1)" = "$2" ]; }

say "Mailroom bootstrap version $BOOTSTRAP_VERSION"

STEP="system check"
[ "$(id -u)" -eq 0 ] || fail "run it as root: sudo bash install.sh"
. /etc/os-release
[ "${ID:-}" = ubuntu ] && [ "${VERSION_ID:-}" = "24.04" ] || fail "this installer supports Ubuntu 24.04 LTS only (found ${PRETTY_NAME:-unknown})."
arch="$(uname -m)"
[ "$arch" = x86_64 ] || fail "the Mailroom image is built for x86_64 (amd64) only; this server is $arch. Choose an x86_64 (Intel/AMD) plan."
free_gib=$(( $(df -Pk / | awk 'NR==2{print $4}') / 1024 / 1024 ))
[ "$free_gib" -ge "$MIN_DISK_GIB" ] || fail "only ${free_gib} GiB free on /; at least ${MIN_DISK_GIB} GiB is needed."
getent hosts ghcr.io >/dev/null || fail "cannot resolve ghcr.io: check the server's network and DNS."
curl -fsS -o /dev/null --max-time 15 https://ghcr.io/v2/ 2>/dev/null || curl -sS -o /dev/null --max-time 15 https://ghcr.io/v2/ || fail "cannot reach https://ghcr.io: check outbound HTTPS."
say "OK  Ubuntu 24.04, x86_64, ${free_gib} GiB free, network reachable"

STEP="Docker"
have_compose() { docker compose version --short 2>/dev/null | sed 's/^v//'; }
cv="$(command -v docker >/dev/null && have_compose || true)"
if [ -n "$cv" ] && version_ge "$cv" "$MIN_COMPOSE"; then
  say "OK  Docker already installed (Compose $cv)"
else
  say "..  Installing Docker Engine and the Compose plugin from Docker's apt repository"
  # https://docs.docker.com/engine/install/ubuntu/ ("Install using the apt repository")
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -q
  apt-get install -y -q ca-certificates curl
  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
  chmod a+r /etc/apt/keyrings/docker.asc
  cat > /etc/apt/sources.list.d/docker.sources <<EOF
Types: deb
URIs: https://download.docker.com/linux/ubuntu
Suites: ${UBUNTU_CODENAME:-$VERSION_CODENAME}
Components: stable
Signed-By: /etc/apt/keyrings/docker.asc
EOF
  apt-get update -q
  apt-get install -y -q docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
  systemctl enable --now docker
  cv="$(have_compose)"
  version_ge "$cv" "$MIN_COMPOSE" || fail "Docker Compose $cv is older than $MIN_COMPOSE."
  say "OK  Docker installed (Compose $cv)"
fi

STEP="questions"
answer REG_USER MAILROOM_REGISTRY_USER "GitHub username for the download token: "
answer VERSION MAILROOM_VERSION "Version to install (for example v1.14.0): "
if [[ ! "$VERSION" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  # The CI rehearsal installs the verified sha-<commit> image; nowhere else.
  [ "${MAILROOM_REHEARSAL:-0}" = 1 ] && [[ "$VERSION" =~ ^sha-[0-9a-f]{40}$ ]] \
    || fail "the version must look like v1.14.0 (lowercase v, three numbers). There is no 'latest'."
fi
[ -n "$REG_USER" ] || fail "no GitHub username given."

STEP="registry login"
install -d -m 700 "$ROOT" "$ROOT/.docker"
export DOCKER_CONFIG="$ROOT/.docker"
TOKEN=""
if [ -n "${MAILROOM_REGISTRY_TOKEN_FILE:-}" ]; then
  [ -r "$MAILROOM_REGISTRY_TOKEN_FILE" ] && [ -s "$MAILROOM_REGISTRY_TOKEN_FILE" ] \
    || fail "checked the token file named by MAILROOM_REGISTRY_TOKEN_FILE; found it missing or empty; do: write the token to it (mode 600) and run again."
  head -n1 "$MAILROOM_REGISTRY_TOKEN_FILE" | docker login ghcr.io --username "$REG_USER" --password-stdin >/dev/null \
    || fail "checked the login to ghcr.io with the token file; found it was refused; do: check the username and that the token has read:packages."
else
  answer TOKEN MAILROOM_REGISTRY_TOKEN_FILE "Download token (read:packages; typing is hidden): " hidden
  [ -n "$TOKEN" ] || fail "checked the download token; found none was given; do: paste a GitHub token with read:packages."
  printf '%s' "$TOKEN" | docker login ghcr.io --username "$REG_USER" --password-stdin >/dev/null \
    || { unset TOKEN; fail "checked the login to ghcr.io; found it was refused; do: check the username and that the token has read:packages."; }
  unset TOKEN
fi
say "OK  logged in to ghcr.io as $REG_USER (credentials kept in $ROOT/.docker, mode 700)"

STEP="pull"
docker pull -q "$IMAGE:$VERSION" >/dev/null || fail "could not pull $IMAGE:$VERSION. Does that version exist, and may this token read it?"
DIGEST="$(docker image inspect --format '{{index .RepoDigests 0}}' "$IMAGE:$VERSION" | sed 's/.*@//')"
[[ "$DIGEST" =~ ^sha256:[0-9a-f]{64}$ ]] || fail "could not read the image digest."
say "OK  pulled $IMAGE:$VERSION ($DIGEST)"

STEP="extract installer"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
cid="$(docker create "$IMAGE@$DIGEST")"
docker cp "$cid:/app/deploy" "$WORK/deploy" >/dev/null
docker rm "$cid" >/dev/null
[ -f "$WORK/deploy/installer/install.sh" ] || fail "this version has no installer (it predates v1.14.0)."
need="$(sed -n 's/^MIN_BOOTSTRAP_VERSION=\([0-9]*\).*/\1/p' "$WORK/deploy/installer/install.sh")"
if [ -n "$need" ] && [ "$need" -gt "$BOOTSTRAP_VERSION" ]; then
  fail "this version needs bootstrap version $need or newer; this is version $BOOTSTRAP_VERSION. Download the current install.sh and run it again."
fi

STEP="installer"
export MAILROOM_IMAGE="$IMAGE" MAILROOM_VERSION="$VERSION" MAILROOM_DIGEST="$DIGEST" MAILROOM_DEPLOY_SRC="$WORK/deploy"
bash "$WORK/deploy/installer/install.sh"
