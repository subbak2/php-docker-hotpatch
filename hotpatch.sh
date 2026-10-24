#!/usr/bin/env bash
# php-docker-hotpatch: build the official PHP / WordPress Docker images yourself with a newer PHP release,
# for the hours or days between a PHP security release and the official Docker Hub images catching up.
#
# Nothing is downloaded prebuilt: the build files come from docker-library (the source of the official images),
# only the PHP version and its SHA256 are changed, and the PHP tarball is verified against its SHA256 and the
# release managers' GPG signatures exactly as the official build does.
#
# Usage:
#   ./hotpatch.sh check [--php 8.3] [--image wordpress:php8.3-apache]
#   ./hotpatch.sh build [--php 8.3] [--version 8.3.36] [--variant apache|fpm] [--debian trixie]
#                       [--platform linux/amd64] [--no-wordpress] [--imagick-from-github] [--force] [--workdir DIR]
#
# Requires: bash, curl, python3, docker (buildx for --platform).
set -euo pipefail

PHP_BRANCH="8.3"
VERSION=""
VARIANT="apache"
DEBIAN="trixie"
PLATFORM=""
IMAGE=""
WITH_WORDPRESS=1
IMAGICK_FROM_GITHUB=0
FORCE=0
WORKDIR=""

PHP_REPO_RAW="https://raw.githubusercontent.com/docker-library/php/master"
WP_REPO_RAW="https://raw.githubusercontent.com/docker-library/wordpress/master"
PHP_REPO_API="https://api.github.com/repos/docker-library/php/contents"

die() { echo "error: $*" >&2; exit 1; }
log() { echo "==> $*" >&2; }

usage() { sed -n '2,15p' "$0" | sed 's/^# \{0,1\}//'; exit "${1:-0}"; }

parse_args() {
    while [ $# -gt 0 ]; do
        case "$1" in
            --php) PHP_BRANCH="$2"; shift 2 ;;
            --version) VERSION="$2"; shift 2 ;;
            --variant) VARIANT="$2"; shift 2 ;;
            --debian) DEBIAN="$2"; shift 2 ;;
            --platform) PLATFORM="$2"; shift 2 ;;
            --image) IMAGE="$2"; shift 2 ;;
            --no-wordpress) WITH_WORDPRESS=0; shift ;;
            --imagick-from-github) IMAGICK_FROM_GITHUB=1; shift ;;
            --force) FORCE=1; shift ;;
            --workdir) WORKDIR="$2"; shift 2 ;;
            -h|--help) usage 0 ;;
            *) die "unknown option: $1 (see --help)" ;;
        esac
    done
    [[ "$PHP_BRANCH" =~ ^[0-9]+\.[0-9]+$ ]] || die "--php must look like 8.3"
    [[ "$VARIANT" == apache || "$VARIANT" == fpm ]] || die "--variant must be apache or fpm"
    [ -n "$IMAGE" ] || IMAGE="wordpress:php${PHP_BRANCH}-${VARIANT}"
}

