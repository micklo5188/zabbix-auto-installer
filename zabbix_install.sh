#!/bin/bash
# ==============================================================================
# ZABBIX UNIVERSAL AUTO-INSTALLER
# Author:Mech Boy
# Version: 1.0.1
# Description: Automated, foolproof Zabbix deployment
# Support: Debian, Ubuntu, Oracle Linux, RHEL, CentOS, Alma, Rocky, Amazon,
#          OpenSUSE Leap, SLES, Raspberry Pi OS/Raspbian
# ==============================================================================

# ====== FIX PATH (Debian minimal / su / entornos sin sbin en PATH) ======
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:$PATH"

# ====== COLORES Y VARIABLES GLOBALES ======
R=$(tput setaf 1); G=$(tput setaf 2); Y=$(tput setaf 3)
B=$(tput setaf 4); C=$(tput setaf 6); N=$(tput sgr0); BOLD=$(tput bold)
LOG_FILE="/tmp/zbx_install.log"
VALID_FILE="/tmp/zbx_valid.txt"
START_TIME=$(date +%s)
ENABLE_SSL="n"

WEB_PORT="80"
IP_ADDR=""

# Docker host ports (dinámicos)
DOCKER_WEB_PORT="80"
DOCKER_ZBX_PORT="10051"
DOCKER_AGENT_PORT="10050"

# Docker extra (proxy/agent)
DOCKER_INSTANCE_ID=""        # ID único por despliegue Docker (multi-instancia)
DOCKER_WORKDIR=""            # Directorio compose por instancia
ZBX_SERVER_PORT="10051"      # Puerto del Zabbix Server maestro (Docker Proxy/Agent)
DOCKER_PROXYMODE="0"         # 0=active, 1=passive

# ====== MANEJO DE INTERRUPCIONES (CTRL+C) ======
trap 'cleanup_on_exit' SIGINT

cleanup_on_exit() {
    tput cnorm
    rm -f "$LOG_FILE" "$VALID_FILE" /tmp/zbx_*.tmp zbx.deb zbx.rpm get-docker.sh
    echo -e "\n\n${R}█▓▒░ Instalación cancelada por el usuario (SIGINT). Limpiando temporales...${N}\n"
    exit 1
}

# ====== INTERFAZ GRÁFICA ======
print_ascii_logo() {
    clear
    echo -e "${C}${BOLD}"
    echo '  ███████╗ █████╗ ██████╗ ██████╗ ██╗██╗  ██╗'
    echo '  ╚══███╔╝██╔══██╗██╔══██╗██╔══██╗██║╚██╗██╔╝'
    echo '    ███╔╝ ███████║██████╔╝██████╔╝██║ ╚███╔╝ '
    echo '   ███╔╝  ██╔══██║██╔══██╗██╔══██╗██║ ██╔██╗ '
    echo '  ███████╗██║  ██║██████╔╝██████╔╝██║██╔╝ ██╗'
    echo '  ╚══════╝╚═╝  ╚═╝╚═════╝ ╚═════╝ ╚═╝╚═╝  ╚═╝'
    echo -e "${N}"
    echo -e "${B}================================================================================${N}"
    echo -e "${BOLD}  UNIVERSAL AUTO-INSTALLER v1.0.1 | by FW-Mech Boy${N}"
    echo -e "${B}================================================================================${N}\n"
}

msg() { echo -e "${1}$2${N}"; }
fail() { tput cnorm; echo ""; msg "$R" "█▓▒░ ERROR CRÍTICO: $1"; exit 1; }

> "$LOG_FILE"
> "$VALID_FILE"

# ====== MOTOR GRÁFICO: BARRAS ALINEADAS ======
task_progress_bar() {
    local title="$1"
    local func="$2"
    local pid

    local padded_title
    padded_title=$(printf "%-40.40s" "$title")   # FIX: recorta a 40 chars para no correr barras
    local bar_len=38
    local bar_char="█"
    local empty_char="░"

    $func >> "$LOG_FILE" 2>&1 &
    pid=$!

    tput civis
    local pct=0
    local delay=0.2

    while kill -0 $pid 2>/dev/null; do
        if [ $pct -lt 99 ]; then pct=$((pct + 1)); fi
        local filled_len=$(( (pct * bar_len) / 100 ))
        local empty_len=$(( bar_len - filled_len ))

        local filled=""
        local empty=""
        [[ $filled_len -gt 0 ]] && filled=$(printf "%${filled_len}s" | tr ' ' "$bar_char")
        [[ $empty_len -gt 0 ]] && empty=$(printf "%${empty_len}s" | tr ' ' "$empty_char")

        printf "\r ${C}[BUSY]${N} %s ${B}[${G}%s${C}%s${B}]${N} %3d%% " "$padded_title" "$filled" "$empty" "$pct"
        sleep $delay
    done

    wait $pid
    local status=$?
    printf "\r\033[K"

    local full_bar
    full_bar=$(printf "%${bar_len}s" | tr ' ' "$bar_char")
    if [ $status -eq 0 ]; then
        printf " ${G}[ OK ]${N} %s ${B}[${G}%s${B}]${N} 100%%\n" "$padded_title" "$full_bar"
    else
        printf " ${R}[FAIL]${N} %s ${B}[${R}%s${B}]${N} ERR%%\n\n" "$padded_title" "$full_bar"
        msg "${Y}⚠️  EL PROCESO FALLÓ. ÚLTIMAS LÍNEAS DEL LOG:${N}"
        echo "--------------------------------------------------------------------------------"
        tail -n 160 "$LOG_FILE"
        echo "--------------------------------------------------------------------------------"
        fail "Revise el error en el log o pruebe con una versión de Zabbix distinta."
    fi
    tput cnorm
}

# ====== HELPERS ======
have_systemd() {
    command -v systemctl >/dev/null 2>&1 || return 1
    systemctl list-unit-files >/dev/null 2>&1 && return 0
    return 1
}

svc_enable_start() {
    local svc="$1"
    if have_systemd; then
        systemctl enable --now "$svc" >/dev/null 2>&1 && return 0
        systemctl start "$svc" >/dev/null 2>&1 && return 0
    fi
    if command -v service >/dev/null 2>&1; then
        service "$svc" start >/dev/null 2>&1 && return 0
    fi
    if [ -x "/etc/init.d/$svc" ]; then
        "/etc/init.d/$svc" start >/dev/null 2>&1 && return 0
    fi
    return 1
}

svc_restart_enable() {
    local svc="$1"
    if have_systemd; then
        systemctl restart "$svc" >/dev/null 2>&1 || true
        systemctl enable "$svc" >/dev/null 2>&1 || true
        return 0
    fi
    if command -v service >/dev/null 2>&1; then
        service "$svc" restart >/dev/null 2>&1 || true
        return 0
    fi
    if [ -x "/etc/init.d/$svc" ]; then
        "/etc/init.d/$svc" restart >/dev/null 2>&1 || true
        return 0
    fi
    return 0
}

detect_ip() {
    IP_ADDR=$(hostname -I 2>/dev/null | awk '{print $1}')
    [ -z "$IP_ADDR" ] && IP_ADDR="$(hostname -i 2>/dev/null | awk '{print $1}')"
    [ -z "$IP_ADDR" ] && IP_ADDR="127.0.0.1"
}

sanitize_num() { echo "${1//[^0-9]/}"; }

# --- PORT HELPERS ---
port_listener_line() {
    local port="$1"
    if command -v ss >/dev/null 2>&1; then
        ss -ltnpH 2>/dev/null | awk -v p=":${port}" '$4 ~ p"$" {print; exit}'
        return 0
    elif command -v netstat >/dev/null 2>&1; then
        netstat -ltnp 2>/dev/null | awk -v p=":${port}" '$4 ~ p"$" {print; exit}'
        return 0
    fi
    return 1
}

port_in_use() {
    local port="$1"
    local line
    line="$(port_listener_line "$port" 2>/dev/null || true)"
    [ -n "$line" ] && return 0
    return 1
}

port_proc_name() {
    local port="$1"
    local line
    line="$(port_listener_line "$port" 2>/dev/null || true)"
    [ -z "$line" ] && return 0
    echo "$line" | sed -n 's/.*users:(("\([^"]\+\)".*/\1/p' | head -n 1
}

first_free_port() {
    for p in 80 8080 8000 81 8888 8081; do
        if ! port_in_use "$p"; then
            echo "$p"
            return 0
        fi
    done
    echo "80"
    return 0
}

first_free_port_list() {
    # uso: first_free_port_list 10051 10052 11051 12051
    local p
    for p in "$@"; do
        if ! port_in_use "$p"; then
            echo "$p"
            return 0
        fi
    done
    echo "$1"
    return 0
}

# ====== FIX: si puerto ocupado, usar +10 automáticamente (10050->10060->10070...) ======
step_free_port() {
    # uso: step_free_port 10050 10 60
    local base="$1"
    local step="${2:-10}"
    local tries="${3:-60}"
    local p="$base"
    local i

    for i in $(seq 0 "$tries"); do
        if ! port_in_use "$p"; then
            echo "$p"
            return 0
        fi
        p=$((p + step))
    done

    echo "$base"
    return 0
}

# --- URL selftest (nativo / alias /zabbix) ---
http_selftest() {
    local port="$1"
    local code=""
    local path=""
    for path in "/zabbix/" "/zabbix" "/zabbix/index.php"; do
        code=$(curl -sS -L -o /dev/null -m 6 -w "%{http_code}" "http://127.0.0.1:${port}${path}" 2>/dev/null || true)
        [[ "$code" =~ ^(200|301|302|401)$ ]] && return 0
    done
    return 1
}

