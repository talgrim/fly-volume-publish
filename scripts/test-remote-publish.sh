#!/usr/bin/env bash
# Tests scripts/remote-publish.sh in a throwaway alpine container (same busybox as the Fly
# machine). Touches only a temp dir. Usage: ./scripts/test-remote-publish.sh
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/vol"
cp "$here/remote-publish.sh" "$tmp/rp.sh"

cat >"$tmp/inner.sh" <<'EOF'
set -eu
export FILES_DIR=/vol
cd /vol
S=/rp.sh
fails=0
check() { # description, command...
    desc=$1; shift
    if "$@" >/dev/null 2>&1; then echo "ok   $desc"; else echo "FAIL $desc"; fails=$((fails + 1)); fi
}
stage() { mkdir -p .incoming; head -c "$2" /dev/urandom >".incoming/$1"; }
link_is() { [ "$(readlink "$1")" = "$2" ]; }
fails_with() { set +e; "$@" >/dev/null 2>&1; rc=$?; set -e; [ "$rc" -ne 0 ]; }

# a volume like the live one
head -c 3000 /dev/urandom >anivision-1.1.0.apk;                 ln -s anivision-1.1.0.apk anivision-latest.apk
head -c 1000 /dev/urandom >homecursor-1.0.0.apk
head -c 1000 /dev/urandom >homecursor-1.1.0.apk;                ln -s homecursor-1.1.0.apk homecursor-latest.apk
head -c 5000 /dev/urandom >homecursor-host-1.0.0-win-x64.zip
head -c 5000 /dev/urandom >homecursor-host-1.1.0-win-x64.zip;   ln -s homecursor-host-1.1.0-win-x64.zip homecursor-host-latest-win-x64.zip

sh $S reindex
check "reindex writes manifest.json"            test -s manifest.json
check "manifest has 5 files"                    test "$(grep -o '"product"' manifest.json | wc -l)" -eq 5
check "manifest marks homecursor 1.1.0 latest"  grep -q '"file":"homecursor-1.1.0.apk","size":1000,"updated":"[0-9-]*","sha256":"[0-9a-f]*","latest":true' manifest.json
check "homecursor does not swallow the host zip" test "$(grep -o '"product":"homecursor"' manifest.json | wc -l)" -eq 2
check "reindex adds checksums"                  test -f anivision-1.1.0.apk.sha256

stage homecursor-1.2.0.apk 1500
sh $S publish homecursor 1.2.0 .apk /vol/.incoming/homecursor-1.2.0.apk
check "publish stores the file"                 test "$(stat -c %s homecursor-1.2.0.apk)" -eq 1500
check "latest moves to 1.2.0"                   link_is homecursor-latest.apk homecursor-1.2.0.apk
check "staged file is gone"                     test ! -e .incoming/homecursor-1.2.0.apk

stage homecursor-1.10.0.apk 1600
sh $S publish homecursor 1.10.0 .apk /vol/.incoming/homecursor-1.10.0.apk
check "1.10.0 sorts above 1.2.0"                link_is homecursor-latest.apk homecursor-1.10.0.apk

stage homecursor-1.2.0.apk 1500
sh $S publish homecursor 1.2.0 .apk /vol/.incoming/homecursor-1.2.0.apk
check "rebuilding an old version keeps latest"  link_is homecursor-latest.apk homecursor-1.10.0.apk

stage homecursor-1.11.0.apk 1700
KEEP=2 sh $S publish homecursor 1.11.0 .apk /vol/.incoming/homecursor-1.11.0.apk
check "prune keeps the newest two"              test -f homecursor-1.11.0.apk -a -f homecursor-1.10.0.apk
check "prune removes older versions"            test ! -e homecursor-1.0.0.apk -a ! -e homecursor-1.2.0.apk
check "prune removes their checksums"           test ! -e homecursor-1.2.0.apk.sha256
check "other products are untouched"            test -f anivision-1.1.0.apk -a -f homecursor-host-1.0.0-win-x64.zip
check "latest points at the newest"             link_is homecursor-latest.apk homecursor-1.11.0.apk
check "sha256 file matches"                     sh -c 'cd /vol && sha256sum -c homecursor-1.11.0.apk.sha256'
check "manifest is rewritten"                   grep -q '"file":"homecursor-1.11.0.apk".*"latest":true' manifest.json

stage homecursor-host-1.2.0-win-x64.zip 6000
sh $S publish homecursor-host 1.2.0 -win-x64.zip /vol/.incoming/homecursor-host-1.2.0-win-x64.zip
check "suffix with a dash works"                link_is homecursor-host-latest-win-x64.zip homecursor-host-1.2.0-win-x64.zip

check "bad product is rejected"                 fails_with sh $S publish Bad 1.0.0 .apk /vol/.incoming/x
check "bad version is rejected"                 fails_with sh $S publish ok 1.0 .apk /vol/.incoming/x
check "suffix without a dot is rejected"        fails_with sh $S publish ok 1.0.0 apk /vol/.incoming/x
check "path tricks are rejected"                fails_with sh $S publish ok 1.0.0 .apk /vol/.incoming/../x
check "staging outside .incoming is rejected"   fails_with sh $S publish ok 1.0.0 .apk /etc/passwd
check "lock is released"                        test ! -e .lock

echo; echo "manifest.json:"; cat manifest.json; echo
[ "$fails" -eq 0 ] && echo "ALL PASSED" || { echo "$fails FAILED"; exit 1; }
EOF

if [ "${1:-}" = "--on-machine" ]; then
    # The most faithful run: the real busybox on the Fly machine, in /tmp (never /srv/files).
    : "${FLY_APP:?set FLY_APP}"; : "${PUBLISH_URL:?set PUBLISH_URL}"; APP="$FLY_APP"
    if command -v fly >/dev/null 2>&1; then FLY=fly
    elif command -v flyctl >/dev/null 2>&1; then FLY=flyctl
    else FLY=fly.exe; fi
    lp() { if [ "$FLY" = fly.exe ]; then wslpath -w "$1"; else printf '%s' "$1"; fi; }
    sed -e "s#/vol#/tmp/fvp-test/vol#g; s#/rp.sh#/tmp/fvp-test/rp.sh#g" "$tmp/inner.sh" >"$tmp/inner-remote.sh"
    curl -fsS -m 30 -o /dev/null "${PUBLISH_URL%/}${HEALTH_PATH:-/health}"   # wakes the machine
    "$FLY" ssh console -a "$APP" -C "sh -c 'rm -rf /tmp/fvp-test && mkdir -p /tmp/fvp-test/vol'"
    "$FLY" ssh sftp put "$(lp "$tmp/rp.sh")" /tmp/fvp-test/rp.sh -a "$APP"
    "$FLY" ssh sftp put "$(lp "$tmp/inner-remote.sh")" /tmp/fvp-test/inner.sh -a "$APP"
    rc=0
    "$FLY" ssh console -a "$APP" -C "sh /tmp/fvp-test/inner.sh" || rc=$?
    "$FLY" ssh console -a "$APP" -C "sh -c 'rm -rf /tmp/fvp-test'" || true
    exit "$rc"
elif docker info >/dev/null 2>&1; then
    docker run --rm -v "$tmp/vol:/vol" -v "$tmp/rp.sh:/rp.sh:ro" -v "$tmp/inner.sh:/t.sh:ro" alpine:3.21 sh /t.sh
else
    echo "docker is not available: running with this machine's sh and coreutils (less faithful than busybox)"
    sed -e "s#/vol#$tmp/vol#g; s#/rp.sh#$tmp/rp.sh#g" "$tmp/inner.sh" | sh
fi
