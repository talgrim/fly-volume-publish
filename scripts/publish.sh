#!/usr/bin/env bash
# Publish a build to a Fly.io volume that nginx serves, from CI or from your own machine.
#
#   FLY_APP=my-files PUBLISH_URL=https://files.example.com \
#     ./scripts/publish.sh <file> <product> <version> <suffix>
#   ... ./scripts/publish.sh app-release.apk myapp 1.2.0 .apk
#   ... ./scripts/publish.sh MyApp-win-x64.zip myapp-host 1.2.0 -win-x64.zip
#   ... ./scripts/publish.sh --reindex          # rebuild manifest.json + checksums from the volume
#
# The file is stored as <files dir>/<product>-<version><suffix>; <product>-latest<suffix> points at
# it unless a newer version exists, old versions are pruned and manifest.json is rewritten.
# See README.md for the rules and the manifest format.
#
# Needs flyctl logged in, or FLY_API_TOKEN set (`fly tokens create ssh -a <app>`).
# Env:
#   FLY_APP       (required) the Fly app that owns the volume
#   PUBLISH_URL   (required) public base URL of that app, no trailing slash
#   FILES_DIR     where the volume is mounted on the machine (default /srv/files)
#   URL_PATH      URL path under which nginx serves FILES_DIR (default /files)
#   HEALTH_PATH   an always-200 path used to wake a stopped machine (default /health)
#   KEEP          versions to keep per product (default 3)
set -euo pipefail

: "${FLY_APP:?set FLY_APP to the Fly app that owns the volume}"
: "${PUBLISH_URL:?set PUBLISH_URL to the public base URL, e.g. https://files.example.com}"
APP="$FLY_APP"
BASE="${PUBLISH_URL%/}"
FILES_DIR="${FILES_DIR:-/srv/files}"
URL_PATH="${URL_PATH:-/files}"
HEALTH_PATH="${HEALTH_PATH:-/health}"
KEEP="${KEEP:-3}"
here="$(cd "$(dirname "$0")" && pwd)"

# These end up inside a remote command line, so only plain values are accepted.
[[ "$FILES_DIR" =~ ^/[A-Za-z0-9._/-]+$ ]] || { echo "bad FILES_DIR: $FILES_DIR" >&2; exit 1; }
[[ "$URL_PATH" =~ ^/[A-Za-z0-9._/-]*$ ]] || { echo "bad URL_PATH: $URL_PATH" >&2; exit 1; }
[[ "$HEALTH_PATH" =~ ^/[A-Za-z0-9._/-]*$ ]] || { echo "bad HEALTH_PATH: $HEALTH_PATH" >&2; exit 1; }
[[ "$KEEP" =~ ^[0-9]+$ ]] && [ "$KEEP" -ge 1 ] || { echo "bad KEEP: $KEEP" >&2; exit 1; }
[[ "$APP" =~ ^[a-z0-9][a-z0-9-]*$ ]] || { echo "bad FLY_APP: $APP" >&2; exit 1; }
URL_PATH="${URL_PATH%/}"

reindex_only=0
if [ "${1:-}" = "--reindex" ] && [ $# -eq 1 ]; then
    reindex_only=1
elif [ $# -ne 4 ] || [ ! -f "$1" ]; then
    echo "usage: $0 <file> <product> <version> <suffix>   |   $0 --reindex" >&2
    exit 1
fi

if [ "$reindex_only" -eq 0 ]; then
    file="$1" product="$2" version="$3" suffix="$4"
    name="$product-$version$suffix"

    # Same rules as remote-publish.sh, checked early so a typo fails before anything is uploaded.
    [[ "$product" =~ ^[a-z0-9]+(-[a-z0-9]+)*$ ]] || { echo "bad product: $product" >&2; exit 1; }
    [[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "bad version: $version (x.y.z only)" >&2; exit 1; }
    [[ "$suffix" =~ ^[.-][A-Za-z0-9._-]*[A-Za-z0-9]$ ]] || { echo "bad suffix: $suffix" >&2; exit 1; }
fi

# Under WSL only the Windows flyctl may be installed
if command -v fly >/dev/null 2>&1; then FLY=fly
elif command -v flyctl >/dev/null 2>&1; then FLY=flyctl
elif command -v fly.exe >/dev/null 2>&1; then FLY=fly.exe
else echo "flyctl not found (fly / flyctl / fly.exe)" >&2; exit 1
fi

local_path() { # fly.exe needs Windows paths
    if [ "$FLY" = fly.exe ]; then wslpath -w "$1"; else printf '%s' "$1"; fi
}

retry() { # retry <attempts> <command...>
    local attempts=$1 i=1; shift
    until "$@"; do
        [ "$i" -lt "$attempts" ] || return 1
        echo "  attempt $i/$attempts failed, retrying in 10s" >&2
        i=$((i + 1)); sleep 10
    done
}

ssh_run() { "$FLY" ssh console -a "$APP" -C "sh -c '$1'"; }
remote_env="FILES_DIR=$FILES_DIR KEEP=$KEEP"

# A stopped machine is NOT started by `fly ssh`; an HTTP request through the Fly proxy is.
echo "waking $BASE ..."
retry 6 curl -fsS -m 30 -o /dev/null "$BASE$HEALTH_PATH"

if [ "$reindex_only" -eq 1 ]; then
    retry 5 ssh_run "rm -f /tmp/remote-publish.sh"
    retry 3 "$FLY" ssh sftp put "$(local_path "$here/remote-publish.sh")" /tmp/remote-publish.sh -a "$APP"
    ssh_run "$remote_env sh /tmp/remote-publish.sh reindex"
    exit 0
fi

echo "preparing the staging area ..."
retry 5 ssh_run "mkdir -p $FILES_DIR/.incoming && rm -f $FILES_DIR/.incoming/$name /tmp/remote-publish.sh"

size="$(stat -c %s "$file" 2>/dev/null || wc -c <"$file")"
echo "uploading $name ($size bytes) ..."
retry 3 "$FLY" ssh sftp put "$(local_path "$file")" "$FILES_DIR/.incoming/$name" -a "$APP"
retry 3 "$FLY" ssh sftp put "$(local_path "$here/remote-publish.sh")" /tmp/remote-publish.sh -a "$APP"

echo "publishing ..."
log="$(mktemp)"
trap 'rm -f "$log"' EXIT
ssh_run "$remote_env sh /tmp/remote-publish.sh publish $product $version $suffix $FILES_DIR/.incoming/$name" 2>&1 | tee "$log"

served_size() { curl -fsSIL -m 60 "$1" | tr -d '\r' | awk 'tolower($1)=="content-length:" {v=$2} END {print v}'; }

# Check what the world sees, not what we think we did.
echo "verifying $BASE$URL_PATH/$name ..."
got="$(served_size "$BASE$URL_PATH/$name")"
[ "$got" = "$size" ] || { echo "FAILED: served $got bytes, expected $size" >&2; exit 1; }

if grep -q "^latest -> $name" "$log"; then
    got="$(served_size "$BASE$URL_PATH/$product-latest$suffix")"
    [ "$got" = "$size" ] || { echo "FAILED: latest link serves $got bytes, expected $size" >&2; exit 1; }
    echo "latest OK: $BASE$URL_PATH/$product-latest$suffix"
fi
echo "done: $BASE$URL_PATH/$name"
