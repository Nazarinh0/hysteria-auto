# Hysteria 2 Docker IP Deployer

Самостоятельный bash-deployer для установки Hysteria 2 на Ubuntu/Debian VPS.

Скрипт запускает один Docker-контейнер `hysteria2` на UDP-порту `8443` по умолчанию и выводит готовую клиентскую ссылку `hysteria2://`. Mihomo/Clash-конфиги не создаются.

Основной TLS-режим по умолчанию:

```text
letsencrypt-ip
```

В этом режиме выпускается публично доверенный Let's Encrypt сертификат именно на IP-адрес сервера, поэтому клиентская ссылка использует:

```text
insecure=0
```

Self-signed TLS оставлен только как fallback:

```bash
--tls self-signed
```

В fallback-режиме ссылка использует:

```text
insecure=1
```

## Что делает deployer

- Устанавливает Docker Engine на чистую Ubuntu/Debian VM, если Docker отсутствует.
- Использует уже работающий Docker без переустановки, обновления и restart.
- Запускает официальный image `tobyxdd/hysteria:latest`.
- Публикует UDP-порт через Docker: `-p 8443:8443/udp`.
- Создаёт `/opt/hysteria2`.
- Сохраняет `client-uri.txt`, `install-result.json`, `server-info.txt`, `docker-run-command.sh`.
- Создаёт systemd timer для автоматического renewal короткоживущего Let's Encrypt IP certificate.
- Может работать рядом с Amnezia self-hosted.

## Что deployer не делает

- Не использует Docker Compose.
- Не создаёт Dockerfile.
- Не создаёт Mihomo config.
- Не создаёт Clash config.
- Не использует UDP 443.
- Не использует TCP 443.
- Не включает port hopping.
- Не выпускает domain ACME certificates.
- Не создаёт отдельные Docker networks.
- Не использует `--network host`.
- Не использует `--privileged`.
- Не использует `--cap-add=NET_ADMIN`.
- Не выполняет `apt upgrade`, `apt full-upgrade`, `apt autoremove`.
- Не перезапускает Docker daemon, если Docker уже работает.
- Не переписывает системные iptables rules.
- Не выполняет Docker prune.
- Не останавливает сервисы на TCP 80 автоматически.
- Не меняет контейнеры Amnezia, Xray, AWG2, WireGuard, OpenVPN.

## Поддерживаемые ОС

MVP рассчитан на:

- Ubuntu 22.04 LTS
- Ubuntu 24.04 LTS
- Debian 12

Другие версии Ubuntu/Debian могут получить warning. Не Ubuntu/Debian системы останавливаются с ошибкой.

## Требования

Для режима `letsencrypt-ip` нужны:

- Публичный IPv4 сервера.
- TCP 80, доступный из интернета для Certbot standalone validation.
- UDP 8443, доступный из интернета для Hysteria.
- Certbot 5.4+. Если системного Certbot нет или он слишком старый, installer создаёт отдельный venv: `/opt/hysteria2/certbot-venv`.

Email для Let's Encrypt зашит в deployer:

```text
admin@hy2.com
```

Пользователь не указывает email при запуске.

Имя профиля тоже имеет default:

```text
nasha-hy2
```

Пользователь может переопределить его через `--name`, но в обычном запуске это не нужно.

Если TCP 80 уже занят, standalone mode остановится с ошибкой. Скрипт не останавливает nginx, Apache, Amnezia или любой другой сервис автоматически.

## Базовая установка

```bash
ssh root@SERVER_IP "curl -fsSL https://raw.githubusercontent.com/Nazarinh0/hysteria-auto/main/install.sh | bash -s -- --ip SERVER_IP"
```

## Установка с явными паролями

```bash
ssh root@SERVER_IP "curl -fsSL https://raw.githubusercontent.com/Nazarinh0/hysteria-auto/main/install.sh | bash -s -- --ip SERVER_IP --port 8443 --auth-password AUTH_PASSWORD --obfs-password OBFS_PASSWORD"
```

