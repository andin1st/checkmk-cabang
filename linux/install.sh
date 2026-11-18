#!/usr/bin/env bash
# =======================================================================
# Bootstrap Installer Agent Checkmk Linux + Custom Local Checks
# Repositori: https://github.com/itlicensehq25/checkmk-cabang
# ===================================================================

set -e

if [ "$(id -u)" -ne 0 ]; then
    echo -e "\033[31m[ERROR] Harap jalankan skrip ini sebagai root (sudo)!\033[0m"
    exit 1
fi

echo -e "\033[32m===============================================================\033[0m"
echo -e "\033[32m Memulai Instalasi Checkmk Agent Linux & Integration Local Checks  \033[0m"
echo -e "\033[32m================================================================\033[0m"

SERVER=""
SITE="cmk"
VERSION="2.5.0p14-1"
GITHUB_REPO="itlicensehq25/checkmk-cabang"
BRANCH="main"

if [ -z "$1" ]; then
    read -p "Masukkan IP Server & Port Checkmk Cabang (contoh: 192.168.43.188:8080): " INPUT_SERVER
    SERVER="$INPUT_SERVER"
    
    read -p "Masukkan Site ID Checkmk [Default: $SITE]: " INPUT_SITE
    if [ -n "$INPUT_SITE" ]; then
        SITE="$INPUT_SITE"
    fi

    read -p "Masukkan Versi Checkmk Agent (contoh: 2.5.0p14-1) [Default: $VERSION]: " INPUT_VERSION
    if [ -n "$INPUT_VERSION" ]; then
        VERSION="$INPUT_VERSION"
    fi
else
    SERVER="$1"
    [ -n "$2" ] && SITE="$2"
    [ -n "$3" ] && VERSION="$3"
fi

SERVER=$(echo "$SERVER" | sed -e 's|^https\?://||' -e 's|/$||')
SITE=$(echo "$SITE" | sed -e 's|^/||' -e 's|/$||')
CLEAN_IP=$(echo "$SERVER" | cut -d':' -f1)

echo -e "\n\033[33m[Informasi Target Server]\033[0m"
echo "  - Server IP   : $SERVER"
echo "  - Site ID     : $SITE"
echo "  - Agent Ver   : $VERSION"

AGENT_DIR="/etc/check_mk"
LOCAL_DIR="/usr/lib/check_mk_agent/local"
PLUGINS_DIR="/usr/lib/check_mk_agent/plugins"
LOG_CUSTOM_DIR="/var/lib/check_mk_agent/log_custom"

mkdir -p "$AGENT_DIR" "$LOCAL_DIR" "$PLUGINS_DIR" "$LOG_CUSTOM_DIR"

USER_YML="$AGENT_DIR/check_mk.user.yml"
cat << 'EOF_YML > "$USER_YML"
global:
  sections:
    enabled:
      - local
      - plugins
    disabled:
      - cpu
      - mem
      - df
      - diskstat
      - kernel
      - md
      - mount
      - netif
      - statgrab
      - uptime
      - users
      - vmstat
      - systemd
      - processes
EOF_YML

echo -e "\033[32m[+] Konfigurasi $USER_YML berhasil dibuat (Hanya Local Checks & Plugins).\033[0m"

echo -e "\n\033[36m[1/5]Mengonfigurasi Aturan Firewall (TCP 6556)...\033[0m"
if command -v ufw >/dev/null 2>&1 && ufw status | grep -q "active"; then
    ufw allow from "$CLEAN_IP" to any port 6556 proto tcp comment "Checkmk Agent TCP 6556" >/dev/null 2>&1 || true
    echo -e "\033[32m  + UFW Firewall dikonfigurasi untuk IP: $CLEAN_IP\033[0m"
elif command -v firewall-cmd >/dev/null 2>&1 && systemctl is-active --quiet firewalld; then
    firewall-cmd --permanent --add-rich-rule="rule family='ipv4' source address='$CLEAN_IP' port port='6556' protocol='tcp' accept" >/dev/null 2>&1 || true
    firewall-cmd --reload >/dev/null 2>&1 || true
    echo -e "\033[32m  + Firewalld dikonfigurasi untuk IP: $CLEAN_IP\033[0m"
fi

