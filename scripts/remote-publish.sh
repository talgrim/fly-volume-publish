#!/bin/sh
# Runs ON the Fly machine (busybox ash, no jq). Shipped and started by scripts/publish.sh.
#
#   remote-publish.sh publish <product> <version> <suffix> <staged-file>
#   remote-publish.sh reindex
#
# File layout in $FILES_DIR (default /srv/files):
#   <product>-<version><suffix>          the build, e.g. homecursor-host-1.2.0-win-x64.zip
#   <product>-<version><suffix>.sha256   checksum next to it
#   <product>-latest<suffix>             relative symlink to the newest version
#   manifest.json                        index of everything above, read by your download page
#   .incoming/                           staging area for uploads (never served)
#
# KEEP (default 3) is how many versions of each product are kept.
set -eu

DIR="${FILES_DIR:-/srv/files}"
KEEP="${KEEP:-3}"
LOCK="$DIR/.lock"

die() { echo "error: $*" >&2; exit 1; }

# Two repos can publish at the same time and GitHub cannot lock across repos, so lock here.
acquire_lock() {
    tries=0
    while ! mkdir "$LOCK" 2>/dev/null; do
        # a lock older than 10 minutes was left behind by a crashed run
        if [ -n "$(find "$LOCK" -maxdepth 0 -mmin +10 2>/dev/null)" ]; then
            rmdir "$LOCK" 2>/dev/null || true
            continue
        fi
        tries=$((tries + 1))
        [ "$tries" -le 60 ] || die "could not get the lock on $DIR"
        sleep 2
    done
    trap 'rmdir "$LOCK" 2>/dev/null || true' EXIT
}

# Versions of one product on disk, oldest first. Only plain x.y.z files count, so
# "homecursor" does not pick up "homecursor-host-1.0.0-win-x64.zip".
versions_of() {
    for f in "$DIR/$1"-*"$2"; do
        { [ -f "$f" ] && [ ! -L "$f" ]; } || continue
        v=${f##*/}
        v=${v#"$1"-}
        v=${v%"$2"}
        if printf '%s\n' "$v" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$'; then
            echo "$v"
        fi
    done | sort -V
}

prune() {
    vs=$(versions_of "$product" "$suffix")
    n=$(printf '%s\n' "$vs" | grep -c . || true)
    [ "$n" -gt "$KEEP" ] || return 0
    latest_target=$(readlink "$DIR/$product-latest$suffix" 2>/dev/null || true)
    printf '%s\n' "$vs" | head -n $((n - KEEP)) | while read -r v; do
        f="$product-$v$suffix"
        [ "$f" != "$latest_target" ] || continue
        rm -f "$DIR/$f" "$DIR/$f.sha256"
        echo "pruned $f"
    done
}

write_manifest() {
    tmp="$DIR/.manifest.$$"
    {
        for f in "$DIR"/*; do
            { [ -f "$f" ] && [ ! -L "$f" ]; } || continue
            name=${f##*/}
            case "$name" in manifest.json | *.sha256) continue ;; esac
            parts=$(printf '%s\n' "$name" |
                sed -nE 's/^(.+)-([0-9]+\.[0-9]+\.[0-9]+)([.-][A-Za-z0-9._-]*)$/\1 \2 \3/p')
            [ -n "$parts" ] || continue
            read -r p v s <<PARTS
$parts
PARTS
            sum=-
            [ ! -f "$f.sha256" ] || sum=$(cut -d' ' -f1 "$f.sha256")
            is_latest=0
            [ "$(readlink "$DIR/$p-latest$s" 2>/dev/null || true)" != "$name" ] || is_latest=1
            echo "$p $v $s $name $(stat -c %s "$f") $(date -u -r "$f" +%Y-%m-%d) $sum $is_latest"
        done
    } |
        # busybox sort has no per-key V flag, so add a zero-padded version as a sort key (field 9)
        awk '{ split($2, v, "."); printf "%s %09d%09d%09d\n", $0, v[1], v[2], v[3] }' |
        sort -k1,1 -k3,3 -k9,9r >"$tmp.rows"
    # (rows go through a file so that a failing sort stops the script instead of writing an empty manifest)
    awk -v gen="$(date -u +%Y-%m-%dT%H:%M:%SZ)" '
        BEGIN { printf "{\"generated\":\"%s\",\"files\":[", gen }
        {
            if (NR > 1) printf ","
            printf "{\"product\":\"%s\",\"version\":\"%s\",\"suffix\":\"%s\",\"file\":\"%s\",\"size\":%s,\"updated\":\"%s\",\"sha256\":\"%s\",\"latest\":%s}",
                $1, $2, $3, $4, $5, $6, ($7 == "-" ? "" : $7), ($8 == 1 ? "true" : "false")
        }
        END { print "]}" }' "$tmp.rows" >"$tmp"
    # never replace a good manifest with an empty one
    if [ "$(wc -l <"$tmp.rows")" -eq 0 ] && find "$DIR" -maxdepth 1 -type f -name '*-[0-9]*.[0-9]*.[0-9]*' | grep -q .; then
        rm -f "$tmp" "$tmp.rows"
        die "manifest would be empty although there are builds; not writing it"
    fi
    rm -f "$tmp.rows"
    chmod 644 "$tmp"
    mv -f "$tmp" "$DIR/manifest.json"
}

publish() {
    product=$1 version=$2 suffix=$3 staged=$4
    printf '%s\n' "$product" | grep -Eq '^[a-z0-9]+(-[a-z0-9]+)*$' || die "bad product: $product"
    printf '%s\n' "$version" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$' || die "bad version: $version"
    printf '%s\n' "$suffix" | grep -Eq '^[.-][A-Za-z0-9._-]*[A-Za-z0-9]$' || die "bad suffix: $suffix"
    case "$staged" in
        *..*) die "bad staged path" ;;
        "$DIR"/.incoming/*) ;;
        *) die "staged file must be inside $DIR/.incoming" ;;
    esac
    [ -f "$staged" ] || die "staged file not found: $staged"

    target="$product-$version$suffix"
    acquire_lock

    # rename inside one filesystem is atomic: downloads never see a half-written file
    mv -f "$staged" "$DIR/$target"
    chmod 644 "$DIR/$target"
    (cd "$DIR" && sha256sum "$target" >"$target.sha256")
    echo "stored $target ($(stat -c %s "$DIR/$target") bytes)"

    # an old version rebuilt later must not move "latest" backwards
    newest=$(versions_of "$product" "$suffix" | tail -n 1)
    if [ "$newest" = "$version" ]; then
        ln -s "$target" "$DIR/.latest.$$"
        mv -f "$DIR/.latest.$$" "$DIR/$product-latest$suffix"
        echo "latest -> $target"
    else
        echo "latest unchanged ($newest is newer than $version)"
    fi

    prune
    write_manifest
    echo "manifest written"
}

reindex() {
    acquire_lock
    for f in "$DIR"/*; do
        { [ -f "$f" ] && [ ! -L "$f" ]; } || continue
        case "${f##*/}" in manifest.json | *.sha256) continue ;; esac
        [ -f "$f.sha256" ] || (cd "$DIR" && sha256sum "${f##*/}" >"${f##*/}.sha256")
    done
    write_manifest
    echo "manifest written"
}

mkdir -p "$DIR/.incoming"
cmd=${1:-}
case "$cmd" in
    publish) [ $# -eq 5 ] || die "usage: publish <product> <version> <suffix> <staged-file>"; shift; publish "$@" ;;
    reindex) reindex ;;
    *) die "usage: $0 publish <product> <version> <suffix> <staged-file> | reindex" ;;
esac
