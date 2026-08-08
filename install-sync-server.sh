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
DATABASE_CONFIG="$CONFIG_DIR/database.env"
MYSQL_PASSWORD_FILE="$CONFIG_DIR/mysql.password"

prompt_value() {
	PROMPT_TEXT="$1"
	PROMPT_DEFAULT="$2"
	if [ ! -r /dev/tty ]; then
		printf '%s' "$PROMPT_DEFAULT"
		return
	fi
	printf '%s' "$PROMPT_TEXT" > /dev/tty
	IFS= read -r PROMPT_ANSWER < /dev/tty || PROMPT_ANSWER=""
	if [ -z "$PROMPT_ANSWER" ]; then
		PROMPT_ANSWER="$PROMPT_DEFAULT"
	fi
	printf '%s' "$PROMPT_ANSWER"
}

prompt_secret() {
	PROMPT_TEXT="$1"
	if [ ! -r /dev/tty ]; then
		printf ''
		return
	fi
	printf '%s' "$PROMPT_TEXT" > /dev/tty
	stty -echo < /dev/tty
	IFS= read -r PROMPT_ANSWER < /dev/tty || PROMPT_ANSWER=""
	stty echo < /dev/tty
	printf '\n' > /dev/tty
	printf '%s' "$PROMPT_ANSWER"
}

config_value() {
	CONFIG_KEY="$1"
	CONFIG_FILE="$2"
	if [ ! -r "$CONFIG_FILE" ]; then
		return
	fi
	sed -n "s/^${CONFIG_KEY}=//p" "$CONFIG_FILE" | tail -n 1
}

valid_mysql_identifier() {
	case "$1" in
		''|*[!A-Za-z0-9_]*) return 1 ;;
		*) return 0 ;;
	esac
}

valid_mysql_host() {
	case "$1" in
		''|*[!A-Za-z0-9._-]*) return 1 ;;
		*) return 0 ;;
	esac
}

valid_mysql_port() {
	case "$1" in
		''|*[!0-9]*) return 1 ;;
		*) [ "$1" -ge 1 ] && [ "$1" -le 65535 ] ;;
	esac
}

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

EXISTING_STORAGE=""
if [ -s "$DATABASE_CONFIG" ]; then
	EXISTING_STORAGE="$(config_value FUBAO_SYNC_STORAGE "$DATABASE_CONFIG")"
elif [ -s "$DATA_DIR/fubao-sync.db" ]; then
	EXISTING_STORAGE="sqlite"
elif [ -x "$INSTALL_DIR/fubao-sync-server" ]; then
	# Releases before selectable storage only supported SQLite.
	EXISTING_STORAGE="sqlite"
fi

STORAGE="${FUBAO_SYNC_STORAGE:-$EXISTING_STORAGE}"
if [ -z "$STORAGE" ]; then
	if [ -r /dev/tty ]; then
		echo "请选择同步服务存储：" > /dev/tty
		echo "  1) SQLite（默认，免配置）" > /dev/tty
		echo "  2) MySQL（检测本机，未安装时可自动安装）" > /dev/tty
		STORAGE_CHOICE="$(prompt_value "请输入 1 或 2 [1]：" "1")"
		case "$STORAGE_CHOICE" in
			2|mysql|MySQL) STORAGE="mysql" ;;
			*) STORAGE="sqlite" ;;
		esac
	else
		STORAGE="sqlite"
	fi
fi
STORAGE="$(printf '%s' "$STORAGE" | tr '[:upper:]' '[:lower:]')"
case "$STORAGE" in
	sqlite|mysql) ;;
	*) echo "不支持的存储类型：$STORAGE（仅支持 sqlite/mysql）" >&2; exit 1 ;;
esac
if [ -n "$EXISTING_STORAGE" ] && [ "$STORAGE" != "$EXISTING_STORAGE" ]; then
	echo "检测到现有 $EXISTING_STORAGE 数据库，安装器不会自动切换到 $STORAGE，以免造成数据丢失。" >&2
	echo "请先完成数据库迁移，再更新 $DATABASE_CONFIG。" >&2
	exit 1
fi

apt-get update
DEBIAN_FRONTEND=noninteractive apt-get install -y ca-certificates curl gpg python3 tar gzip openssl debian-keyring debian-archive-keyring apt-transport-https
if [ "$STORAGE" = "sqlite" ]; then
	DEBIAN_FRONTEND=noninteractive apt-get install -y sqlite3
