#!/usr/bin/env bash
IFS=$'\n\t'
set -euo pipefail

. /etc/os-release 2>/dev/null || true
OS_FAMILY="${ID_LIKE:-} ${ID:-}"

case "$OS_FAMILY" in
	*debian*|*ubuntu*)
		PM=apt
		;;
	*rhel*|*fedora*|*centos*|*rocky*|*almalinux*|*ol*|*amzn*)
		PM=dnf
		;;
	*suse*|*sles*|*opensuse*)
		PM=zypper
		;;
	*alpine*)
		PM=apk
		;;
	*)
		PM=unknown
		;;
esac

if [ "${PM}" == "unknown" ]; then
	echo "Error: OS is not supported"
	exit 1
fi

# Variables
PORT="50551"
ENV="prod"
RUN_NGINX="true"
SERVER_NAME=""
EMAIL=""

PARSED_FLAGS=$(getopt -o e:p:r:s:m: --long env:,port:,run-nginx:,server-name:,email: -- "$@")
eval set -- "${PARSED_FLAGS}"

while true; do
	case "$1" in
		-e|--env) ENV="$2"; shift 2;;
		-p|--port) PORT="$2"; shift 2;;
		-r|--run-nginx) RUN_NGINX="$2"; shift 2;;
		-s|--server-name) SERVER_NAME="$2"; shift 2;;
		-m|--email) EMAIL="$2"; shift 2;;
		--) shift; break;;
	esac
done

if [ -z "${ENV}" ]; then
	echo "Error: Environment is not set"
	exit 1
fi

if [ -z "${SERVER_NAME}" ]; then
	echo "Error: Server name is not set"
	exit 1
fi

if [ -z "${EMAIL}" ]; then
	echo "Error: Email is not set"
	exit 1
fi

if [ "${RUN_NGINX}" == "true" ]; then
	if lsof -i :${PORT} > /dev/null; then
		echo "Error: Port ${PORT} is already in use"
		exit 1
	fi
fi

if command -v nginx >> /dev/null; then
	echo "Nginx binary found"
else
	if $PM update && $PM install -y nginx >> /dev/null; then
		echo "Nginx installed"
		if systemctl enable nginx >> /dev/null; then
			echo "Nginx enabled"
		else
			echo "Error: Nginx enable failed"
			exit 1
		fi
		if systemctl start nginx >> /dev/null; then
			echo "Nginx started"
		else
			echo "Error: Nginx start failed"
			exit 1
		fi
	else
		echo "Error: Nginx installation failed"
		exit 1
	fi
fi

CONFIG_PATH="/etc/nginx/sites-available/${SERVER_NAME}"
ENABLED_PATH="/etc/nginx/sites-enabled/${SERVER_NAME}"
UPSTREAM_URL="http://localhost:${PORT}"
WEBROOT_DIR="/var/www/${SERVER_NAME}"

mkdir -p "${WEBROOT_DIR}/.well-known/acme-challenge"

mkdir -p /etc/nginx/sites-available /etc/nginx/sites-enabled || true

if [ ! -e "${ENABLED_PATH}" ]; then
	sudo ln -s "${CONFIG_PATH}" "${ENABLED_PATH}" >> /dev/null || true
fi

sudo tee "${CONFIG_PATH}" <<EOF > /dev/null
server {
	listen 80;
	server_name ${SERVER_NAME};

	root ${WEBROOT_DIR};

	location ^~ /.well-known/acme-challenge/ {
		root ${WEBROOT_DIR};
		default_type "text/plain";
	}

	location / {
		return 200 'OK';
		add_header Content-Type text/plain;
	}
}
EOF

if nginx -t >> /dev/null; then
	echo "Nginx temporary HTTP config is valid"
	systemctl reload nginx
else
	echo "Error: Nginx temporary config is invalid"
	exit 1
fi

if command -v certbot >> /dev/null; then
	echo "package certbot installed"
else
	if $PM install -y certbot python3-certbot-nginx >> /dev/null; then
		echo "package certbot installed"
	else
		echo "ERROR: package certbot installation failed"
		exit 1
	fi
fi

SSL_PATH_ROOT="/etc/letsencrypt"
if [[ -f "${SSL_PATH_ROOT}/live/${SERVER_NAME}/fullchain.pem" ]] && [[ -f "${SSL_PATH_ROOT}/live/${SERVER_NAME}/privkey.pem" ]]; then
	echo "CERTIFICATE ${SERVER_NAME} exists"
else
	if certbot certonly --webroot -w "${WEBROOT_DIR}" -d "${SERVER_NAME}" \
		--email "${EMAIL}" --agree-tos --no-eff-email --non-interactive >> /dev/null; then
		echo "CERTIFICATE ${SERVER_NAME} installed"
	else
		echo "ERROR: CERTIFICATE ${SERVER_NAME} installation failed"
		exit 1
	fi
fi

sudo tee "${CONFIG_PATH}" <<EOF > /dev/null
 server {

	listen 443 ssl;
	server_name ${SERVER_NAME};

	ssl_certificate /etc/letsencrypt/live/${SERVER_NAME}/fullchain.pem;
	ssl_certificate_key /etc/letsencrypt/live/${SERVER_NAME}/privkey.pem;
	include /etc/letsencrypt/options-ssl-nginx.conf;
	ssl_dhparam /etc/letsencrypt/ssl-dhparams.pem;

	location / {
		add_header 'Access-Control-Allow-Origin' 'https://${SERVER_NAME}' always;
		add_header 'Access-Control-Allow-Methods' 'GET, POST, PUT, DELETE, OPTIONS' always;
		add_header 'Access-Control-Allow-Headers' 'Content-Type, Authorization, App-Device' always;

		if (\$request_method = 'OPTIONS') {
			add_header 'Access-Control-Allow-Origin' 'https://${SERVER_NAME}' always;
			add_header 'Access-Control-Allow-Methods' 'GET, POST, PUT, DELETE, OPTIONS' always;
			add_header 'Access-Control-Allow-Headers' 'Content-Type, Authorization, App-Device' always;
			add_header 'Access-Control-Max-Age' 1728000;
			return 204;
		}

		proxy_pass ${UPSTREAM_URL};

		proxy_set_header Host \$host;
		proxy_set_header Grpc-Metadata-X-Real-IP \$remote_addr;
		proxy_set_header Grpc-Metadata-User-Agent \$http_user_agent;
		proxy_set_header X-Real-IP \$remote_addr;
		proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
		proxy_set_header X-Forwarded-Proto \$scheme;

		proxy_http_version 1.1;
		proxy_set_header Upgrade \$http_upgrade;
		proxy_set_header Connection "upgrade";
		proxy_set_header TE "trailers";
		proxy_read_timeout 300s;
		proxy_connect_timeout 75s;
	}
}

server {
	listen 80;
	server_name ${SERVER_NAME};

	root ${WEBROOT_DIR};

	# Serve ACME HTTP-01 for renewals without redirect
	location ^~ /.well-known/acme-challenge/ {
		root ${WEBROOT_DIR};
		default_type "text/plain";
	}

	location / {
		return 301 https://\$host\$request_uri;
	}
}
EOF

if nginx -t >> /dev/null; then
	echo "Nginx configuration is valid"
else
	echo "Error: Nginx configuration is invalid"
	exit 1
fi

if [ "${RUN_NGINX}" == "true" ]; then
	if systemctl restart nginx >> /dev/null; then
		echo "Nginx restarted"
	else
		echo "Error: Nginx restart failed"
		exit 1
	fi
fi