## Self-signed fallback

Используйте только если осознанно принимаете `insecure=1`.

```bash
ssh root@SERVER_IP "curl -fsSL https://raw.githubusercontent.com/Nazarinh0/hysteria-auto/main/install.sh | bash -s -- --ip SERVER_IP --tls self-signed"
```

## Пример клиентской ссылки

```text
hysteria2://AUTH_PASSWORD@SERVER_IP:8443/?obfs=salamander&obfs-password=OBFS_PASSWORD&sni=SERVER_IP&insecure=0#nasha-hy2
```

## Проверка установки

```bash
docker ps --filter name=hysteria2
docker logs hysteria2
docker port hysteria2
ss -lunp | grep 8443
cat /opt/hysteria2/client-uri.txt
systemctl list-timers | grep hysteria2-cert-renew
```

Проверить SAN в IP-сертификате:

```bash
openssl x509 -in /etc/letsencrypt/live/SERVER_IP/fullchain.pem -noout -text | grep -A2 "Subject Alternative Name"
```

Проверить, что контейнеры Amnezia не были изменены:

```bash
docker ps --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}'
```

## Удаление

Удалить контейнер и renewal timer, файлы оставить:

```bash
bash uninstall.sh --keep-files
```

Удалить контейнер, renewal timer и install dir:

```bash
bash uninstall.sh --remove-files
```

Удалить контейнер, файлы и Let's Encrypt certificate lineage:

```bash
bash uninstall.sh --remove-files --remove-cert --ip SERVER_IP
```

`uninstall.sh` не удаляет Docker Engine, Docker networks, Amnezia, Xray, AWG2, WireGuard, OpenVPN, firewall rules или iptables rules.

## Создаваемые файлы

- `/opt/hysteria2/config.yaml`
- `/opt/hysteria2/client-uri.txt`
- `/opt/hysteria2/install-result.json`
- `/opt/hysteria2/server-info.txt`
- `/opt/hysteria2/docker-run-command.sh`
- `/opt/hysteria2/renew-cert.sh`
- `/etc/systemd/system/hysteria2-cert-renew.service`
- `/etc/systemd/system/hysteria2-cert-renew.timer`

Файлы с секретами получают mode `600`, где это применимо. Install dir получает mode `700`.

## Совместимость с Amnezia

Amnezia Xray/REALITY часто использует TCP 443. Это не конфликтует с Hysteria на UDP 8443.

Контейнер Hysteria:

- имя: `hysteria2`
- port publishing: `-p 8443:8443/udp`
- без `--network host`
- без Docker networks Amnezia
- без `amnezia-dns-net`
- без изменений Xray/AWG2/WireGuard/OpenVPN configs

Реальные конфликты:

- занят UDP 8443;
- занят TCP 80 при использовании Certbot standalone mode.

## Обновление сертификата

Let's Encrypt IP certificates короткоживущие, около 6 дней. Deployer создаёт systemd timer:

```bash
systemctl list-timers | grep hysteria2-cert-renew
journalctl -u hysteria2-cert-renew.service --no-pager -e
```

Renewal hook после успешного обновления перезапускает только контейнер `hysteria2`. Активные Hysteria-подключения могут кратко оборваться во время restart.

## Firewall

Deployer открывает локальные firewall ports только если `ufw` или `firewalld` уже active. Inactive `ufw` не включается автоматически.

В firewall/security group VPS-провайдера всё равно нужно открыть:

- UDP 8443 для Hysteria.
- TCP 80 для выпуска и renewal Let's Encrypt IP certificate.

## Docker networking

Трафик попадает в контейнер через Docker port publishing:

```bash
-p 8443:8443/udp
```

Deployer полагается на штатные Docker NAT/firewall rules. Если `/etc/docker/daemon.json` содержит `"iptables": false`, install останавливается и не переписывает Docker daemon settings.