fi

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

if ! getent group "$SERVICE_USER" >/dev/null 2>&1; then
	groupadd --system "$SERVICE_USER"
fi
if ! id "$SERVICE_USER" >/dev/null 2>&1; then
	useradd --system --gid "$SERVICE_USER" --home-dir "$DATA_DIR" --shell /usr/sbin/nologin "$SERVICE_USER"
fi
install -d -m 0750 -o "$SERVICE_USER" -g "$SERVICE_USER" "$DATA_DIR"
install -d -m 0750 -o root -g "$SERVICE_USER" "$CONFIG_DIR"

MYSQL_HOST="${FUBAO_SYNC_MYSQL_HOST:-127.0.0.1}"
MYSQL_PORT="${FUBAO_SYNC_MYSQL_PORT:-3306}"
MYSQL_DATABASE="${FUBAO_SYNC_MYSQL_DATABASE:-fubao_sync}"
MYSQL_USER="${FUBAO_SYNC_MYSQL_USER:-fubao_sync}"
MYSQL_PASSWORD="${FUBAO_SYNC_MYSQL_PASSWORD:-}"

mysql_server_installed() {
	command -v mysqld >/dev/null 2>&1 || command -v mariadbd >/dev/null 2>&1 || \
		dpkg-query -W -f='${Status}' default-mysql-server mysql-server mariadb-server 2>/dev/null | grep -q 'install ok installed'
}

start_mysql_service() {
	for MYSQL_UNIT in mysql mariadb; do
		if systemctl list-unit-files --type=service 2>/dev/null | grep -q "^${MYSQL_UNIT}\\.service"; then
			systemctl enable --now "$MYSQL_UNIT.service"
			return
		fi
	done
	echo "MySQL/MariaDB 已安装，但没有找到可启动的 systemd 服务。" >&2
	exit 1
}

run_mysql_admin() {
	if [ "$MYSQL_ADMIN_PROTOCOL" = "socket" ]; then
		MYSQL_PWD="$MYSQL_ADMIN_PASSWORD" mysql --protocol=socket -u "$MYSQL_ADMIN_USER" "$@"
	else
		MYSQL_PWD="$MYSQL_ADMIN_PASSWORD" mysql --protocol=tcp -h "$MYSQL_HOST" -P "$MYSQL_PORT" -u "$MYSQL_ADMIN_USER" "$@"
	fi
}