echo -e "\n\033[36m[2/5] Memeriksa status check_mk_agent...\033[0m"
if ! command -v check_mk_agent >/dev/null 2>&1; then
    echo -e "\033[33m Agen Checkmk belum terpasang. Mengunduh paket installer dari server cabang...\033[0m"
    TEMP_PKG="/tmp/check-mk-agent-installer"
    CLEAN_VER=$(echo "$VERSION" | sed 's/-.*//')

    CANDIDATES=(
        "http://$SERVER/$SITE/check_mk/agents/check-mk-agent_${VERSION}_all.deb"
        "http://$SERVER/$SITE/check_mk/agents/check-mk-agent-${VERSION}.noarch.rpm"
        "http://$SERVER/$SITE/check_mk/agents/check-mk-agent_${CLEAN_VER}_all.deb"
        "http://$SERVER/$SITE/check_mk/agents/check-mk-agent-${CLEAN_VER}.noarch.rpm"
        "http://$SERVER/$SITE/check_mk/agents/check_mk_agent.deb"
        "http://$SERVER/$SITE/check_mk/agents/check_mk_agent.rpm"
    )

    DOWNLOADED=false
    for URL in "${CANDIDATES[@]}"; do
        echo -e "\033[90m  [-] Mencoba unduh dari: $URL ...\033[0m"
        if curl -sSL -m 15 --insecure "$URL" -o "$TEMP_PKG"; then
            if [ -s "$TEMP_PKG" ] && [ $(stat -c%s "$TEMP_PKG" 2>/dev/null || stat -f%z "$TEMP_PKG" 2>/dev/null || echo 0) -gt 500000 ]; then
                DOWNLOADED=true
                echo -e "\033[32m  [+] Berhasil mengunduh paket dari: $URL\033[0m"
                break
            fi
        fi
        rm -f "$TEMP_PKG"
    done

    if [ "$DOWNLOADED" = true ]; then
        if command -v dpkg >/dev/null 2>&1; then
            dpkg -i "$TEMP_PKG" || yum install -y "$TEMP_PKG" || dnf install -y "$TEMP_PKG" || true
        elif command -v rpm >/dev/null 2>&1; then
            rpm -Uvh --force "$TEMP_PKG" || yum install -y "$TEMP_PKG" || true
        fi
        rm -f "$TEMP_PKG" 
        echo -e "\033[32m Paket agen Checkmk berhasil terpasang.\033[0m"
    fi
else
    echo -e "\033[32m Agen Checkmk sudah terpasang di sistem Linux.\033[0m"
fi

echo -e "\n\033[36m[3/5]Mengunduh Skrip Local Checks & Plugins dari GitHub...\033[0m"
BASE_URL="https://raw.githubusercontent.com/$GITHUB_REPO/$BRANCH/linux"

CHECKS=(
    "cpu_info.sh"
    "ram_usage.sh"
    "storage_usage.sh"
    "disk_nvme_health.sh"
    "info_network.sh"
    "remote_access_id.sh"
)

for SCRIPT in "${CHECKS[@]}"; do
    if curl -sSL -m 10 "$BASE_URL/local_checks/$SCRIPT" -o "$LOCAL_DIR/$SCRIPT"; then
        chmod +x "$LOCAL_DIR/$SCRIPT"
        echo -e "\033[90m  + Unduh local_checks/$SCRIPT [OK]\033[0m"
    else
        echo -e "\033[33m  - Gagal mengunduh local_checks/$SCRIPT\033[0m"
    fi
done

echo -e "\n\033[36m[4/5]Mengatur Izin Eksekusi Skrip...\033[0m"
chmod +x "$LOCAL_DIR"/* 2>/dev/null || true
chmod +x "$PLUGINS_DIR"/* 2>/dev/null || true

echo -e "\n\033[36m[5/5]Memverifikasi & Restart Service/Socket Checkmk Agent...\033[0m"
if systemctl list-unit-files | grep -q "check-mk-agent.socket"; then
    systemctl daemon-reload
    systemctl enable --now check-mk-agent.socket
    systemctl restart check-mk-agent.socket
elif systemctl list-unit-files | grep -q "xinetd"; then
    systemctl restart xinetd
fi

echo -e "\n\033[32m=================================================================\033[0m"
echo -e "\033[32m INSTALASI SELESAI SUCCESSFUL!                             \033[0m"
echo -e "\033[32m Agen Checkmk Linux telah terpasang dan dikonfigurasi HANYA untuk    \033[0m"
echo -e "\033[32m menjalankan local checks & plugins buatan Anda.                 \033[0m"
echo -e "\033[32m================================================================\033[0m"
