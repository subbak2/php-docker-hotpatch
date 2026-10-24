# php-docker-hotpatch

Patch PHP in your Docker WordPress (or plain PHP) containers **before the official images catch up**.

When php.net ships a security release, the official `php` and `wordpress` images on Docker Hub can take hours to days to follow. `hotpatch.sh` builds those same images yourself with the new PHP version, so you can swap them in right away and switch back to the official image once it's updated.

**한국어 설명: [docs/manual-ko.md](docs/manual-ko.md)**

## Why this is safe to run

- **No prebuilt binaries.** Nothing here is an image to trust. The script downloads the build files from [docker-library/php](https://github.com/docker-library/php) and [docker-library/wordpress](https://github.com/docker-library/wordpress), the repositories the official images are built from.
- **One change.** It changes only `PHP_VERSION`, `PHP_URL` and `PHP_SHA256` in the PHP Dockerfile (and the `FROM` line in the WordPress Dockerfile). The SHA256 comes from the php.net releases API.
- **Same verification.** The unchanged official Dockerfile checks the PHP tarball against that SHA256 and the PHP release managers' GPG signatures before compiling.
- **Nothing on your server changes** until you point your compose file at the new image, and going back is one line.

## Quick start

```bash
git clone https://github.com/subbak2/php-docker-hotpatch && cd php-docker-hotpatch

./hotpatch.sh check --php 8.3                 # is wordpress:php8.3-apache behind php.net?
./hotpatch.sh build --php 8.3                 # build hotpatch/php and hotpatch/wordpress with the latest 8.3.x
```

Then in `docker-compose.yml`:

```yaml
  wordpress:
    image: hotpatch/wordpress:php8.3.36-apache   # was wordpress:php8.3-apache
```

```bash
docker compose up -d --no-deps wordpress
docker compose exec wordpress php -v           # PHP 8.3.36 ...
```

Your `wp-content`, database and settings live in volumes, so only the PHP runtime changes.

## Options

| Option | Default | |
|---|---|---|
| `--php 8.3` | `8.3` | PHP branch |
| `--version 8.3.36` | latest of the branch | Exact release |
| `--variant apache\|fpm` | `apache` | Image variant (Debian) |
| `--debian trixie` | `trixie` | Debian release used by docker-library for that branch |
| `--platform linux/amd64` | host | Cross-build with buildx, e.g. on an Apple Silicon Mac for an x86 server |
| `--no-wordpress` | | Build only `hotpatch/php` (for non-WordPress PHP apps) |
| `--imagick-from-github` | | Build the imagick extension from its GitHub tag instead of pecl.php.net (pecl is often overloaded right after a security release) |
| `--force` | | Build even if docker-library already has the new version |
| `--image` (check) | `wordpress:php<branch>-<variant>` | Image to compare against php.net |

Image tags: `hotpatch/php:<version>-<variant>[-<arch>]` and `hotpatch/wordpress:php<version>-<variant>[-<arch>]`.

## Getting the image onto a server

Build on the server itself (simplest), or build elsewhere and copy it without a registry:

```bash
./hotpatch.sh build --php 8.3 --platform linux/amd64
docker save hotpatch/wordpress:php8.3.36-apache-amd64 | gzip | ssh myserver 'gunzip | docker load'
```

Timing on an Apple Silicon Mac: PHP compiles in about 4.5 minutes natively and WordPress adds about 1.5 minutes. Cross-building amd64 under QEMU emulation took about 31 minutes for the PHP stage, so building on the x86 server is usually faster.

## Going back to the official image

Run `./hotpatch.sh check` once in a while (or from cron). When it prints `OK`, put `wordpress:php8.3-apache` back in your compose file and run `docker compose pull wordpress && docker compose up -d --no-deps wordpress`.

Until then **you** own the security updates of that image: the base Debian packages in it are frozen at build time. Treat a hotpatched image as a bridge of hours or days, not a long-term base.

## While you wait for the build

A patched PHP is the fix. Until it is deployed, the usual stopgaps are a WAF rule at your CDN and disabling PHP features WordPress doesn't use. For example, during PHP2Shell (CVE-2026-109618/109619, October 2026) `session.upload_progress.enabled = 0` removed one attack path. Check the advisory for the CVE you're dealing with; settings alone don't replace the patch.

## Real-world use

Written after patching a production WordPress site during PHP2Shell: PHP 8.3.36 was out at 23:00 KST, the official `wordpress:php8.3-apache` was still on 8.3.35, and the hotpatched image was in production 91 minutes later. This script is that procedure, generalized.

## Limitations

- Debian-based `apache` and `fpm` variants only (no Alpine, no ZTS).
- Relies on the docker-library Dockerfile layout (`ENV PHP_VERSION`, `ENV PHP_URL=...`, `ENV PHP_SHA256=...`, `FROM php:...`). If upstream changes it, the script stops with an error instead of building something unexpected.
- The PHP branch needs a docker-library folder for the chosen Debian release; pass `--debian bookworm` for older branches if needed.

## License

MIT