# --- Docker selftest (en docker normalmente es /) ---
docker_http_selftest() {
    local port="$1"
    local code=""
    local path=""
    for path in "/" "/index.php" "/zabbix" "/zabbix/"; do
        code=$(curl -sS -L -o /dev/null -m 6 -w "%{http_code}" "http://127.0.0.1:${port}${path}" 2>/dev/null || true)
        [[ "$code" =~ ^(200|301|302|401)$ ]] && return 0
    done
    return 1
}

docker_web_has_db_error() {
    local port="$1"
    curl -fsSL -m 6 "http://127.0.0.1:${port}/" 2>/dev/null | grep -qi "Database error"
}

docker_wait_web_ok() {
    local port="$1"
    local i
    for i in $(seq 1 300); do
        if docker_http_selftest "$port"; then
            if ! docker_web_has_db_error "$port"; then
                return 0
            fi
        fi
        sleep 1
    done
    return 1
}

docker_any_container_bad() {
    local bad
    bad="$(docker ps --filter "name=zabbix" --format '{{.Names}} {{.Status}}' 2>/dev/null | grep -Ei 'Exited|Restarting' | wc -l 2>/dev/null || echo 0)"
    [ "$bad" -gt 0 ] && return 0
    return 1
}

docker_compose_cmd() {
    if command -v docker-compose >/dev/null 2>&1; then
        echo "docker-compose"
    else
        echo "docker compose"
    fi
}

docker_wait_container_healthy() {
    # uso: docker_wait_container_healthy nombre 180
    local name="$1"
    local max="${2:-180}"
    local i st
    for i in $(seq 1 "$max"); do
        st="$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}nohealth{{end}}' "$name" 2>/dev/null || true)"
        if [ "$st" == "healthy" ] || [ "$st" == "nohealth" ]; then
            return 0
        fi
        sleep 1
    done
    return 1
}

docker_wait_db_schema() {
    # espera hasta 300s a que exista la tabla config (Zabbix DB inicializada)
    local max="${1:-300}"
    local i
    for i in $(seq 1 "$max"); do
        if [ "$DB_TYPE" == "mysql" ]; then
            docker exec zabbix-db sh -lc "mysql -uzabbix -p\"$Z_PASS\" -e \"USE zabbix; SELECT 1 FROM config LIMIT 1;\" >/dev/null 2>&1" && return 0
        else
            docker exec zabbix-db sh -lc "psql -U zabbix -d zabbix -c \"SELECT 1 FROM config LIMIT 1;\" >/dev/null 2>&1" && return 0
        fi
        sleep 1
    done
    return 1
}

# --- Docker conflicts: detener SOLO contenedores zabbix que publiquen puertos críticos ---
stop_zabbix_docker_conflicts() {
    command -v docker >/dev/null 2>&1 || return 0
    docker info >/dev/null 2>&1 || return 0

    # Solo parar si elegiste instalación Nativa (Server/Proxy/Agent)
    [[ "$DEPLOY_TYPE" =~ ^[1-3]$ ]] || return 0

    local ids=()
    while read -r id img name ports; do
        [ -z "$id" ] && continue
        if echo "$img" | grep -qi '^zabbix/'; then
            if echo "$ports" | grep -Eq '0\.0\.0\.0:(80|443|10050|10051)->|:::(80|443|10050|10051)->'; then
                ids+=("$id")
            fi
        fi
        if echo "$name" | grep -qi 'zabbix'; then
            if echo "$ports" | grep -Eq '0\.0\.0\.0:(80|443|10050|10051)->|:::(80|443|10050|10051)->'; then
                ids+=("$id")
            fi
        fi
    done < <(docker ps --format '{{.ID}} {{.Image}} {{.Names}} {{.Ports}}' 2>/dev/null || true)

    if [ "${#ids[@]}" -gt 0 ]; then
        local uniq=()
        local seen="|"
        local c
        for c in "${ids[@]}"; do
            if [[ "$seen" != *"|$c|"* ]]; then
                uniq+=("$c"); seen="${seen}${c}|"
            fi
        done
        echo "[INFO] Deteniendo contenedores Zabbix que bloquean puertos (80/443/10050/10051): ${uniq[*]}" >> "$LOG_FILE"
        docker stop "${uniq[@]}" >/dev/null 2>&1 || true
    fi
    return 0
}

# --- Apache/Nginx port configuration ---
apache_set_listen_port() {
    local port="$1"

    [ -f /etc/apache2/ports.conf ] || return 0

    if grep -Eq '^\s*Listen\s+80\b' /etc/apache2/ports.conf; then
        sed -i -E "s/^\s*Listen\s+80\b/Listen ${port}/" /etc/apache2/ports.conf
    elif ! grep -Eq "^\s*Listen\s+${port}\b" /etc/apache2/ports.conf; then
        echo "Listen ${port}" >> /etc/apache2/ports.conf
    fi

    if [ -f /etc/apache2/sites-available/000-default.conf ]; then
        sed -i -E "s/<VirtualHost\s+\*:(80|[0-9]+)>/<VirtualHost *:${port}>/g" /etc/apache2/sites-available/000-default.conf
    fi
    if [ -f /etc/apache2/sites-enabled/000-default.conf ]; then
        sed -i -E "s/<VirtualHost\s+\*:(80|[0-9]+)>/<VirtualHost *:${port}>/g" /etc/apache2/sites-enabled/000-default.conf
    fi
    return 0
}

nginx_set_listen_port() {
    local port="$1"
    local f="/etc/nginx/sites-available/default"
    [ -f "$f" ] || return 0
    sed -i -E "s/listen\s+80\b/listen ${port}/g" "$f"
    sed -i -E "s/listen\s+\[::\]:80\b/listen [::]:${port}/g" "$f"
    return 0
}

open_firewall_port() {
    local port="$1"
    if command -v firewall-cmd >/dev/null 2>&1 && systemctl is-active --quiet firewalld 2>/dev/null; then
        firewall-cmd --permanent --add-port="${port}/tcp" >/dev/null 2>&1 || true
        firewall-cmd --reload >/dev/null 2>&1 || true
    elif command -v ufw >/dev/null 2>&1 && (systemctl is-active --quiet ufw 2>/dev/null || ufw status >/dev/null 2>&1); then
        ufw allow "${port}/tcp" >/dev/null 2>&1 || true
    fi
}

# ====== FIX DEBIAN: asegurarse de recargar Apache/Nginx tras habilitar conf/módulos ======
apache_reload_restart() {
    # intenta reload; si falla, hace restart
    if have_systemd; then
        systemctl reload apache2 >/dev/null 2>&1 && return 0
        systemctl restart apache2 >/dev/null 2>&1 && return 0
        systemctl reload httpd   >/dev/null 2>&1 && return 0
        systemctl restart httpd  >/dev/null 2>&1 && return 0
    fi
    if command -v service >/dev/null 2>&1; then
        service apache2 reload >/dev/null 2>&1 && return 0
        service apache2 restart >/dev/null 2>&1 && return 0
        service httpd reload >/dev/null 2>&1 && return 0
        service httpd restart >/dev/null 2>&1 && return 0
    fi
    return 1
}

nginx_reload_restart() {
    if have_systemd; then
        systemctl reload nginx >/dev/null 2>&1 && return 0
        systemctl restart nginx >/dev/null 2>&1 && return 0
    fi
    if command -v service >/dev/null 2>&1; then
        service nginx reload >/dev/null 2>&1 && return 0
        service nginx restart >/dev/null 2>&1 && return 0
    fi
    return 1
}

dump_web_debug() {
    echo ""
    echo "==================== DEBUG WEB ===================="

    echo "[DEBUG] Puertos escuchando:"
    if command -v ss >/dev/null 2>&1; then ss -ltnp 2>/dev/null | head -n 120 || true; fi
    if command -v netstat >/dev/null 2>&1; then netstat -ltnp 2>/dev/null | head -n 120 || true; fi

    echo ""
    echo "[DEBUG] Apache ports.conf:"
    [ -f /etc/apache2/ports.conf ] && sed -n '1,220p' /etc/apache2/ports.conf || true

    echo ""
    echo "[DEBUG] Conf-enabled:"
    ls -la /etc/apache2/conf-enabled 2>/dev/null || true

    echo ""
    echo "[DEBUG] Buscar Alias /zabbix:"
    grep -Rns "Alias\s\+/zabbix" /etc/apache2 2>/dev/null | head -n 80 || true

    echo ""
    echo "[DEBUG] apache2ctl -S (si existe):"
    command -v apache2ctl >/dev/null 2>&1 && apache2ctl -S 2>&1 | head -n 120 || true

    echo ""
    echo "[DEBUG] apache2ctl -M (módulos cargados, si existe):"
    command -v apache2ctl >/dev/null 2>&1 && apache2ctl -M 2>/dev/null | head -n 200 || true

    echo ""
    echo "[DEBUG] docker ps (si existe):"
    command -v docker >/dev/null 2>&1 && docker ps --format '{{.ID}} {{.Image}} {{.Names}} {{.Ports}}' 2>/dev/null | head -n 80 || true

    echo ""
    echo "[DEBUG] curl headers puertos típicos:"
    for p in 80 8080 8000 81 8888 8081; do
        echo "---- http://127.0.0.1:${p}/zabbix ----"
        curl -sS -I -m 4 "http://127.0.0.1:${p}/zabbix" 2>/dev/null | head -n 5 || true
    done

    echo "==================================================="
    echo ""
}

# ====== 1. PRE-REQUISITOS Y DETECCIÓN ======
check_prereqs() {
    for cmd in curl wget grep awk tput sed cut sort head tail tr find; do
        command -v $cmd >/dev/null 2>&1 || fail "El sistema no tiene '$cmd' instalado. Instálelo primero."
    done
}