if [ "$STORAGE" = "mysql" ]; then
	DEBIAN_FRONTEND=noninteractive apt-get install -y default-mysql-client
	MYSQL_WAS_INSTALLED="true"
	if ! mysql_server_installed; then
		MYSQL_WAS_INSTALLED="false"
		MYSQL_AUTO_INSTALL="${FUBAO_SYNC_MYSQL_AUTO_INSTALL:-}"
		if [ -z "$MYSQL_AUTO_INSTALL" ]; then
			MYSQL_AUTO_INSTALL="$(prompt_value "未检测到本机 MySQL，是否自动安装？[Y/n]：" "y")"
		fi
		case "$MYSQL_AUTO_INSTALL" in
			n|N|no|NO) echo "已取消 MySQL 自动安装。" >&2; exit 1 ;;
		esac
		DEBIAN_FRONTEND=noninteractive apt-get install -y default-mysql-server
	fi
	start_mysql_service

	if [ -s "$DATABASE_CONFIG" ]; then
		MYSQL_HOST="$(config_value FUBAO_SYNC_MYSQL_HOST "$DATABASE_CONFIG")"
		MYSQL_PORT="$(config_value FUBAO_SYNC_MYSQL_PORT "$DATABASE_CONFIG")"
		MYSQL_DATABASE="$(config_value FUBAO_SYNC_MYSQL_DATABASE "$DATABASE_CONFIG")"
		MYSQL_USER="$(config_value FUBAO_SYNC_MYSQL_USER "$DATABASE_CONFIG")"
		if [ ! -r "$MYSQL_PASSWORD_FILE" ]; then
			echo "MySQL 密码文件不存在：$MYSQL_PASSWORD_FILE" >&2
			exit 1
		fi
		MYSQL_PASSWORD="$(cat "$MYSQL_PASSWORD_FILE")"
	else
		if ! valid_mysql_identifier "$MYSQL_DATABASE" || ! valid_mysql_identifier "$MYSQL_USER" || ! valid_mysql_host "$MYSQL_HOST" || ! valid_mysql_port "$MYSQL_PORT"; then
			echo "MySQL 主机、端口、数据库名或服务账号格式无效。" >&2
			exit 1
		fi
		if [ -z "$MYSQL_PASSWORD" ]; then
			MYSQL_PASSWORD="$(openssl rand -hex 24)"
			MYSQL_ADMIN_USER="${FUBAO_SYNC_MYSQL_ADMIN_USER:-root}"
			MYSQL_ADMIN_PASSWORD="${FUBAO_SYNC_MYSQL_ADMIN_PASSWORD:-}"
			MYSQL_ADMIN_PROTOCOL="tcp"
			if [ "$MYSQL_WAS_INSTALLED" = "false" ]; then
				MYSQL_ADMIN_PROTOCOL="socket"
			elif [ -z "${FUBAO_SYNC_MYSQL_ADMIN_USER:-}" ] && [ -z "${FUBAO_SYNC_MYSQL_ADMIN_PASSWORD:-}" ]; then
				MYSQL_ADMIN_USER="$(prompt_value "MySQL 管理账号 [root]：" "root")"
				MYSQL_ADMIN_PASSWORD="$(prompt_secret "MySQL 管理密码（允许为空）：")"
			fi
			if ! run_mysql_admin -Nse "SELECT 1" >/dev/null; then
				if [ "$MYSQL_ADMIN_USER" = "root" ] && MYSQL_PWD="$MYSQL_ADMIN_PASSWORD" mysql --protocol=socket -u root -Nse "SELECT 1" >/dev/null 2>&1; then
					MYSQL_ADMIN_PROTOCOL="socket"
				else
					echo "MySQL 管理账号验证失败，请检查账号、密码和本机 3306 服务。" >&2
					exit 1
				fi
			fi
			run_mysql_admin -e "CREATE DATABASE IF NOT EXISTS \`$MYSQL_DATABASE\` CHARACTER SET utf8mb4 COLLATE utf8mb4_bin; CREATE USER IF NOT EXISTS '$MYSQL_USER'@'127.0.0.1' IDENTIFIED BY '$MYSQL_PASSWORD'; ALTER USER '$MYSQL_USER'@'127.0.0.1' IDENTIFIED BY '$MYSQL_PASSWORD'; GRANT ALL PRIVILEGES ON \`$MYSQL_DATABASE\`.* TO '$MYSQL_USER'@'127.0.0.1'; FLUSH PRIVILEGES;"
		else
			if ! MYSQL_PWD="$MYSQL_PASSWORD" mysql --protocol=tcp -h "$MYSQL_HOST" -P "$MYSQL_PORT" -u "$MYSQL_USER" -Nse "CREATE DATABASE IF NOT EXISTS \`$MYSQL_DATABASE\` CHARACTER SET utf8mb4 COLLATE utf8mb4_bin"; then
				echo "现有 MySQL 账号无法连接或没有创建数据库的权限。" >&2
				exit 1
			fi
		fi
		umask 027
		printf '%s\n' "$MYSQL_PASSWORD" > "$MYSQL_PASSWORD_FILE"
		chown root:"$SERVICE_USER" "$MYSQL_PASSWORD_FILE"
		chmod 0640 "$MYSQL_PASSWORD_FILE"
	fi
	if ! MYSQL_PWD="$MYSQL_PASSWORD" mysql --protocol=tcp -h "$MYSQL_HOST" -P "$MYSQL_PORT" -u "$MYSQL_USER" "$MYSQL_DATABASE" -Nse "SELECT 1" >/dev/null; then
		echo "MySQL 服务账号无法访问数据库 $MYSQL_DATABASE。" >&2
		exit 1
	fi
	cat > "$DATABASE_CONFIG" <<EOF
FUBAO_SYNC_STORAGE=mysql
FUBAO_SYNC_MYSQL_HOST=$MYSQL_HOST
FUBAO_SYNC_MYSQL_PORT=$MYSQL_PORT
FUBAO_SYNC_MYSQL_DATABASE=$MYSQL_DATABASE
FUBAO_SYNC_MYSQL_USER=$MYSQL_USER
FUBAO_SYNC_MYSQL_PASSWORD_FILE=$MYSQL_PASSWORD_FILE
EOF
else
	cat > "$DATABASE_CONFIG" <<'EOF'
