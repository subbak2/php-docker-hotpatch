# php-docker-hotpatch 설명서

PHP 보안 업데이트가 나왔는데 Docker Hub의 공식 `php`·`wordpress` 이미지가 아직 옛 버전일 때, **같은 공식 빌드 파일로 새 PHP 버전 이미지를 직접 만들어** 바로 갈아 끼우는 스크립트입니다. 공식 이미지가 따라오면 원래대로 돌아갑니다.

## 언제 쓰나

- Docker로 워드프레스(또는 PHP 앱)를 운영하는데
- php.net에 보안 릴리스가 나왔고 (예: 2026-10-21 PHP2Shell, 8.3.36)
- `docker pull wordpress:php8.3-apache` 해도 아직 이전 버전(8.3.35)일 때

## 믿고 써도 되는 이유

- **미리 만든 이미지를 받지 않습니다.** 공식 이미지를 만드는 저장소(docker-library/php, docker-library/wordpress)에서 빌드 파일을 그대로 받아 내 컴퓨터에서 빌드합니다.
- **바꾸는 건 버전 세 줄뿐**입니다. PHP Dockerfile의 `PHP_VERSION`·`PHP_URL`·`PHP_SHA256`(php.net 릴리스 API 값)과 워드프레스 Dockerfile의 `FROM` 한 줄.
- **검증도 공식과 같습니다.** 공식 Dockerfile이 PHP 소스의 SHA256과 PHP 릴리스 담당자의 GPG 서명을 확인한 뒤 컴파일합니다.

## 쓰는 법

```bash
git clone https://github.com/subbak2/php-docker-hotpatch && cd php-docker-hotpatch

./hotpatch.sh check --php 8.3     # 공식 이미지가 php.net보다 뒤처졌는지 확인
./hotpatch.sh build --php 8.3     # hotpatch/php, hotpatch/wordpress 이미지 빌드
```

`docker-compose.yml`의 이미지를 바꾸고 워드프레스 컨테이너만 다시 띄웁니다.

```yaml
  wordpress:
    image: hotpatch/wordpress:php8.3.36-apache   # 원래 wordpress:php8.3-apache
```

```bash
docker compose up -d --no-deps wordpress
docker compose exec wordpress php -v
```

글·DB·설정은 볼륨에 있어서 PHP 실행 환경만 바뀝니다.

## 자주 쓰는 옵션

- `--platform linux/amd64`: 맥(Apple Silicon)에서 x86 서버용으로 빌드. QEMU 에뮬레이션이라 PHP 단계만 30분쯤 걸리니, 가능하면 서버에서 직접 빌드하는 편이 빠릅니다.
- `--imagick-from-github`: 보안 릴리스 직후 pecl.php.net이 과부하로 죽어 있을 때 imagick을 GitHub 소스로 빌드.
- `--no-wordpress`: PHP 이미지만 (워드프레스가 아닌 PHP 앱).
- `--variant fpm`: Apache 대신 FPM 이미지.

서버로 옮기기 (레지스트리 없이):

```bash
docker save hotpatch/wordpress:php8.3.36-apache-amd64 | gzip | ssh 내서버 'gunzip | docker load'
```

## 공식 이미지로 돌아가기

`./hotpatch.sh check`가 `OK`를 출력하면 compose 파일을 `wordpress:php8.3-apache`로 되돌리고 `docker compose pull wordpress && docker compose up -d --no-deps wordpress`.

직접 빌드한 이미지는 그 시점의 데비안 패키지로 굳어 있습니다. 몇 시간~며칠 쓰는 다리로만 쓰고 오래 두지 마세요.

## 빌드 기다리는 동안

해결책은 패치입니다. 그 전까지는 CDN의 WAF 규칙, 워드프레스가 쓰지 않는 PHP 기능 끄기로 공격 경로를 줄입니다. PHP2Shell 때는 `session.upload_progress.enabled = 0`이 공격 경로 하나를 막았습니다. 설정만으로 패치를 대신할 수는 없습니다.

## 한계

- 데비안 기반 `apache`·`fpm`만 지원 (Alpine·ZTS 없음)
- docker-library Dockerfile 형식이 바뀌면 이상한 이미지를 만들지 않고 오류로 멈춥니다