source /etc/os-release
OS_NAME="$PRETTY_NAME"
VER_ID="$VERSION_ID"
VER_MAJOR=$(echo "$VERSION_ID" | cut -d. -f1)
CODENAME="${VERSION_CODENAME:-}"

[[ "$ID" == "amzn" && "$VER_MAJOR" == "2" ]] && VER_MAJOR="7"
[[ "$ID" == "amzn" && "$VER_MAJOR" == "2023" ]] && VER_MAJOR="9"

REPO_RPM_OS="rhel"
case "$ID" in
  almalinux) REPO_RPM_OS="alma" ;;
  rocky)     REPO_RPM_OS="rocky" ;;
  ol|oracle) REPO_RPM_OS="oracle" ;;
  rhel)      REPO_RPM_OS="rhel" ;;
  centos)    REPO_RPM_OS="rhel" ;;
  amzn)      REPO_RPM_OS="amazon" ;;
esac

REPO_OS=""
case "$ID" in
  ubuntu)   REPO_OS="ubuntu" ;;
  debian)   REPO_OS="debian" ;;
  raspbian) REPO_OS="raspbian" ;;
esac

detect_pkg() {
    if command -v apt >/dev/null 2>&1; then
        PKG="apt"
        if [ -z "$CODENAME" ]; then
            CODENAME="$(lsb_release -cs 2>/dev/null || true)"
        fi
        [ -z "$CODENAME" ] && fail "No pude detectar el codename (VERSION_CODENAME)."
    elif command -v dnf >/dev/null 2>&1; then
        PKG="dnf"
    elif command -v yum >/dev/null 2>&1; then
        PKG="yum"
    elif command -v zypper >/dev/null 2>&1; then
        PKG="zypper"
    elif command -v pacman >/dev/null 2>&1; then
        PKG="pacman"
    else
        fail "Gestor de paquetes no soportado."
    fi
}

# ====== INSTALACIÓN MULTI-OS DE DOCKER ======
task_install_docker() {
    if [ "$PKG" == "dnf" ] || [ "$PKG" == "yum" ]; then
        $PKG install -y dnf-utils
        $PKG config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo
        $PKG install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin --allowerasing
    elif [ "$PKG" == "pacman" ]; then
        pacman -Sy --noconfirm docker docker-compose
    elif [ "$PKG" == "zypper" ]; then
        zypper addrepo https://download.docker.com/linux/sles/docker-ce.repo
        zypper --non-interactive install docker-ce docker-ce-cli containerd.io docker-compose-plugin
    else
        curl -fsSL https://get.docker.com -o get-docker.sh
        sh get-docker.sh
        rm -f get-docker.sh
    fi
    svc_enable_start docker || true
}

# ====== 2. MENÚ E INTERACCIÓN ======
is_version_supported_here() {
    local v="$1"
    if [ "$PKG" == "apt" ]; then
        curl -fsI "https://repo.zabbix.com/zabbix/${v}/release/${REPO_OS}/dists/${CODENAME}/Release" >/dev/null 2>&1
        return $?
    elif [ "$PKG" == "dnf" ] || [ "$PKG" == "yum" ]; then
        # FIX: Oracle/RHEL y variantes: probar varios OS y arch (x86_64/noarch/aarch64)
        local os arch
        for os in "$REPO_RPM_OS" rhel; do
            for arch in x86_64 noarch aarch64; do
                curl -fsI "https://repo.zabbix.com/zabbix/${v}/release/${os}/${VER_MAJOR}/${arch}/repodata/repomd.xml" >/dev/null 2>&1 && return 0
            done
        done
        return 1
    else
        return 0
    fi
}