# Latest release (or --version) of the branch from php.net. Sets REL_VERSION and REL_SHA256 (of the .tar.xz).
php_release() {
    local url="https://www.php.net/releases/index.php?json&version=${VERSION:-$PHP_BRANCH}" json out
    json=$(curl -fsSL "$url") || die "could not reach php.net ($url)"
    out=$(printf '%s' "$json" | python3 -c '
import json, re, sys
branch = sys.argv[1]
r = json.load(sys.stdin)
if "error" in r: sys.exit("php.net: " + r["error"])
version = r.get("version", "")
if not re.fullmatch(re.escape(branch) + r"\.\d+", version):
    sys.exit(f"php.net returned version {version!r}, expected {branch}.x")
xz = [s for s in r.get("source", []) if s.get("filename") == f"php-{version}.tar.xz"]
if not xz or not re.fullmatch(r"[0-9a-f]{64}", xz[0].get("sha256", "")):
    sys.exit(f"php.net: no valid SHA256 for php-{version}.tar.xz")
print(version, xz[0]["sha256"])
' "$PHP_BRANCH") || die "unexpected php.net response"
    read -r REL_VERSION REL_SHA256 <<< "$out"
}

image_php_version() {
    docker run --rm --pull always --entrypoint php "$1" -r 'echo PHP_VERSION;' 2>/dev/null
}

# "a < b" for dotted versions (python3 instead of sort -V, which BSD/macOS sort may lack)
version_lt() {
    python3 -c 'import sys; v = lambda s: [int(x) for x in s.split(".")]; sys.exit(0 if v(sys.argv[1]) < v(sys.argv[2]) else 1)' "$1" "$2"
}

cmd_check() {
    local latest current
    php_release
    latest="$REL_VERSION"
    log "php.net latest ${PHP_BRANCH}: ${latest}"
    log "pulling ${IMAGE} to read its PHP version..."
    current=$(image_php_version "$IMAGE") || die "could not run ${IMAGE}"
    log "${IMAGE}: PHP ${current}"
    if version_lt "$current" "$latest"; then
        echo "BEHIND: ${IMAGE} has PHP ${current}, php.net has ${latest}. Run: ./hotpatch.sh build --php ${PHP_BRANCH}"
        return 1
    fi
    echo "OK: ${IMAGE} is up to date (PHP ${current}). No hotpatch needed."
}

fetch() { curl -fsSL "$1" -o "$2" || die "download failed: $1"; }

prepare_php_dir() {
    local dir="$1" path="${PHP_BRANCH}/${DEBIAN}/${VARIANT}"
    log "fetching docker-library/php ${path}"
    mkdir -p "$dir"
    curl -fsSL "${PHP_REPO_API}/${path}" | python3 -c '
import json, sys
for f in json.load(sys.stdin):
    if f["type"] == "file": print(f["name"])
' > "$dir/.files" || die "docker-library/php has no ${path} (try --debian bookworm)"
    while read -r f; do fetch "${PHP_REPO_RAW}/${path}/${f}" "$dir/$f"; done < "$dir/.files"
    chmod +x "$dir"/docker-php-* "$dir"/apache2-foreground 2>/dev/null || true
    rm "$dir/.files"
}

set_php_version() {
    local dockerfile="$1" version="$2" sha="$3"
    python3 - "$dockerfile" "$version" "$sha" <<'PY'
import re, sys
path, version, sha = sys.argv[1:]
text = open(path).read()
rules = [
    (r"^ENV PHP_VERSION .*$", f"ENV PHP_VERSION {version}"),
    (r'^ENV PHP_URL=.*$', f'ENV PHP_URL="https://www.php.net/distributions/php-{version}.tar.xz" PHP_ASC_URL="https://www.php.net/distributions/php-{version}.tar.xz.asc"'),
    (r'^ENV PHP_SHA256=.*$', f'ENV PHP_SHA256="{sha}"'),
]
for pattern, line in rules:
    text, n = re.subn(pattern, line, text, flags=re.M)
    if n != 1:
        sys.exit(f"unexpected Dockerfile layout: {pattern} matched {n} times")
open(path, "w").write(text)
PY
}

prepare_wordpress_dir() {
    local dir="$1" base="$2" path="latest/php${PHP_BRANCH}/${VARIANT}"
    log "fetching docker-library/wordpress ${path}"
    mkdir -p "$dir"
    for f in Dockerfile docker-entrypoint.sh wp-config-docker.php; do fetch "${WP_REPO_RAW}/${path}/${f}" "$dir/$f"; done
    chmod +x "$dir/docker-entrypoint.sh"
    python3 - "$dir/Dockerfile" "$base" "$IMAGICK_FROM_GITHUB" <<'PY'
import re, sys
path, base, imagick_from_github = sys.argv[1], sys.argv[2], sys.argv[3] == "1"
text = open(path).read()
text, n = re.subn(r"^FROM php:\S+$", f"FROM {base}", text, count=1, flags=re.M)
if n != 1:
    sys.exit("unexpected WordPress Dockerfile: no 'FROM php:...' line")
if imagick_from_github:
    # pecl.php.net is often overloaded right after a security release; build imagick from its GitHub tag instead.
    m = re.search(r"^(\s*)pecl install imagick-([0-9.]+); \\\n", text, flags=re.M)
    if not m:
        sys.exit("unexpected WordPress Dockerfile: no 'pecl install imagick-X' line")
    indent, ver = m.group(1), m.group(2)
    repl = (f"{indent}mkdir -p /usr/src/imagick; \\\n"
            f"{indent}curl -fsSL https://github.com/Imagick/imagick/archive/refs/tags/{ver}.tar.gz | tar -xz -C /usr/src/imagick --strip-components=1; \\\n"
            f"{indent}docker-php-ext-install -j \"$(nproc)\" /usr/src/imagick; \\\n"
            f"{indent}rm -rf /usr/src/imagick; \\\n")
    text = text[:m.start()] + repl + text[m.end():]
    text = re.sub(r"^\s*docker-php-ext-enable imagick; \\\n", "", text, flags=re.M)
    # pecl did not run, so its temp dir may not exist
    text = re.sub(r"^(\s*)rm -r /tmp/pear; \\$", r"\1rm -rf /tmp/pear; \\", text, flags=re.M)
open(path, "w").write(text)
PY
}

docker_build() {
    local tag="$1" dir="$2"
    if [ -n "$PLATFORM" ]; then
        docker buildx build --platform "$PLATFORM" --load -t "$tag" "$dir"
    else
        docker build -t "$tag" "$dir"
    fi
}

cmd_build() {
    local version sha suffix php_tag wp_tag final_tag
    php_release
    version="$REL_VERSION"; sha="$REL_SHA256"
    log "target PHP ${version} (sha256 ${sha:0:12}...)"

    suffix=""
    [ -n "$PLATFORM" ] && suffix="-${PLATFORM##*/}"
    php_tag="hotpatch/php:${version}-${VARIANT}${suffix}"
    wp_tag="hotpatch/wordpress:php${version}-${VARIANT}${suffix}"

    [ -n "$WORKDIR" ] || WORKDIR="build/php${version}-${VARIANT}${suffix}"
    rm -rf "$WORKDIR"; mkdir -p "$WORKDIR"

    prepare_php_dir "$WORKDIR/php"
    local upstream
    upstream=$(sed -n 's/^ENV PHP_VERSION //p' "$WORKDIR/php/Dockerfile")
    if ! version_lt "$upstream" "$version" && [ "$FORCE" = 0 ]; then
        echo "docker-library already builds PHP ${upstream}; the official image should follow shortly."
        echo "Pull the official image instead, or pass --force to build anyway."
        exit 0
    fi
    set_php_version "$WORKDIR/php/Dockerfile" "$version" "$sha"
    log "building ${php_tag} (PHP ${upstream} -> ${version}; compiling PHP takes a few minutes)"
    docker_build "$php_tag" "$WORKDIR/php"

    if [ "$WITH_WORDPRESS" = 1 ]; then
        prepare_wordpress_dir "$WORKDIR/wordpress" "$php_tag"
        log "building ${wp_tag}"
        docker_build "$wp_tag" "$WORKDIR/wordpress"
    fi

    final_tag="$php_tag"
    [ "$WITH_WORDPRESS" = 1 ] && final_tag="$wp_tag"
    log "checking the result"
    docker run --rm --entrypoint php "$final_tag" -v | head -1
    cat <<EOF

Built: ${final_tag}

Point your docker-compose.yml at it (image: ${final_tag}) and recreate that service,
e.g. docker compose up -d --no-deps wordpress
Copy to a server without a registry:
  docker save ${final_tag} | gzip | ssh <server> 'gunzip | docker load'
Go back to the official image as soon as \`./hotpatch.sh check\` says OK.
EOF
}

main() {
    [ $# -ge 1 ] || usage 1
    local cmd="$1"; shift
    parse_args "$@"
    case "$cmd" in
        check) cmd_check ;;
        build) cmd_build ;;
        -h|--help|help) usage 0 ;;
        *) die "unknown command: $cmd (check or build)" ;;
    esac
}

main "$@"
