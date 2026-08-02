#!/bin/sh
set -eu

DOMAIN="${FUBAO_SYNC_DOMAIN:-fbv2.ccvar.com}"
MANIFEST_URL="${FUBAO_SYNC_MANIFEST_URL:-https://raw.githubusercontent.com/ccvar/fubao-v2-releases/main/server-latest.json}"
SERVICE_USER="fubao-sync"
SERVICE_NAME="fubao-sync"
INSTALL_DIR="/usr/local/bin"
CONFIG_DIR="/etc/fubao-sync"
DATA_DIR="/var/lib/fubao-sync"
CADDY_SNIPPET="/etc/caddy/conf.d/fbv2.caddy"
CADDY_IMPORT="import /etc/caddy/conf.d/*.caddy"

if [ "$(id -u)" -ne 0 ]; then
	echo "请使用 sudo 运行安装脚本。" >&2
	exit 1
fi

if [ ! -r /etc/os-release ]; then
	echo "当前系统暂不支持一键安装；第一版支持 Debian 和 Ubuntu。" >&2
	exit 1
fi
. /etc/os-release
case "${ID:-}:${ID_LIKE:-}" in
	debian:*|ubuntu:*|*:debian*) ;;
	*)
		echo "当前系统暂不支持一键安装；第一版支持 Debian 和 Ubuntu。" >&2
		exit 1
		;;
esac

case "$(uname -m)" in
	x86_64|amd64) ASSET_KEY="linux-amd64" ;;
	aarch64|arm64) ASSET_KEY="linux-arm64" ;;
	*)
		echo "不支持的 CPU 架构：$(uname -m)" >&2
		exit 1
		;;
esac

apt-get update
DEBIAN_FRONTEND=noninteractive apt-get install -y ca-certificates curl gpg python3 tar openssl sqlite3 debian-keyring debian-archive-keyring apt-transport-https

if ! command -v caddy >/dev/null 2>&1; then
	curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' | gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
	curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' > /etc/apt/sources.list.d/caddy-stable.list
	chmod o+r /usr/share/keyrings/caddy-stable-archive-keyring.gpg /etc/apt/sources.list.d/caddy-stable.list
	apt-get update
	DEBIAN_FRONTEND=noninteractive apt-get install -y caddy
fi

TEMP_DIR="$(mktemp -d)"
cleanup() {
	rm -rf "$TEMP_DIR"
}
trap cleanup EXIT INT TERM

curl --fail --silent --show-error --location "$MANIFEST_URL" --output "$TEMP_DIR/server-latest.json"
ASSET_URL="$(python3 - "$TEMP_DIR/server-latest.json" "$ASSET_KEY" <<'PY'
import json, sys
with open(sys.argv[1], encoding="utf-8") as source:
    print(json.load(source)["assets"][sys.argv[2]]["url"])
PY
)"
ASSET_SHA256="$(python3 - "$TEMP_DIR/server-latest.json" "$ASSET_KEY" <<'PY'
import json, sys
with open(sys.argv[1], encoding="utf-8") as source:
    print(json.load(source)["assets"][sys.argv[2]]["sha256"])
PY
)"
VERSION="$(python3 - "$TEMP_DIR/server-latest.json" <<'PY'
import json, sys
with open(sys.argv[1], encoding="utf-8") as source:
    print(json.load(source)["version"])
PY
)"

curl --fail --silent --show-error --location "$ASSET_URL" --output "$TEMP_DIR/server.tar.gz"
printf '%s  %s\n' "$ASSET_SHA256" "$TEMP_DIR/server.tar.gz" | sha256sum --check --status
tar -xzf "$TEMP_DIR/server.tar.gz" -C "$TEMP_DIR"
install -m 0755 "$TEMP_DIR/fubao-sync-server" "$INSTALL_DIR/fubao-sync-server"

if ! getent group "$SERVICE_USER" >/dev/null 2>&1; then
	groupadd --system "$SERVICE_USER"
fi
if ! id "$SERVICE_USER" >/dev/null 2>&1; then
	useradd --system --gid "$SERVICE_USER" --home-dir "$DATA_DIR" --shell /usr/sbin/nologin "$SERVICE_USER"
fi
install -d -m 0750 -o "$SERVICE_USER" -g "$SERVICE_USER" "$DATA_DIR"
install -d -m 0750 -o root -g "$SERVICE_USER" "$CONFIG_DIR"