select_options() {
    print_ascii_logo
    msg "${C}🖥️  SISTEMA DETECTADO: ${N}$OS_NAME"
    echo ""

    msg "${BOLD}Seleccione el tipo de despliegue de Zabbix:${N}"
    echo -e "  ${C}[1]${N} Zabbix Server Nativo (Frontend + DB + Server)"
    echo -e "  ${C}[2]${N} Zabbix Proxy Nativo (Nodo intermediario con SQLite3)"
    echo -e "  ${C}[3]${N} Zabbix Agent Nativo (Cliente de monitoreo)"
    echo -e "  ${C}[4]${N} Zabbix Containers (Docker Hub / Compose)"

    while true; do
        read -r -p "  👉 Opción: " DEPLOY_TYPE
        DEPLOY_TYPE="$(sanitize_num "$DEPLOY_TYPE")"
        [[ "$DEPLOY_TYPE" =~ ^[1-4]$ ]] && break
    done
    echo ""

    if [ "$DEPLOY_TYPE" == "4" ]; then
        if ! command -v docker >/dev/null 2>&1; then
            msg "$Y" "⚠️ Docker no está instalado en este sistema."
            read -r -p "  👉 ¿Desea instalar Docker automáticamente ahora? (s/n): " INST_DOCKER
            if [[ "$INST_DOCKER" =~ ^[Ss]$ ]]; then
                task_progress_bar "Instalando Docker Multi-OS" task_install_docker
            else
                fail "Docker es requerido para esta opción."
            fi
        fi
        msg "${BOLD}Catálogo Oficial de Contenedores Zabbix:${N}"
        echo -e "  ${C}[1]${N} Stack Completo (Server + Frontend + DB)"
        echo -e "  ${C}[2]${N} Zabbix Proxy (SQLite3)"
        echo -e "  ${C}[3]${N} Zabbix Agent"

        while true; do
            read -r -p "  👉 Selecciona la categoría: " DOCKER_CAT
            DOCKER_CAT="$(sanitize_num "$DOCKER_CAT")"
            [[ "$DOCKER_CAT" =~ ^[1-3]$ ]] && break
        done
        echo ""
    fi

    if [ "$PKG" == "pacman" ] && [ "$DEPLOY_TYPE" != "4" ]; then
        Z_VER="Rolling (Arch Repos)"
        msg "$Y" "➜ Arch Linux detectado. Utilizando repositorios nativos rolling-release."
        echo ""
    else
        msg "$C" "➜ Scrapeando repositorios oficiales de Zabbix..."
        (
            mapfile -t RAW_VERSIONS < <(
                curl -fsSL https://repo.zabbix.com/zabbix/ \
                | grep -Eo 'href="[0-9]+\.[0-9]+/' \
                | cut -d'"' -f2 \
                | tr -d '/' \
                | sort -Vr \
                | awk '!seen[$0]++'
            )

            VERSIONS_FOUND=()
            for v in "${RAW_VERSIONS[@]}"; do
                if is_version_supported_here "$v"; then
                    VERSIONS_FOUND+=("$v")
                fi
                [ "${#VERSIONS_FOUND[@]}" -ge 5 ] && break
            done

            declare -p VERSIONS_FOUND > /tmp/zbx_versions.tmp
        ) & spinner_pid=$!

        while kill -0 $spinner_pid 2>/dev/null; do printf "${C}●${N} "; sleep 0.15; printf "\b\b"; done
        wait $spinner_pid || true
        printf "\r\033[K"

        source /tmp/zbx_versions.tmp && rm -f /tmp/zbx_versions.tmp
        VERSIONS=("${VERSIONS_FOUND[@]}")

        [[ ${#VERSIONS[@]} -eq 0 ]] && fail "No se encontraron versiones compatibles para esta distro."
        msg "${BOLD}Versiones disponibles compatibles:${N}"
        for i in "${!VERSIONS[@]}"; do echo -e "  ${C}[$((i+1))]${N} Zabbix ${VERSIONS[$i]}"; done
        echo ""

        while true; do
            read -r -p "  👉 Selecciona Versión: " OPC_V
            OPC_V="$(sanitize_num "$OPC_V")"
            [[ "$OPC_V" =~ ^[0-9]+$ ]] || continue
            [ "$OPC_V" -ge 1 ] && [ "$OPC_V" -le "${#VERSIONS[@]}" ] && break
        done

        Z_VER="${VERSIONS[$((OPC_V-1))]}"
        [[ -z "$Z_VER" ]] && fail "Opción incorrecta."
        echo ""
    fi

    if [ "$DEPLOY_TYPE" == "1" ] || [[ "$DEPLOY_TYPE" == "4" && "$DOCKER_CAT" == "1" ]]; then
        msg "${BOLD}Configuración de Base de Datos:${N}"
        echo -e "  ${C}[1]${N} MySQL / MariaDB"
        echo -e "  ${C}[2]${N} PostgreSQL"
        while true; do
            read -r -p "  👉 Selecciona Motor DB: " OPC_D
            OPC_D="$(sanitize_num "$OPC_D")"
            [[ "$OPC_D" =~ ^[1-2]$ ]] && break
        done
        DB_TYPE="mysql"; [[ "$OPC_D" == "2" ]] && DB_TYPE="pgsql"
        echo ""

        msg "${BOLD}Configuración de Servidor Web:${N}"
        echo -e "  ${C}[1]${N} Apache"
        echo -e "  ${C}[2]${N} Nginx"
        while true; do
            read -r -p "  👉 Selecciona Servidor Web: " OPC_W
            OPC_W="$(sanitize_num "$OPC_W")"
            [[ "$OPC_W" =~ ^[1-2]$ ]] && break
        done
        WEB_TYPE="apache"; [[ "$OPC_W" == "2" ]] && WEB_TYPE="nginx"
        echo ""

        msg "${BOLD}Seguridad de Base de Datos:${N}"
        while true; do
            read -s -p "  🔑 Crea contraseña para 'zabbix': " Z_PASS1; echo
            read -s -p "  🔑 Confirma la contraseña: " Z_PASS2; echo
            if [ "$Z_PASS1" == "$Z_PASS2" ] && [ -n "$Z_PASS1" ]; then
                Z_PASS="$Z_PASS1"; break
            else
                msg "$R" "  ❌ Las contraseñas no coinciden. Reintente."
            fi
        done
        echo ""

        msg "${BOLD}Seguridad SSL/TLS (Let's Encrypt):${N}"
        read -r -p "  👉 ¿Tiene un Dominio válido apuntando a esta IP? (s/n): " ASK_SSL
        if [[ "$ASK_SSL" =~ ^[Ss]$ ]]; then
            ENABLE_SSL="s"
            read -r -p "  🌐 Ingrese el dominio: " SSL_DOMAIN
            read -r -p "  📧 Ingrese un email: " SSL_EMAIL
        fi
        echo ""
    fi

    if [ "$DEPLOY_TYPE" == "2" ] || [ "$DEPLOY_TYPE" == "3" ] || [[ "$DEPLOY_TYPE" == "4" && "$DOCKER_CAT" != "1" ]]; then
        msg "${BOLD}Configuración del Nodo:${N}"
        read -r -p "  🌐 Ingrese la IP del Zabbix Server Maestro: " ZBX_SERVER_IP

        # Docker Proxy/Agent: permitir puerto del server (default 10050)
        if [[ "$DEPLOY_TYPE" == "4" && "$DOCKER_CAT" != "1" ]]; then
            read -r -p "  🔌 Puerto del Zabbix Server Maestro (Default=10050): " _p
            _p="$(sanitize_num "${_p:-10051}")"
            [ -z "$_p" ] && _p="10051"
            ZBX_SERVER_PORT="$_p"

            if [[ "$DOCKER_CAT" == "2" ]]; then
                echo -e "  ${C}[0]${N} Proxy ACTIVE (default)"
                echo -e "  ${C}[1]${N} Proxy PASSIVE"
                read -r -p "  👉 ProxyMode (0/1, Enter=0): " _pm
                _pm="$(sanitize_num "${_pm:-0}")"
                [[ "$_pm" =~ ^[01]$ ]] || _pm="0"
                DOCKER_PROXYMODE="$_pm"
            fi
        fi

        read -r -p "  📛 Ingrese el Hostname (Enter = Default): " ZBX_HOSTNAME
        echo ""
    fi
}

# ====== TAREAS (BACKEND) ======
# (Desde acá hacia abajo, tu script original 1.2.8 sigue igual salvo FIX DOCKER ports)
# ------------------------------------------------------------------------------

task_repos() {
    if [ "$PKG" == "apt" ]; then
        export DEBIAN_FRONTEND=noninteractive
        export UCF_FORCE_CONFFNEW=1
        export UCF_FORCE_CONFFOLD=0

        apt update -y
        apt install -y wget curl gnupg ca-certificates lsb-release

        rm -f /etc/apt/sources.list.d/zabbix*.list /etc/apt/sources.list.d/zabbix*.sources

        local DIR_URL="https://repo.zabbix.com/zabbix/${Z_VER}/release/${REPO_OS}/pool/main/z/zabbix-release/"
        local wanted1="zabbix-release_latest_${Z_VER}+${REPO_OS}${VER_ID}_all.deb"
        local wanted2="zabbix-release_${Z_VER}-1+${REPO_OS}${VER_ID}_all.deb"
        local wanted3="zabbix-release_latest+${REPO_OS}${VER_ID}_all.deb"

        local EXACT_FILE=""
        EXACT_FILE=$(curl -fsSL "$DIR_URL" | grep -Eo "${wanted1}" | head -n 1 || true)
        [ -z "$EXACT_FILE" ] && EXACT_FILE=$(curl -fsSL "$DIR_URL" | grep -Eo "${wanted2}" | head -n 1 || true)
        [ -z "$EXACT_FILE" ] && EXACT_FILE=$(curl -fsSL "$DIR_URL" | grep -Eo "${wanted3}" | head -n 1 || true)

        if [ -z "$EXACT_FILE" ]; then
            EXACT_FILE=$(curl -fsSL "$DIR_URL" \
                | grep -Eo 'zabbix-release[^"]+_all\.deb' \
                | grep -E "${REPO_OS}${VER_ID}_all\.deb" \
                | grep -E "${Z_VER}" \
                | sort -V \
                | tail -n 1 || true)
        fi

        [ -z "$EXACT_FILE" ] && fail "No pude encontrar zabbix-release para ${REPO_OS}${VER_ID} en ${DIR_URL}"

        local URL="${DIR_URL}${EXACT_FILE}"
        wget -q "$URL" -O zbx.deb
        dpkg -i --force-confnew --force-confdef zbx.deb

        cat >/etc/apt/preferences.d/99-zabbix <<EOF
Package: zabbix*
Pin: origin "repo.zabbix.com"
Pin-Priority: 1001
EOF

        sed -i 's|^deb .*repo\.zabbix\.com/zabbix-tools.*|# &|g' /etc/apt/sources.list.d/zabbix*.list 2>/dev/null || true

        apt update -y

    elif [ "$PKG" == "zypper" ]; then
        local SUSE_OS="sles"
        [[ "$ID" == "opensuse-leap" ]] && SUSE_OS="opensuse"
        local DIR_URL="https://repo.zabbix.com/zabbix/${Z_VER}/release/${SUSE_OS}/${VER_MAJOR}/noarch/"
        local LATEST_RPM
        LATEST_RPM=$(curl -fsSL "$DIR_URL" | grep -Eo 'zabbix-release[^"]+\.noarch\.rpm' | sort -V | tail -n 1)
        [ -z "$LATEST_RPM" ] && return 1
        zypper --non-interactive install "${DIR_URL}${LATEST_RPM}"
        zypper --non-interactive --gpg-auto-import-keys refresh

    elif [ "$PKG" == "dnf" ] || [ "$PKG" == "yum" ]; then
        rpm --import "https://repo.zabbix.com/zabbix-official-repo.key" >/dev/null 2>&1 || true

        local try_os="$REPO_RPM_OS"
        local DIR_URL="https://repo.zabbix.com/zabbix/${Z_VER}/release/${try_os}/${VER_MAJOR}/noarch/"
        local LATEST_RPM
        LATEST_RPM=$(curl -fsSL "$DIR_URL" | grep -Eo 'zabbix-release[^"]+\.noarch\.rpm' | sort -V | tail -n 1 || true)

        if [ -z "$LATEST_RPM" ]; then
            DIR_URL="https://repo.zabbix.com/zabbix/${Z_VER}/release/rhel/${VER_MAJOR}/noarch/"
            LATEST_RPM=$(curl -fsSL "$DIR_URL" | grep -Eo 'zabbix-release[^"]+\.noarch\.rpm' | sort -V | tail -n 1 || true)
        fi

        [ -z "$LATEST_RPM" ] && return 1
        $PKG install -y "${DIR_URL}${LATEST_RPM}"
        $PKG clean all
    fi
}

task_packages() {
    local OPT=""
    [[ "$PKG" == "dnf" ]] && OPT="--allowerasing"

    if [ "$PKG" == "apt" ]; then
        export DEBIAN_FRONTEND=noninteractive

        if [ "$DEPLOY_TYPE" == "1" ]; then
            if [ "$WEB_TYPE" == "apache" ]; then
                apt install -y apache2 libapache2-mod-php php php-mysql php-gd php-xml php-bcmath php-mbstring php-ldap php-curl >/dev/null 2>&1 || true
            else
                apt install -y nginx php-fpm php-mysql php-gd php-xml php-bcmath php-mbstring php-ldap php-curl >/dev/null 2>&1 || true
            fi

            if [ "$DB_TYPE" == "mysql" ]; then
                apt install -y mariadb-server mariadb-client || return 1
            else
                apt install -y postgresql || return 1
            fi

            apt install -y "zabbix-server-${DB_TYPE}" zabbix-frontend-php "zabbix-${WEB_TYPE}-conf" zabbix-sql-scripts zabbix-agent || return 1
        fi

        if [ "$DEPLOY_TYPE" == "2" ]; then
            apt install -y zabbix-proxy-sqlite3 zabbix-sql-scripts sqlite3 || return 1
        fi

        if [ "$DEPLOY_TYPE" == "3" ]; then
            apt install -y zabbix-agent || return 1
        fi

    elif [ "$PKG" == "zypper" ]; then
        if [ "$DEPLOY_TYPE" == "1" ]; then
            if [ "$DB_TYPE" == "mysql" ]; then zypper --non-interactive install mariadb mariadb-client || return 1
            else zypper --non-interactive install postgresql postgresql-server || return 1; fi
            zypper --non-interactive install "zabbix-server-${DB_TYPE}" "zabbix-web-${DB_TYPE}" "zabbix-${WEB_TYPE}-conf" zabbix-sql-scripts zabbix-agent || return 1
        fi
        if [ "$DEPLOY_TYPE" == "2" ]; then
            zypper --non-interactive install zabbix-proxy-sqlite3 zabbix-sql-scripts sqlite3 || return 1
        fi
        if [ "$DEPLOY_TYPE" == "3" ]; then
            zypper --non-interactive install zabbix-agent || return 1
        fi

    elif [ "$PKG" == "pacman" ]; then
        if [ "$DEPLOY_TYPE" == "1" ]; then pacman -Sy --noconfirm zabbix-server zabbix-frontend-php zabbix-agent mariadb apache php-apache || return 1; fi
        if [ "$DEPLOY_TYPE" == "2" ]; then pacman -Sy --noconfirm zabbix-proxy-sqlite3 zabbix-sql-scripts sqlite || return 1; fi
        if [ "$DEPLOY_TYPE" == "3" ]; then pacman -Sy --noconfirm zabbix-agent || return 1; fi

    else
        if [ "$DEPLOY_TYPE" == "1" ]; then
            if [ "$DB_TYPE" == "mysql" ]; then $PKG install -y $OPT mariadb-server mariadb || true
            else $PKG install -y $OPT postgresql-server postgresql || true; fi
            $PKG install -y $OPT "zabbix-server-${DB_TYPE}" "zabbix-web-${DB_TYPE}" "zabbix-${WEB_TYPE}-conf" zabbix-sql-scripts zabbix-agent || return 1
        fi
        if [ "$DEPLOY_TYPE" == "2" ]; then
            $PKG install -y $OPT zabbix-proxy-sqlite3 zabbix-sql-scripts sqlite3 || return 1
        fi
        if [ "$DEPLOY_TYPE" == "3" ]; then
            $PKG install -y $OPT zabbix-agent || return 1
        fi
    fi
}

task_database() {
    if [ "$DEPLOY_TYPE" != "1" ]; then return 0; fi

    if [ "$DB_TYPE" == "mysql" ]; then
        command -v mysql >/dev/null 2>&1 || return 1
        svc_enable_start mariadb || svc_enable_start mysql || true
        sleep 2
        mysql --protocol=socket -uroot -e "SELECT 1" >/dev/null 2>&1 || return 1

        mysql -uroot -e "DROP DATABASE IF EXISTS zabbix; CREATE DATABASE zabbix CHARACTER SET utf8mb4 COLLATE utf8mb4_bin;"
        mysql -uroot -e "DROP USER IF EXISTS 'zabbix'@'localhost'; CREATE USER 'zabbix'@'localhost' IDENTIFIED BY '${Z_PASS}';"
        mysql -uroot -e "GRANT ALL PRIVILEGES ON zabbix.* TO 'zabbix'@'localhost'; FLUSH PRIVILEGES;"
        mysql -uroot -e "SET GLOBAL log_bin_trust_function_creators = 1;"

        local SQL_PATH=""
        for p in \
            /usr/share/zabbix/sql-scripts/mysql/server.sql.gz \
            /usr/share/zabbix-sql-scripts/mysql/server.sql.gz
        do
            [ -f "$p" ] && SQL_PATH="$p" && break
        done
        [ -z "$SQL_PATH" ] && SQL_PATH=$(find /usr/share -type f -name "server.sql.gz" 2>/dev/null | grep -E "/mysql/" | head -n 1 || true)
        [ -z "$SQL_PATH" ] && return 1

        zcat "$SQL_PATH" | mysql -uzabbix -p"$Z_PASS" zabbix || return 1
        mysql -uroot -e "SET GLOBAL log_bin_trust_function_creators = 0;" || true

    else
        svc_enable_start postgresql || true
        sleep 2

        if command -v runuser >/dev/null 2>&1; then
            runuser -u postgres -- psql -tc "SELECT 1 FROM pg_roles WHERE rolname='zabbix'" | grep -q 1 || runuser -u postgres -- psql -c "CREATE USER zabbix WITH PASSWORD '${Z_PASS}';"
            runuser -u postgres -- psql -tc "SELECT 1 FROM pg_database WHERE datname='zabbix'" | grep -q 1 || runuser -u postgres -- createdb -O zabbix -E UTF8 zabbix
        else
            su - postgres -c "psql -tc \"SELECT 1 FROM pg_roles WHERE rolname='zabbix'\" | grep -q 1 || psql -c \"CREATE USER zabbix WITH PASSWORD '${Z_PASS}';\""
            su - postgres -c "psql -tc \"SELECT 1 FROM pg_database WHERE datname='zabbix'\" | grep -q 1 || createdb -O zabbix -E UTF8 zabbix"
        fi

        local SQL_PATH=""
        for p in \
            /usr/share/zabbix/sql-scripts/postgresql/server.sql.gz \
            /usr/share/zabbix-sql-scripts/postgresql/server.sql.gz
        do
            [ -f "$p" ] && SQL_PATH="$p" && break
        done
        [ -z "$SQL_PATH" ] && SQL_PATH=$(find /usr/share -type f -name "server.sql.gz" 2>/dev/null | grep -E "/postgresql/" | head -n 1 || true)
        [ -z "$SQL_PATH" ] && return 1

        if command -v runuser >/dev/null 2>&1; then
            zcat "$SQL_PATH" | runuser -u postgres -- psql -d zabbix || return 1
        else
            zcat "$SQL_PATH" | su - postgres -c "psql -d zabbix" || return 1
        fi
    fi

    return 0
}

task_proxy_db() {
    command -v sqlite3 >/dev/null 2>&1 || return 1
    mkdir -p /var/lib/zabbix
    chown zabbix:zabbix /var/lib/zabbix || true
    local SQL_PATH
    SQL_PATH=$(find /usr/share -name "proxy.sql.gz" 2>/dev/null | grep -E "/sqlite3/" | head -n 1 || true)
    [ -z "$SQL_PATH" ] && return 1
    zcat "$SQL_PATH" | sqlite3 /var/lib/zabbix/zabbix_proxy.db || return 1
    chown zabbix:zabbix /var/lib/zabbix/zabbix_proxy.db || true
    local CONF_PATH
    CONF_PATH=$(find /etc -name "zabbix_proxy.conf" 2>/dev/null | head -n 1 || true)
    [ -z "$CONF_PATH" ] && return 1
    sed -i "s/^Server=.*/Server=$ZBX_SERVER_IP/g" "$CONF_PATH"
    if [ -n "$ZBX_HOSTNAME" ]; then sed -i "s/^Hostname=.*/Hostname=$ZBX_HOSTNAME/g" "$CONF_PATH"
    else sed -i "s/^Hostname=.*/Hostname=$(hostname)/g" "$CONF_PATH"; fi
    sed -i "s|^DBName=.*|DBName=/var/lib/zabbix/zabbix_proxy.db|g" "$CONF_PATH"
    svc_restart_enable zabbix-proxy
    return 0
}

task_security() {
    local PORT=""
    if [ "$DEPLOY_TYPE" == "1" ] || [ "$DEPLOY_TYPE" == "2" ] || [[ "$DEPLOY_TYPE" == "4" && "$DOCKER_CAT" =~ ^[12]$ ]]; then PORT="10051/tcp"; fi
    if [ "$DEPLOY_TYPE" == "3" ] || [[ "$DEPLOY_TYPE" == "4" && "$DOCKER_CAT" == "3" ]]; then PORT="10050/tcp"; fi

    if command -v firewall-cmd >/dev/null 2>&1 && systemctl is-active --quiet firewalld 2>/dev/null; then
        if [ "$DEPLOY_TYPE" == "1" ] || [[ "$DEPLOY_TYPE" == "4" && "$DOCKER_CAT" == "1" ]]; then firewall-cmd --permanent --add-service={http,https} >/dev/null 2>&1 || true; fi
        [[ -n "$PORT" ]] && firewall-cmd --permanent --add-port=$PORT >/dev/null 2>&1 || true
        firewall-cmd --reload >/dev/null 2>&1 || true
    elif command -v ufw >/dev/null 2>&1 && (systemctl is-active --quiet ufw 2>/dev/null || ufw status >/dev/null 2>&1); then
        if [ "$DEPLOY_TYPE" == "1" ] || [[ "$DEPLOY_TYPE" == "4" && "$DOCKER_CAT" == "1" ]]; then ufw allow 80/tcp >/dev/null 2>&1 || true; ufw allow 443/tcp >/dev/null 2>&1 || true; fi
        [[ -n "$PORT" ]] && ufw allow $PORT >/dev/null 2>&1 || true
    fi

    if [ "$DEPLOY_TYPE" == "1" ] && command -v setsebool >/dev/null 2>&1; then
        setsebool -P httpd_can_network_connect 1 >/dev/null 2>&1 || true
        setsebool -P httpd_can_connect_zabbix on >/dev/null 2>&1 || true
        setsebool -P httpd_can_network_connect_db on >/dev/null 2>&1 || true
    fi

    return 0
}

task_ssl() {
    if command -v apt >/dev/null 2>&1; then
        apt install -y certbot "python3-certbot-${WEB_TYPE}" || true
    elif command -v dnf >/dev/null 2>&1; then
        dnf install -y certbot "python3-certbot-${WEB_TYPE}" || true
    fi

    if [ "$DEPLOY_TYPE" == "1" ]; then
        certbot --$WEB_TYPE -d "$SSL_DOMAIN" --non-interactive --agree-tos -m "$SSL_EMAIL" --redirect
    elif [ "$DEPLOY_TYPE" == "4" ]; then
        certbot certonly --standalone -d "$SSL_DOMAIN" --non-interactive --agree-tos -m "$SSL_EMAIL"
    fi
}

task_configure_agent() {
    local CONF_FILE="/etc/zabbix/zabbix_agentd.conf"
    local AGENT_SVC="zabbix-agent"
    [[ -f "/etc/zabbix/zabbix_agent2.conf" ]] && CONF_FILE="/etc/zabbix/zabbix_agent2.conf" && AGENT_SVC="zabbix-agent2"
    [ -f "$CONF_FILE" ] || return 1

    cp "$CONF_FILE" "${CONF_FILE}.bak"
    sed -i "s/^Server=.*/Server=$ZBX_SERVER_IP/g" "$CONF_FILE"
    sed -i "s/^ServerActive=.*/ServerActive=$ZBX_SERVER_IP/g" "$CONF_FILE"
    if [ -n "$ZBX_HOSTNAME" ]; then sed -i "s/^Hostname=.*/Hostname=$ZBX_HOSTNAME/g" "$CONF_FILE"
    else sed -i "s/^Hostname=.*/Hostname=$(hostname)/g" "$CONF_FILE"; fi
    svc_restart_enable "$AGENT_SVC"
    return 0
}

apache_enable_single_zabbix_alias() {
    # Si el paquete ya trae zabbix.conf, lo habilitamos y listo (pero OJO: requiere reload/restart)
    if [ -f /etc/apache2/conf-available/zabbix.conf ]; then
        if command -v a2disconf >/dev/null 2>&1; then
            [ -f /etc/apache2/conf-enabled/zabbix-ui.conf ] && a2disconf zabbix-ui >/dev/null 2>&1 || true
        elif [ -x /usr/sbin/a2disconf ]; then
            [ -f /etc/apache2/conf-enabled/zabbix-ui.conf ] && /usr/sbin/a2disconf zabbix-ui >/dev/null 2>&1 || true
        fi

        if command -v a2enconf >/dev/null 2>&1; then
            a2enconf zabbix >/dev/null 2>&1 || true
        elif [ -x /usr/sbin/a2enconf ]; then
            /usr/sbin/a2enconf zabbix >/dev/null 2>&1 || true
        fi
        return 0
    fi

    local ZBX_UI_DIR="/usr/share/zabbix"
    if [ -d "/usr/share/zabbix/ui" ] && [ -f "/usr/share/zabbix/ui/index.php" ]; then
        ZBX_UI_DIR="/usr/share/zabbix/ui"
    fi

    if [ -d /etc/apache2/conf-available ]; then
        cat >/etc/apache2/conf-available/zabbix-ui.conf <<EOF
Alias /zabbix ${ZBX_UI_DIR}

<Directory "${ZBX_UI_DIR}">
    Options FollowSymLinks
    AllowOverride All
    Require all granted
</Directory>

<IfModule mod_php.c>
    php_value max_execution_time 300
    php_value memory_limit 256M
    php_value post_max_size 16M
    php_value upload_max_filesize 2M
    php_value max_input_time 300
    php_value max_input_vars 10000
</IfModule>
EOF
        if command -v a2enconf >/dev/null 2>&1; then
            a2enconf zabbix-ui >/dev/null 2>&1 || true
        elif [ -x /usr/sbin/a2enconf ]; then
            /usr/sbin/a2enconf zabbix-ui >/dev/null 2>&1 || true
        fi
    fi
    return 0
}

task_services() {
    stop_zabbix_docker_conflicts

    local CONF_PATH
    CONF_PATH=$(find /etc -name "zabbix_server.conf" 2>/dev/null | head -n 1 || true)
    [[ -n "$CONF_PATH" ]] && sed -i "s/^#\?\s*DBPassword=.*/DBPassword=$Z_PASS/g" "$CONF_PATH"

    rm -f /etc/zabbix/web/zabbix.conf.php /usr/share/zabbix/conf/zabbix.conf.php 2>/dev/null || true

    svc_restart_enable zabbix-server
    svc_restart_enable zabbix-agent

    if [ "$WEB_TYPE" == "apache" ]; then
        apache_enable_single_zabbix_alias

        # Si el 80 está ocupado por otro, mover Apache a un puerto libre
        local p80proc
        p80proc="$(port_proc_name 80)"
        if port_in_use 80 && ! echo "$p80proc" | grep -Eq 'apache2|httpd'; then
            WEB_PORT="$(first_free_port)"
            [ "$WEB_PORT" == "80" ] && WEB_PORT="8080"
            apache_set_listen_port "$WEB_PORT"
        else
            WEB_PORT="80"
        fi

        # Habilitar módulos ANTES de recargar Apache (en Debian suele estar en /usr/sbin)
        local A2ENMOD_BIN=""
        if command -v a2enmod >/dev/null 2>&1; then
            A2ENMOD_BIN="$(command -v a2enmod)"
        elif [ -x /usr/sbin/a2enmod ]; then
            A2ENMOD_BIN="/usr/sbin/a2enmod"
        fi

        if [ -n "$A2ENMOD_BIN" ]; then
            $A2ENMOD_BIN alias >/dev/null 2>&1 || true
            $A2ENMOD_BIN rewrite >/dev/null 2>&1 || true

            # Habilitar módulo PHP correcto si existe
            if command -v php >/dev/null 2>&1; then
                local phpm="php$(php -r 'echo PHP_MAJOR_VERSION.".".PHP_MINOR_VERSION;')"
                $A2ENMOD_BIN "$phpm" >/dev/null 2>&1 || true
            fi
        fi

        # Arrancar y recargar para que tome conf-enabled/zabbix.conf y los módulos
        svc_enable_start apache2 || svc_enable_start httpd || true
        apache_reload_restart || true

        open_firewall_port "$WEB_PORT"

        if http_selftest "$WEB_PORT"; then
            return 0
        else
            dump_web_debug
            return 1
        fi
    fi

    if [ "$WEB_TYPE" == "nginx" ]; then
        local p80proc
        p80proc="$(port_proc_name 80)"
        if port_in_use 80 && ! echo "$p80proc" | grep -Eq 'nginx'; then
            WEB_PORT="$(first_free_port)"
            [ "$WEB_PORT" == "80" ] && WEB_PORT="8080"
            nginx_set_listen_port "$WEB_PORT"
        else
            WEB_PORT="80"
        fi

        svc_enable_start nginx || true
        nginx_reload_restart || true

        open_firewall_port "$WEB_PORT"

        if http_selftest "$WEB_PORT"; then
            return 0
        else
            dump_web_debug
            return 1
        fi
    fi

    return 1
}

task_docker_deploy() {
    command -v docker >/dev/null 2>&1 || return 1
    docker info >/dev/null 2>&1 || return 1

    local COMPOSE
    COMPOSE="$(docker_compose_cmd)"

    # Tag oficial: hasta 7.4 es "<distro>-<ver>-latest".
    # En Docker Hub, 8.0 aparece publicado como "trunk" (tags: alpine-trunk / ubuntu-trunk / ol-trunk).
    local DOCKER_TAG=""
    if [[ "$Z_VER" =~ ^8\.0$ ]]; then
        DOCKER_TAG="ubuntu-trunk"
    else
        DOCKER_TAG="ubuntu-${Z_VER}-latest"
    fi

    local DB_IMAGE="mysql:8.0"
    [ "$DB_TYPE" == "pgsql" ] && DB_IMAGE="postgres:16"

    # =======================
    # Multi-instancia REAL
    # =======================
    local BASE="/opt/zabbix-docker"
    mkdir -p "$BASE" || return 1

    # 1) Puertos host: +10 automático
    DOCKER_WEB_PORT=""
    DOCKER_ZBX_PORT=""
    DOCKER_AGENT_PORT=""

    if [ "$DOCKER_CAT" == "1" ]; then
        DOCKER_WEB_PORT="$(step_free_port 80 10 60)"       # 80,90,100...
        DOCKER_ZBX_PORT="$(step_free_port 10051 10 60)"    # 10051,10061,10071...
    elif [ "$DOCKER_CAT" == "2" ]; then
        DOCKER_ZBX_PORT="$(step_free_port 10051 10 60)"
    elif [ "$DOCKER_CAT" == "3" ]; then
        DOCKER_AGENT_PORT="$(step_free_port 10050 10 60)"
    fi

    # 2) ID + directorio por instancia (NO pisa otras instalaciones)
    local ts zv
    ts="$(date +%s)"
    zv="${Z_VER//./_}"
    DOCKER_INSTANCE_ID="zbx_${zv}_c${DOCKER_CAT}_w${DOCKER_WEB_PORT:-0}_s${DOCKER_ZBX_PORT:-0}_a${DOCKER_AGENT_PORT:-0}_${ts}"
    DOCKER_WORKDIR="${BASE}/${DOCKER_INSTANCE_ID}"
    mkdir -p "$DOCKER_WORKDIR" || return 1
    cd "$DOCKER_WORKDIR" || return 1

    # Guardar para debug incluso si falla
    echo "[DOCKER] instance=${DOCKER_INSTANCE_ID} workdir=${DOCKER_WORKDIR} tag=${DOCKER_TAG} db=${DB_TYPE}" >> "$LOG_FILE"

    # 3) Nombres de contenedores por instancia (evita colisiones)
    local C_DB="${DOCKER_INSTANCE_ID}-db"
    local C_SERVER="${DOCKER_INSTANCE_ID}-server"
    local C_WEB="${DOCKER_INSTANCE_ID}-web"
    local C_PROXY="${DOCKER_INSTANCE_ID}-proxy"
    local C_AGENT="${DOCKER_INSTANCE_ID}-agent"

    # 4) Limpieza SOLO de esta instancia (por si reintentás)
    $COMPOSE -f docker-compose.yml down -v --remove-orphans >/dev/null 2>&1 || true
    docker rm -fv "$C_DB" "$C_SERVER" "$C_WEB" "$C_PROXY" "$C_AGENT" >/dev/null 2>&1 || true

    # 5) Abrir firewall SOLO puertos usados
    if [ "$DOCKER_CAT" == "1" ]; then
        open_firewall_port "$DOCKER_WEB_PORT"
        open_firewall_port "$DOCKER_ZBX_PORT"
    elif [ "$DOCKER_CAT" == "2" ]; then
        open_firewall_port "$DOCKER_ZBX_PORT"
    elif [ "$DOCKER_CAT" == "3" ]; then
        open_firewall_port "$DOCKER_AGENT_PORT"
    fi

    # 6) Generar docker-compose
    echo "services:" > docker-compose.yml

    if [ "$DOCKER_CAT" == "1" ]; then
        mkdir -p db_data

        # DB
        echo "  zabbix-db:" >> docker-compose.yml
        echo "    container_name: ${C_DB}" >> docker-compose.yml
        echo "    image: ${DB_IMAGE}" >> docker-compose.yml
        echo "    restart: always" >> docker-compose.yml
        echo "    volumes:" >> docker-compose.yml
        if [ "$DB_TYPE" == "mysql" ]; then
            echo "      - ./db_data:/var/lib/mysql:Z" >> docker-compose.yml
            echo "    command: [\"--character-set-server=utf8mb4\", \"--collation-server=utf8mb4_bin\"]" >> docker-compose.yml
        else
            echo "      - ./db_data:/var/lib/postgresql/data:Z" >> docker-compose.yml
        fi
        echo "    environment:" >> docker-compose.yml
        if [ "$DB_TYPE" == "mysql" ]; then
            echo "      - MYSQL_ROOT_PASSWORD=${Z_PASS}" >> docker-compose.yml
            echo "      - MYSQL_DATABASE=zabbix" >> docker-compose.yml
            echo "      - MYSQL_USER=zabbix" >> docker-compose.yml
            echo "      - MYSQL_PASSWORD=${Z_PASS}" >> docker-compose.yml
            echo "    healthcheck:" >> docker-compose.yml
            echo "      test: ['CMD-SHELL', 'mysqladmin ping -h 127.0.0.1 -uroot -p\$\\$MYSQL_ROOT_PASSWORD || exit 1']" >> docker-compose.yml
        else
            echo "      - POSTGRES_DB=zabbix" >> docker-compose.yml
            echo "      - POSTGRES_USER=zabbix" >> docker-compose.yml
            echo "      - POSTGRES_PASSWORD=${Z_PASS}" >> docker-compose.yml
            echo "    healthcheck:" >> docker-compose.yml
            echo "      test: ['CMD-SHELL', 'pg_isready -U \$\\$POSTGRES_USER -d \$\\$POSTGRES_DB || exit 1']" >> docker-compose.yml
        fi
        echo "      interval: 5s" >> docker-compose.yml
        echo "      timeout: 3s" >> docker-compose.yml
        echo "      retries: 60" >> docker-compose.yml
        echo "      start_period: 20s" >> docker-compose.yml
        echo "" >> docker-compose.yml

        # Server
        echo "  zabbix-server:" >> docker-compose.yml
        echo "    container_name: ${C_SERVER}" >> docker-compose.yml
        echo "    image: zabbix/zabbix-server-${DB_TYPE}:${DOCKER_TAG}" >> docker-compose.yml
        echo "    restart: always" >> docker-compose.yml
        echo "    ports:" >> docker-compose.yml
        echo "      - \"${DOCKER_ZBX_PORT}:10051\"" >> docker-compose.yml
        echo "    environment:" >> docker-compose.yml
        echo "      - DB_SERVER_HOST=zabbix-db" >> docker-compose.yml
        if [ "$DB_TYPE" == "mysql" ]; then
            echo "      - MYSQL_DATABASE=zabbix" >> docker-compose.yml
            echo "      - MYSQL_USER=zabbix" >> docker-compose.yml
            echo "      - MYSQL_PASSWORD=${Z_PASS}" >> docker-compose.yml
        else
            echo "      - POSTGRES_DB=zabbix" >> docker-compose.yml
            echo "      - POSTGRES_USER=zabbix" >> docker-compose.yml
            echo "      - POSTGRES_PASSWORD=${Z_PASS}" >> docker-compose.yml
        fi
        echo "" >> docker-compose.yml

        # Web
        echo "  zabbix-web:" >> docker-compose.yml
        echo "    container_name: ${C_WEB}" >> docker-compose.yml
        echo "    image: zabbix/zabbix-web-${WEB_TYPE}-${DB_TYPE}:${DOCKER_TAG}" >> docker-compose.yml
        echo "    restart: always" >> docker-compose.yml
        echo "    ports:" >> docker-compose.yml
        echo "      - \"${DOCKER_WEB_PORT}:8080\"" >> docker-compose.yml
        echo "    environment:" >> docker-compose.yml
        echo "      - ZBX_SERVER_HOST=zabbix-server" >> docker-compose.yml
        echo "      - DB_SERVER_HOST=zabbix-db" >> docker-compose.yml
        if [ "$DB_TYPE" == "mysql" ]; then
            echo "      - MYSQL_DATABASE=zabbix" >> docker-compose.yml
            echo "      - MYSQL_USER=zabbix" >> docker-compose.yml
            echo "      - MYSQL_PASSWORD=${Z_PASS}" >> docker-compose.yml
        else
            echo "      - POSTGRES_DB=zabbix" >> docker-compose.yml
            echo "      - POSTGRES_USER=zabbix" >> docker-compose.yml
            echo "      - POSTGRES_PASSWORD=${Z_PASS}" >> docker-compose.yml
        fi

    elif [ "$DOCKER_CAT" == "2" ]; then
        mkdir -p proxy_data
        echo "  zabbix-proxy:" >> docker-compose.yml
        echo "    container_name: ${C_PROXY}" >> docker-compose.yml
        echo "    image: zabbix/zabbix-proxy-sqlite3:${DOCKER_TAG}" >> docker-compose.yml
        echo "    restart: always" >> docker-compose.yml
        echo "    ports:" >> docker-compose.yml
        echo "      - \"${DOCKER_ZBX_PORT}:10051\"" >> docker-compose.yml
        echo "    environment:" >> docker-compose.yml
        echo "      - ZBX_PROXYMODE=${DOCKER_PROXYMODE}" >> docker-compose.yml
        echo "      - ZBX_SERVER_HOST=${ZBX_SERVER_IP}" >> docker-compose.yml
        echo "      - ZBX_SERVER_PORT=${ZBX_SERVER_PORT}" >> docker-compose.yml
        if [ -n "${ZBX_HOSTNAME:-}" ]; then
            echo "      - ZBX_HOSTNAME=${ZBX_HOSTNAME}" >> docker-compose.yml
        else
            echo "      - ZBX_HOSTNAME=$(hostname)" >> docker-compose.yml
        fi
        echo "    volumes:" >> docker-compose.yml
        echo "      - ./proxy_data:/var/lib/zabbix/db_data:Z" >> docker-compose.yml

    elif [ "$DOCKER_CAT" == "3" ]; then
        echo "  zabbix-agent:" >> docker-compose.yml
        echo "    container_name: ${C_AGENT}" >> docker-compose.yml
        echo "    image: zabbix/zabbix-agent:${DOCKER_TAG}" >> docker-compose.yml
        echo "    restart: always" >> docker-compose.yml
        echo "    ports:" >> docker-compose.yml
        echo "      - \"${DOCKER_AGENT_PORT}:10050\"" >> docker-compose.yml
        echo "    environment:" >> docker-compose.yml
        echo "      - ZBX_SERVER_HOST=${ZBX_SERVER_IP}" >> docker-compose.yml
        echo "      - ZBX_SERVER_PORT=${ZBX_SERVER_PORT}" >> docker-compose.yml
        if [ -n "${ZBX_HOSTNAME:-}" ]; then
            echo "      - ZBX_HOSTNAME=${ZBX_HOSTNAME}" >> docker-compose.yml
        else
            echo "      - ZBX_HOSTNAME=$(hostname)" >> docker-compose.yml
        fi
        echo "    privileged: true" >> docker-compose.yml
    fi

    # =======================
    # DEPLOY SECUENCIAL (FIX REAL)
    # =======================
    if [ "$DOCKER_CAT" == "1" ]; then
        # A) Levantar SOLO DB
        if ! $COMPOSE -f docker-compose.yml up -d zabbix-db; then
            echo "[DOCKER] up DB falló" >> "$LOG_FILE"
            $COMPOSE -f docker-compose.yml logs --tail=250 zabbix-db >> "$LOG_FILE" 2>&1 || true
            return 1
        fi

        # B) Esperar health DB
        local i st
        for i in $(seq 1 240); do
            st="$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}nohealth{{end}}' "$C_DB" 2>/dev/null || true)"
            [ "$st" == "healthy" ] && break
            sleep 1
        done
        st="$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}nohealth{{end}}' "$C_DB" 2>/dev/null || true)"
        if [ "$st" != "healthy" ] && [ "$st" != "nohealth" ]; then
            echo "[DOCKER] DB no quedó healthy a tiempo" >> "$LOG_FILE"
            docker logs --tail=250 "$C_DB" >> "$LOG_FILE" 2>&1 || true
            return 1
        fi

        # C) Inicializar ESQUEMA explícitamente (evita 'users table is empty')
        #    1) log_bin_trust_function_creators=1 (si binlog está activo)
        #    2) drop/create DB con collation recomendado
        #    3) importar create.sql.gz/server.sql.gz desde la imagen zabbix-server
        if [ "$DB_TYPE" == "mysql" ]; then
            docker exec "$C_DB" sh -lc "mysql -uroot -p\"$Z_PASS\" -e \"SET GLOBAL log_bin_trust_function_creators=1;\" " >/dev/null 2>&1 || true
            docker exec "$C_DB" sh -lc "mysql -uroot -p\"$Z_PASS\" -e \"DROP DATABASE IF EXISTS zabbix; CREATE DATABASE zabbix CHARACTER SET utf8mb4 COLLATE utf8mb4_bin;\" " >/dev/null 2>&1 || true
            docker exec "$C_DB" sh -lc "mysql -uroot -p\"$Z_PASS\" -e \"CREATE USER IF NOT EXISTS 'zabbix'@'%' IDENTIFIED BY '$Z_PASS'; GRANT ALL PRIVILEGES ON zabbix.* TO 'zabbix'@'%'; FLUSH PRIVILEGES;\" " >/dev/null 2>&1 || true

            local schema
            schema="$(docker run --rm "zabbix/zabbix-server-${DB_TYPE}:${DOCKER_TAG}" sh -lc "set -e; f=\$(find /usr/share /usr/share/doc -maxdepth 6 -type f \\( -name 'create.sql.gz' -o -name 'server.sql.gz' \\) 2>/dev/null | head -n 1); [ -n \"\$f\" ] && echo \"\$f\"")"
            [ -z "$schema" ] && { echo "[DOCKER] No encontré create.sql.gz/server.sql.gz en la imagen server" >> "$LOG_FILE"; return 1; }

            # importar
            docker run --rm "zabbix/zabbix-server-${DB_TYPE}:${DOCKER_TAG}" sh -lc "gzip -dc \"$schema\"" \
              | docker exec -i "$C_DB" sh -lc "mysql -uzabbix -p\"$Z_PASS\" zabbix" \
              >/dev/null 2>&1 || { echo "[DOCKER] Import schema falló" >> "$LOG_FILE"; return 1; }

            docker exec "$C_DB" sh -lc "mysql -uroot -p\"$Z_PASS\" -e \"SET GLOBAL log_bin_trust_function_creators=0;\" " >/dev/null 2>&1 || true

            # validar users > 0
            docker exec "$C_DB" sh -lc "mysql -uzabbix -p\"$Z_PASS\" -e \"USE zabbix; SELECT COUNT(*) FROM users;\" 2>/dev/null" >> "$LOG_FILE" 2>&1 || true

        else
            # PostgreSQL: el contenedor ya crea user/db, solo importamos schema
            local schema
            schema="$(docker run --rm "zabbix/zabbix-server-${DB_TYPE}:${DOCKER_TAG}" sh -lc "set -e; f=\$(find /usr/share /usr/share/doc -maxdepth 6 -type f \\( -name 'create.sql.gz' -o -name 'server.sql.gz' \\) 2>/dev/null | head -n 1); [ -n \"\$f\" ] && echo \"\$f\"")"
            [ -z "$schema" ] && { echo "[DOCKER] No encontré create.sql.gz/server.sql.gz en la imagen server" >> "$LOG_FILE"; return 1; }

            docker run --rm "zabbix/zabbix-server-${DB_TYPE}:${DOCKER_TAG}" sh -lc "gzip -dc \"$schema\"" \
              | docker exec -i "$C_DB" sh -lc "psql -U zabbix -d zabbix" \
              >/dev/null 2>&1 || { echo "[DOCKER] Import schema (pgsql) falló" >> "$LOG_FILE"; return 1; }
        fi

        # D) Levantar server + web
        if ! $COMPOSE -f docker-compose.yml up -d zabbix-server zabbix-web; then
            echo "[DOCKER] up server/web falló" >> "$LOG_FILE"
            $COMPOSE -f docker-compose.yml ps >> "$LOG_FILE" 2>&1 || true
            $COMPOSE -f docker-compose.yml logs --tail=300 >> "$LOG_FILE" 2>&1 || true
            return 1
        fi

        # E) Validaciones
        if ! docker_wait_web_ok "$DOCKER_WEB_PORT"; then
            echo "[DOCKER] Web no quedó lista" >> "$LOG_FILE"
            docker logs --tail=250 "$C_WEB" >> "$LOG_FILE" 2>&1 || true
            docker logs --tail=250 "$C_SERVER" >> "$LOG_FILE" 2>&1 || true
            docker logs --tail=250 "$C_DB" >> "$LOG_FILE" 2>&1 || true
            return 1
        fi

        return 0
    fi

    # Proxy / Agent: deploy normal
    if ! $COMPOSE -f docker-compose.yml up -d; then
        echo "[DOCKER] compose up falló" >> "$LOG_FILE"
        $COMPOSE -f docker-compose.yml ps >> "$LOG_FILE" 2>&1 || true
        $COMPOSE -f docker-compose.yml logs --tail=250 >> "$LOG_FILE" 2>&1 || true
        return 1
    fi

    return 0
}

# ====== EJECUCIÓN PRINCIPAL ======
[[ $EUID -ne 0 ]] && fail "Este script requiere privilegios de root (sudo)."
check_prereqs
detect_pkg
select_options

echo -e "${B}================================================================================${N}"
echo -e "${BOLD}${C}   INICIANDO DESPLIEGUE EN SEGUNDO PLANO${N}"
echo -e "${B}================================================================================${N}\n"

if [ "$DEPLOY_TYPE" == "1" ]; then
    task_progress_bar "Sincronizando repositorios y llaves GPG" task_repos
    task_progress_bar "Descargando e instalando dependencias" task_packages
    task_progress_bar "Inicializando motor de Base de Datos" task_database
    task_progress_bar "Aplicando politicas de seguridad" task_security
    if [ "$ENABLE_SSL" == "s" ]; then task_progress_bar "Generando Certificados SSL (Let's Encrypt)" task_ssl; fi
    task_progress_bar "Registrando e iniciando servicios Web" task_services
elif [ "$DEPLOY_TYPE" == "2" ]; then
    task_progress_bar "Sincronizando repositorios y llaves GPG" task_repos
    task_progress_bar "Descargando e instalando dependencias" task_packages
    task_progress_bar "Generando DB local y configurando Proxy" task_proxy_db
    task_progress_bar "Aplicando politicas de seguridad" task_security
elif [ "$DEPLOY_TYPE" == "3" ]; then
    task_progress_bar "Sincronizando repositorios y llaves GPG" task_repos
    task_progress_bar "Descargando e instalando dependencias" task_packages
    task_progress_bar "Configurando Zabbix Agent" task_configure_agent
    task_progress_bar "Aplicando politicas de seguridad" task_security
elif [ "$DEPLOY_TYPE" == "4" ]; then
    task_progress_bar "Aplicando politicas de seguridad (Puertos)" task_security
    if [ "$ENABLE_SSL" == "s" ]; then task_progress_bar "Generando Certificados SSL para Docker" task_ssl; fi
    task_progress_bar "Generando y desplegando Stack Docker" task_docker_deploy
fi

rm -f "$VALID_FILE" /tmp/zbx_*.tmp zbx.deb zbx.rpm

END_TIME=$(date +%s)
DURATION=$((END_TIME - START_TIME))
MINS=$((DURATION / 60))
SECS=$((DURATION % 60))

detect_ip

echo ""
echo "${B}================================================================================${N}"
if [ "$DEPLOY_TYPE" == "1" ]; then
    echo "${G}  🚀 ¡ZABBIX SERVER $Z_VER INSTALADO Y DESPLEGADO CON ÉXITO!${N}"
    echo "${B}================================================================================${N}"
    echo "  ⏱️  Tiempo total:  ${C}${MINS}m ${SECS}s${N}"

    if [ "$ENABLE_SSL" == "s" ]; then
        if [ "$WEB_PORT" == "443" ] || [ -z "$WEB_PORT" ]; then
            echo "  🔒 URL Segura:   ${C}https://$SSL_DOMAIN/zabbix${N}"
        else
            echo "  🔒 URL Segura:   ${C}https://$SSL_DOMAIN:${WEB_PORT}/zabbix${N}"
        fi
    else
        if [ "$WEB_PORT" == "80" ] || [ -z "$WEB_PORT" ]; then
            echo "  🌐 URL Acceso:   ${C}http://$IP_ADDR/zabbix${N}"
        else
            echo "  🌐 URL Acceso:   ${C}http://$IP_ADDR:${WEB_PORT}/zabbix${N}"
        fi
    fi

    echo "  👤 Usuario Web:  ${Y}Admin${N} (Con 'A' mayúscula)"
    echo "  🔑 Clave Web:    ${Y}zabbix${N}"

elif [ "$DEPLOY_TYPE" == "2" ]; then
    echo "${G}  🖧 ¡ZABBIX PROXY (SQLite3) $Z_VER INSTALADO Y REPORTANDO A $ZBX_SERVER_IP!${N}"

elif [ "$DEPLOY_TYPE" == "3" ]; then
    echo "${G}  🛡️ ¡ZABBIX AGENT $Z_VER INSTALADO Y REPORTANDO A $ZBX_SERVER_IP!${N}"

elif [ "$DEPLOY_TYPE" == "4" ]; then
    echo "${G}  🐳 ¡STACK DOCKER ZABBIX $Z_VER DESPLEGADO CON ÉXITO!${N}"
    echo "${B}================================================================================${N}"
    echo "  ⏱️  Tiempo total:  ${C}${MINS}m ${SECS}s${N}"
    echo "  🧩 Instancia Docker: ${C}${DOCKER_INSTANCE_ID}${N}"
    echo "  📁 Directorio Compose: ${C}${DOCKER_WORKDIR}${N}"

    if [ "$DOCKER_CAT" == "1" ]; then
        if [ "$DOCKER_WEB_PORT" == "80" ]; then
            echo "  🌐 URL Acceso:   ${C}http://$IP_ADDR/${N}"
        else
            echo "  🌐 URL Acceso:   ${C}http://$IP_ADDR:${DOCKER_WEB_PORT}/${N}"
        fi
        echo "  🧠 Zabbix Server: ${C}${IP_ADDR}:${DOCKER_ZBX_PORT}${N}"
        echo "  👤 Usuario Web:  ${Y}Admin${N} (Con 'A' mayúscula)"
        echo "  🔑 Clave Web:    ${Y}zabbix${N}"
    elif [ "$DOCKER_CAT" == "2" ]; then
        echo "  🖧 Proxy escucha en: ${C}${IP_ADDR}:${DOCKER_ZBX_PORT}${N}"
        echo "  🔌 Proxy reporta a: ${C}${ZBX_SERVER_IP}:${ZBX_SERVER_PORT}${N}"
    elif [ "$DOCKER_CAT" == "3" ]; then
        echo "  🛡️ Agent escucha en: ${C}${IP_ADDR}:${DOCKER_AGENT_PORT}${N}"
        echo "  🔌 Agent reporta a: ${C}${ZBX_SERVER_IP}:${ZBX_SERVER_PORT}${N}"
    fi
fi
echo "${B}================================================================================${N}"