FUBAO_SYNC_STORAGE=sqlite
EOF
fi
chown root:"$SERVICE_USER" "$DATABASE_CONFIG"
chmod 0640 "$DATABASE_CONFIG"

UPGRADING="false"
if [ -f "$INSTALL_DIR/fubao-sync-server" ]; then
	UPGRADING="true"
fi
if [ "$STORAGE" = "sqlite" ] && [ -s "$DATA_DIR/fubao-sync.db" ]; then
	BACKUP_DIR="$DATA_DIR/backups"
	BACKUP_PATH="$BACKUP_DIR/fubao-sync-before-$VERSION-$(date +%Y%m%d-%H%M%S).db"
	install -d -m 0750 -o "$SERVICE_USER" -g "$SERVICE_USER" "$BACKUP_DIR"
	sqlite3 "$DATA_DIR/fubao-sync.db" ".backup '$BACKUP_PATH'"
	chown "$SERVICE_USER:$SERVICE_USER" "$BACKUP_PATH"
	chmod 0640 "$BACKUP_PATH"
elif [ "$STORAGE" = "mysql" ] && [ "$UPGRADING" = "true" ]; then
	BACKUP_DIR="$DATA_DIR/backups"
	BACKUP_PATH="$BACKUP_DIR/fubao-sync-before-$VERSION-$(date +%Y%m%d-%H%M%S).sql.gz"
	install -d -m 0750 -o "$SERVICE_USER" -g "$SERVICE_USER" "$BACKUP_DIR"
	MYSQL_PWD="$MYSQL_PASSWORD" mysqldump --protocol=tcp -h "$MYSQL_HOST" -P "$MYSQL_PORT" -u "$MYSQL_USER" --single-transaction --skip-lock-tables --no-tablespaces --triggers "$MYSQL_DATABASE" | gzip -9 > "$BACKUP_PATH"
	chown "$SERVICE_USER:$SERVICE_USER" "$BACKUP_PATH"
	chmod 0640 "$BACKUP_PATH"
fi
install -m 0755 "$TEMP_DIR/fubao-sync-server" "$INSTALL_DIR/fubao-sync-server.new"
mv -f "$INSTALL_DIR/fubao-sync-server.new" "$INSTALL_DIR/fubao-sync-server"

TOKEN_CREATED="false"
if [ ! -s "$CONFIG_DIR/enrollment.token" ]; then
	umask 077
	openssl rand -hex 32 > "$CONFIG_DIR/enrollment.token"
	TOKEN_CREATED="true"
fi
chown root:"$SERVICE_USER" "$CONFIG_DIR/enrollment.token"
chmod 0640 "$CONFIG_DIR/enrollment.token"

cat > "/etc/systemd/system/$SERVICE_NAME.service" <<'UNIT'
[Unit]
Description=Fubao remote room and red-packet sync service
After=network-online.target mysql.service mariadb.service
Wants=network-online.target

[Service]
Type=simple
User=fubao-sync
Group=fubao-sync
EnvironmentFile=-/etc/fubao-sync/database.env
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
systemctl enable "$SERVICE_NAME"
systemctl restart "$SERVICE_NAME"
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
if [ "$UPGRADING" = "true" ]; then
	echo "福宝同步服务已升级到 $VERSION。"
else
	echo "福宝同步服务 $VERSION 安装完成。"
fi
if [ "$STORAGE" = "mysql" ]; then
	echo "数据存储：MySQL（$MYSQL_USER@$MYSQL_HOST:$MYSQL_PORT/$MYSQL_DATABASE）"
else
	echo "数据存储：SQLite（$DATA_DIR/fubao-sync.db）"
fi
echo "服务地址：https://$DOMAIN/api/v1"
echo "备用地址：https://$DOMAIN:8087/api/v1"
if [ "$TOKEN_CREATED" = "true" ]; then
	echo "客户端注册令牌：$(cat "$CONFIG_DIR/enrollment.token")"
else
	echo "已保留现有客户端注册令牌：$CONFIG_DIR/enrollment.token"
fi
echo ""
echo "请确认 $DOMAIN 的 A/AAAA 记录已指向本机，并开放 TCP 80、443、8087。"