if [ ! -s "$CONFIG_DIR/enrollment.token" ]; then
	umask 077
	openssl rand -hex 32 > "$CONFIG_DIR/enrollment.token"
fi
chown root:"$SERVICE_USER" "$CONFIG_DIR/enrollment.token"
chmod 0640 "$CONFIG_DIR/enrollment.token"

cat > "/etc/systemd/system/$SERVICE_NAME.service" <<'UNIT'
[Unit]
Description=Fubao remote room and red-packet sync service
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=fubao-sync
Group=fubao-sync
ExecStart=/usr/local/bin/fubao-sync-server -listen 127.0.0.1:8788 -data /var/lib/fubao-sync/fubao-sync.db -enrollment-token-file /etc/fubao-sync/enrollment.token
Restart=on-failure
RestartSec=5s
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ProtectHome=true
ProtectKernelTunables=true
ProtectKernelModules=true
ProtectControlGroups=true
RestrictSUIDSGID=true
LockPersonality=true
ReadWritePaths=/var/lib/fubao-sync

[Install]
WantedBy=multi-user.target
UNIT

install -d -m 0755 /etc/caddy/conf.d
SNIPPET_EXISTED="false"
if [ -f "$CADDY_SNIPPET" ]; then
	SNIPPET_EXISTED="true"
	cp "$CADDY_SNIPPET" "$TEMP_DIR/fbv2.caddy.backup"
fi
cat > "$CADDY_SNIPPET" <<CADDY
$DOMAIN {
	encode zstd gzip
	reverse_proxy 127.0.0.1:8788 {
		health_uri /healthz
		health_interval 30s
		health_timeout 3s
	}
}

https://$DOMAIN:8087 {
	encode zstd gzip
	reverse_proxy 127.0.0.1:8788 {
		health_uri /healthz
		health_interval 30s
		health_timeout 3s
	}
}
CADDY

CADDY_BACKUP=""
if ! grep -Fq "$CADDY_IMPORT" /etc/caddy/Caddyfile; then
	CADDY_BACKUP="/etc/caddy/Caddyfile.fubao-backup.$(date +%s)"
	cp /etc/caddy/Caddyfile "$CADDY_BACKUP"
	printf '\n%s\n' "$CADDY_IMPORT" >> /etc/caddy/Caddyfile
fi
if ! caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile; then
	if [ -n "$CADDY_BACKUP" ]; then
		cp "$CADDY_BACKUP" /etc/caddy/Caddyfile
	fi
	if [ "$SNIPPET_EXISTED" = "true" ]; then
		cp "$TEMP_DIR/fbv2.caddy.backup" "$CADDY_SNIPPET"
	else
		rm -f "$CADDY_SNIPPET"
	fi
	echo "Caddy 配置验证失败，已恢复原配置。" >&2
	exit 1
fi

systemctl daemon-reload
systemctl enable --now "$SERVICE_NAME"
if ! systemctl enable --now caddy; then
	systemctl status caddy --no-pager -l >&2 || true
	journalctl -u caddy --no-pager -n 50 >&2 || true
	echo "Caddy 启动失败；请检查 80、443、8087 端口占用和上方日志。" >&2
	exit 1
fi
if ! systemctl reload caddy; then
	systemctl status caddy --no-pager -l >&2 || true
	journalctl -u caddy --no-pager -n 50 >&2 || true
	echo "Caddy 重载失败；请检查上方日志。" >&2
	exit 1
fi

for ATTEMPT in 1 2 3 4 5 6 7 8 9 10; do
	if curl --fail --silent --show-error http://127.0.0.1:8788/healthz >/dev/null; then
		break
	fi
	if [ "$ATTEMPT" -eq 10 ]; then
		journalctl -u "$SERVICE_NAME" --no-pager -n 30 >&2
		echo "同步服务启动失败。" >&2
		exit 1
	fi
	sleep 1
done

echo ""
echo "福宝同步服务 $VERSION 安装完成。"
echo "服务地址：https://$DOMAIN/api/v1"
echo "备用地址：https://$DOMAIN:8087/api/v1"
echo "客户端注册令牌：$(cat "$CONFIG_DIR/enrollment.token")"
echo ""
echo "请确认 $DOMAIN 的 A/AAAA 记录已指向本机，并开放 TCP 80、443、8087。"
