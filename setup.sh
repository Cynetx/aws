#!/usr/bin/env bash
set -euo pipefail

# ==============================================================================
# Automated Anti-Ban 3X-UI (Reality + WARP) Deployment Script for AWS EC2
# ==============================================================================

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

log_info()  { echo -e "${CYAN}[INFO]${NC} $1"; }
log_ok()    { echo -e "${GREEN}[OK]${NC} $1"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_err()   { echo -e "${RED}[ERROR]${NC} $1"; exit 1; }

# Ensure root privileges
if [[ $EUID -ne 0 ]]; then
    exec sudo bash "$0" "$@"
fi

# Configuration variables (can be overridden via environment variables)
PANEL_PORT="${PANEL_PORT:-2053}"
PANEL_USER="${PANEL_USER:-admin_$(openssl rand -hex 3)}"
PANEL_PASS="${PANEL_PASS:-$(openssl rand -base64 14 | tr -dc 'A-Za-z0-9' | head -c 16)}"
WEB_PATH="${WEB_PATH:-panel$(openssl rand -hex 4)}"
REALITY_PORT_1=443
REALITY_SNI_1="www.spotify.com"
REALITY_PORT_2=8443
REALITY_SNI_2="dl.google.com"
GRPC_SERVICE="stream$(openssl rand -hex 3)"
CRED_FILE="/root/vpn-credentials.txt"

# 1. Detect Public IP (AWS IMDSv2 first, fallback to external services)
log_info "Detecting server public IP address..."
IMDS_TOKEN=$(curl -s -m 2 -X PUT "http://169.254.169.254/latest/api/token" \
    -H "X-aws-ec2-metadata-token-ttl-seconds: 60" || true)
if [[ -n "$IMDS_TOKEN" ]]; then
    SERVER_IP=$(curl -s -m 2 -H "X-aws-ec2-metadata-token: $IMDS_TOKEN" \
        "http://169.254.169.254/latest/meta-data/public-ipv4" || true)
fi
if [[ -z "${SERVER_IP:-}" ]]; then
    SERVER_IP=$(curl -s -m 5 https://api.ipify.org || curl -s -m 5 https://ifconfig.me)
fi
[[ -z "$SERVER_IP" ]] && log_err "Failed to detect public IP address."
log_ok "Public IP detected: $SERVER_IP"

# 2. Update OS and install required packages
log_info "Updating system packages and installing dependencies..."
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq curl wget socat ufw jq openssl sqlite3 wireguard-tools qrencode >/dev/null
log_ok "System packages installed."

# 3. Enable TCP BBR congestion control
log_info "Enabling Google TCP BBR..."
sed -i '/net.core.default_qdisc/d' /etc/sysctl.conf
sed -i '/net.ipv4.tcp_congestion_control/d' /etc/sysctl.conf
cat << 'EOF' >> /etc/sysctl.conf
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
EOF
sysctl -p >/dev/null
log_ok "TCP BBR enabled ($(sysctl -n net.ipv4.tcp_congestion_control))."

# 4. Configure UFW Firewall
log_info "Configuring UFW firewall rules..."
ufw default deny incoming >/dev/null
ufw default allow outgoing >/dev/null
ufw allow 22/tcp >/dev/null
ufw allow ${REALITY_PORT_1}/tcp >/dev/null
ufw allow ${REALITY_PORT_2}/tcp >/dev/null
ufw --force enable >/dev/null
log_ok "UFW enabled (allowed ports: 22, ${REALITY_PORT_1}, ${REALITY_PORT_2})."

# 5. Install 3X-UI Panel non-interactively
log_info "Installing 3X-UI panel..."
printf "n\n" | bash <(curl -Ls https://raw.githubusercontent.com/mhsanaei/3x-ui/master/install.sh) >/dev/null 2>&1 || true

[[ ! -f /usr/local/x-ui/x-ui ]] && log_err "3X-UI installation failed."
log_ok "3X-UI binary installed."

# 6. Configure 3X-UI credentials, port, secret path, and bind to localhost
log_info "Hardening 3X-UI panel settings (binding to 127.0.0.1)..."
systemctl stop x-ui || true
/usr/local/x-ui/x-ui setting -username "$PANEL_USER" -password "$PANEL_PASS" -port "$PANEL_PORT" -webBasePath "$WEB_PATH" >/dev/null
/usr/local/x-ui/x-ui setting -listenIP 127.0.0.1 >/dev/null 2>&1 || true

# Ensure webListen is strictly 127.0.0.1 in SQLite DB
if [[ -f /etc/x-ui/x-ui.db ]]; then
    sqlite3 /etc/x-ui/x-ui.db "INSERT OR REPLACE INTO settings (key, value) VALUES ('webListen', '127.0.0.1');"
fi

systemctl enable x-ui >/dev/null 2>&1
systemctl start x-ui
sleep 3
log_ok "3X-UI panel secured on 127.0.0.1:${PANEL_PORT}/${WEB_PATH}/"

# 7. Generate Reality X25519 Keypair and UUIDs
log_info "Generating Reality X25519 keys and UUIDs..."
XRAY_BIN=$(find /usr/local/x-ui/bin -maxdepth 1 -type f -name "xray-linux-*" | head -n 1)
[[ -z "$XRAY_BIN" ]] && log_err "Xray binary not found."

X25519_OUT=$("$XRAY_BIN" x25519)
PRIVATE_KEY=$(echo "$X25519_OUT" | awk -F': ' '/Private/ {print $2}' | tr -d ' \r\n')
PUBLIC_KEY=$(echo "$X25519_OUT" | awk -F': ' '/Public|Password/ {print $2}' | tr -d ' \r\n')
[[ -z "$PRIVATE_KEY" || -z "$PUBLIC_KEY" ]] && log_err "Failed to generate X25519 keys."

SHORT_ID=$(openssl rand -hex 8)
UUID_1=$(cat /proc/sys/kernel/random/uuid)
UUID_2=$(cat /proc/sys/kernel/random/uuid)
log_ok "Reality keys generated."

# 8. Register Free Cloudflare WARP WireGuard Account
log_info "Registering Cloudflare WARP WireGuard credentials..."
WARP_PRIV=$(wg genkey)
WARP_PUB=$(echo "$WARP_PRIV" | wg pubkey)
TOS_DATE=$(date -u +%Y-%m-%dT%H:%M:%S.000Z)

WARP_RESP=$(curl -s -m 15 -X POST "https://api.cloudflareclient.com/v0a2158/reg" \
    -H "Content-Type: application/json" \
    -H "User-Agent: okhttp/3.12.1" \
    -d "{\"key\":\"${WARP_PUB}\",\"install_id\":\"\",\"fcm_token\":\"\",\"tos\":\"${TOS_DATE}\",\"model\":\"Android\",\"serial_number\":\"${WARP_PUB}\",\"locale\":\"en_US\"}" || true)

WARP_V4=$(echo "$WARP_RESP" | jq -r '.config.interface.addresses.v4 // empty' 2>/dev/null || true)
WARP_V6=$(echo "$WARP_RESP" | jq -r '.config.interface.addresses.v6 // empty' 2>/dev/null || true)
WARP_PEER_PUB=$(echo "$WARP_RESP" | jq -r '.config.peers[0].public_key // empty' 2>/dev/null || true)
WARP_CLIENT_ID=$(echo "$WARP_RESP" | jq -r '.config.client_id // empty' 2>/dev/null || true)

USE_WARP=false
if [[ -n "$WARP_V4" && -n "$WARP_PEER_PUB" && -n "$WARP_CLIENT_ID" ]]; then
    WARP_RESERVED=$(echo "$WARP_CLIENT_ID" | base64 -d | od -An -t u1 | awk '{print "["$1","$2","$3"]"}')
    USE_WARP=true
    log_ok "Cloudflare WARP account registered (IP: $WARP_V4)."
else
    log_warn "Cloudflare WARP API rate-limited; falling back to direct freedom outbound."
fi

# 9. Authenticate to 3X-UI Local API
log_info "Configuring Xray outbounds, anti-ban routing, and inbounds via API..."
COOKIE_JAR=$(mktemp)
BASE_URL="http://127.0.0.1:${PANEL_PORT}/${WEB_PATH}"

LOGIN_RES=$(curl -s -c "$COOKIE_JAR" -X POST "${BASE_URL}/login" \
    -H "Content-Type: application/json" \
    -d "{\"username\":\"${PANEL_USER}\",\"password\":\"${PANEL_PASS}\"}")

if ! echo "$LOGIN_RES" | grep -q '"success":true'; then
    rm -f "$COOKIE_JAR"
    log_err "Failed to authenticate with 3X-UI local API."
fi

# 10. Configure Outbounds and Anti-Ban Routing Rules
if [[ "$USE_WARP" == true ]]; then
    OUTBOUND_TAG="warp"
    OUTBOUNDS_JSON=$(jq -n \
        --arg priv "$WARP_PRIV" \
        --arg v4 "${WARP_V4}/32" \
        --arg v6 "${WARP_V6}/128" \
        --arg peer "$WARP_PEER_PUB" \
        --argjson res "$WARP_RESERVED" \
        '[
            {
                "tag": "warp",
                "protocol": "wireguard",
                "settings": {
                    "secretKey": $priv,
                    "address": [$v4, $v6],
                    "peers": [{
                        "publicKey": $peer,
                        "endpoint": "engage.cloudflareclient.com:2408"
                    }],
                    "reserved": $res,
                    "mtu": 1280
                }
            },
            {
                "tag": "direct",
                "protocol": "freedom",
                "settings": {"domainStrategy": "UseIP"}
            },
            {
                "tag": "block",
                "protocol": "blackhole",
                "settings": {}
            }
        ]')
else
    OUTBOUND_TAG="direct"
    OUTBOUNDS_JSON='[
        {"tag": "direct", "protocol": "freedom", "settings": {"domainStrategy": "UseIP"}},
        {"tag": "block", "protocol": "blackhole", "settings": {}}
    ]'
fi

XRAY_TEMPLATE=$(jq -n \
    --argjson outbounds "$OUTBOUNDS_JSON" \
    --arg defaultOut "$OUTBOUND_TAG" \
    '{
        "log": {"loglevel": "warning"},
        "routing": {
            "domainStrategy": "IPIfNonMatch",
            "rules": [
                {"type": "field", "protocol": ["bittorrent"], "outboundTag": "block"},
                {"type": "field", "ip": ["geoip:private"], "outboundTag": "block"},
                {"type": "field", "domain": ["geosite:category-ir"], "outboundTag": "block"},
                {"type": "field", "ip": ["geoip:ir"], "outboundTag": "block"},
                {"type": "field", "network": "tcp,udp", "outboundTag": $defaultOut}
            ]
        },
        "inbounds": [],
        "outbounds": $outbounds
    }')

curl -s -b "$COOKIE_JAR" -X POST "${BASE_URL}/panel/xray/update" \
    -d "xraySetting=$(jq -rn --arg x "$XRAY_TEMPLATE" '$x|@uri')" >/dev/null
log_ok "Anti-ban routing rules (Torrent & IR block + WARP outbound) applied."

# 11. Create Inbound 1: VLESS + TCP + Reality + Vision (Port 443)
SETTINGS_1=$(jq -n --arg uuid "$UUID_1" '{
    "clients": [{"id": $uuid, "flow": "xtls-rprx-vision", "email": "aws-vision-443", "enable": true}],
    "decryption": "none",
    "fallbacks": []
}' | jq -c .)

STREAM_1=$(jq -n \
    --arg dest "${REALITY_SNI_1}:443" \
    --arg sni "$REALITY_SNI_1" \
    --arg priv "$PRIVATE_KEY" \
    --arg pub "$PUBLIC_KEY" \
    --arg sid "$SHORT_ID" \
    '{
        "network": "tcp",
        "security": "reality",
        "realitySettings": {
            "show": false,
            "xver": 0,
            "dest": $dest,
            "serverNames": [$sni],
            "privateKey": $priv,
            "minClient": "",
            "maxClient": "",
            "maxTimediff": 0,
            "shortIds": [$sid],
            "settings": {
                "publicKey": $pub,
                "fingerprint": "chrome",
                "serverName": "",
                "spiderX": "/"
            }
        },
        "tcpSettings": {"acceptProxyProtocol": false, "header": {"type": "none"}}
    }' | jq -c .)

SNIFFING_JSON='{"enabled":true,"destOverride":["http","tls","quic","fakedns"],"metadataOnly":false,"routeOnly":false}'

curl -s -b "$COOKIE_JAR" -X POST "${BASE_URL}/panel/inbound/add" \
    --data-urlencode "up=0" \
    --data-urlencode "down=0" \
    --data-urlencode "total=0" \
    --data-urlencode "remark=AWS-Reality-Vision-443" \
    --data-urlencode "enable=true" \
    --data-urlencode "expiryTime=0" \
    --data-urlencode "listen=" \
    --data-urlencode "port=${REALITY_PORT_1}" \
    --data-urlencode "protocol=vless" \
    --data-urlencode "settings=${SETTINGS_1}" \
    --data-urlencode "streamSettings=${STREAM_1}" \
    --data-urlencode "sniffing=${SNIFFING_JSON}" >/dev/null
log_ok "Inbound 1 created: VLESS + TCP + Reality + Vision (Port ${REALITY_PORT_1})."

# 12. Create Inbound 2: VLESS + gRPC + Reality (Port 8443 Backup)
SETTINGS_2=$(jq -n --arg uuid "$UUID_2" '{
    "clients": [{"id": $uuid, "flow": "", "email": "aws-grpc-8443", "enable": true}],
    "decryption": "none",
    "fallbacks": []
}' | jq -c .)

STREAM_2=$(jq -n \
    --arg dest "${REALITY_SNI_2}:443" \
    --arg sni "$REALITY_SNI_2" \
    --arg priv "$PRIVATE_KEY" \
    --arg pub "$PUBLIC_KEY" \
    --arg sid "$SHORT_ID" \
    --arg svc "$GRPC_SERVICE" \
    '{
        "network": "grpc",
        "security": "reality",
        "realitySettings": {
            "show": false,
            "xver": 0,
            "dest": $dest,
            "serverNames": [$sni],
            "privateKey": $priv,
            "minClient": "",
            "maxClient": "",
            "maxTimediff": 0,
            "shortIds": [$sid],
            "settings": {
                "publicKey": $pub,
                "fingerprint": "chrome",
                "serverName": "",
                "spiderX": "/"
            }
        },
        "grpcSettings": {"serviceName": $svc, "multiMode": false, "idle_timeout": 60, "health_check_timeout": 20}
    }' | jq -c .)

curl -s -b "$COOKIE_JAR" -X POST "${BASE_URL}/panel/inbound/add" \
    --data-urlencode "up=0" \
    --data-urlencode "down=0" \
    --data-urlencode "total=0" \
    --data-urlencode "remark=AWS-Reality-gRPC-8443" \
    --data-urlencode "enable=true" \
    --data-urlencode "expiryTime=0" \
    --data-urlencode "listen=" \
    --data-urlencode "port=${REALITY_PORT_2}" \
    --data-urlencode "protocol=vless" \
    --data-urlencode "settings=${SETTINGS_2}" \
    --data-urlencode "streamSettings=${STREAM_2}" \
    --data-urlencode "sniffing=${SNIFFING_JSON}" >/dev/null
log_ok "Inbound 2 created: VLESS + gRPC + Reality (Port ${REALITY_PORT_2})."

# Restart panel and Xray core to apply all settings
rm -f "$COOKIE_JAR"
systemctl restart x-ui
sleep 2

# Build client VLESS URIs
VLESS_LINK_1="vless://${UUID_1}@${SERVER_IP}:${REALITY_PORT_1}?type=tcp&security=reality&pbk=${PUBLIC_KEY}&fp=chrome&sni=${REALITY_SNI_1}&sid=${SHORT_ID}&spx=%2F&flow=xtls-rprx-vision#AWS-Reality-Vision-443"
VLESS_LINK_2="vless://${UUID_2}@${SERVER_IP}:${REALITY_PORT_2}?type=grpc&serviceName=${GRPC_SERVICE}&security=reality&pbk=${PUBLIC_KEY}&fp=chrome&sni=${REALITY_SNI_2}&sid=${SHORT_ID}&spx=%2F#AWS-Reality-gRPC-8443"

# Save credentials to file
cat << EOF > "$CRED_FILE"
====================================================================
AWS 3X-UI Deployment Summary
====================================================================
Server IP       : ${SERVER_IP}
WARP Outbound   : ${USE_WARP}
SSH Tunnel Cmd  : ssh -N -L ${PANEL_PORT}:127.0.0.1:${PANEL_PORT} -i your-key.pem ubuntu@${SERVER_IP}
Panel Local URL : http://127.0.0.1:${PANEL_PORT}/${WEB_PATH}/
Username        : ${PANEL_USER}
Password        : ${PANEL_PASS}

[Config 1 - Primary High-Speed Vision (Port 443)]
${VLESS_LINK_1}

[Config 2 - Anti-Filtering Backup gRPC (Port 8443)]
${VLESS_LINK_2}
====================================================================
EOF
chmod 600 "$CRED_FILE"

# Print Final Output
echo ""
echo -e "${GREEN}====================================================================${NC}"
echo -e "${GREEN}             DEPLOYMENT COMPLETED SUCCESSFULLY                      ${NC}"
echo -e "${GREEN}====================================================================${NC}"
echo -e "${CYAN}Panel Local URL :${NC} http://127.0.0.1:${PANEL_PORT}/${WEB_PATH}/"
echo -e "${CYAN}Username        :${NC} ${PANEL_USER}"
echo -e "${CYAN}Password        :${NC} ${PANEL_PASS}"
echo -e "${CYAN}WARP Status     :${NC} ${USE_WARP}"
echo ""
echo -e "${YELLOW}[Step 1] Run this SSH Tunnel command on your PC to open the panel:${NC}"
echo -e "ssh -N -L ${PANEL_PORT}:127.0.0.1:${PANEL_PORT} -i norah.pem ubuntu@${SERVER_IP}"
echo ""
echo -e "${YELLOW}[Config 1] VLESS + Reality + Vision (Port 443 - High Speed):${NC}"
echo -e "${VLESS_LINK_1}"
echo ""
qrencode -t ansiutf8 "${VLESS_LINK_1}"
echo ""
echo -e "${YELLOW}[Config 2] VLESS + Reality + gRPC (Port 8443 - Backup):${NC}"
echo -e "${VLESS_LINK_2}"
echo ""
qrencode -t ansiutf8 "${VLESS_LINK_2}"
echo -e "${GREEN}Saved credentials to: ${CRED_FILE}${NC}"
