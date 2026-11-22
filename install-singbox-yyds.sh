#!/usr/bin/env bash
set -euo pipefail

# -----------------------
# 彩色输出函数
status_line() {
    local color="$1" label="$2"
    shift 2
    if [[ -t 1 && -z "${NO_COLOR+x}" && "${TERM:-dumb}" != dumb ]]; then
        printf '\033[1;%sm%s\033[0m %s\n' "$color" "$label" "$*"
    else
        printf '%s %s\n' "$label" "$*"
    fi
}

info() { status_line 34 '[信息]' "$@"; }
ok()   { status_line 32 '[成功]' "$@"; }
warn() { status_line 33 '[警告]' "$@"; }
err()  { status_line 31 '[失败]' "$@" >&2; }

step() {
    printf '\n'
    status_line 34 "[$1/5]" "$2"
}

field() { printf '    %s  %s\n' "$1" "$2"; }

show_protocol_ports() {
    if $ENABLE_SS; then field 'Shadowsocks' "$PORT_SS"; fi
    if $ENABLE_HY2; then field 'Hysteria2' "$PORT_HY2/UDP"; fi
    if $ENABLE_TUIC; then field 'TUIC' "$PORT_TUIC/UDP"; fi
    if $ENABLE_REALITY; then field 'VLESS Reality' "$PORT_REALITY/TCP"; fi
    if $ENABLE_ANYTLS; then field 'AnyTLS Reality' "$PORT_ANYTLS/TCP"; fi
}

# -----------------------
# 检测系统类型
detect_os() {
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        OS_ID="${ID:-}"
        OS_ID_LIKE="${ID_LIKE:-}"
    else
        OS_ID=""
        OS_ID_LIKE=""
    fi

    if echo "$OS_ID $OS_ID_LIKE" | grep -qi "alpine"; then
        OS="alpine"
    elif echo "$OS_ID $OS_ID_LIKE" | grep -Ei "debian|ubuntu" >/dev/null; then
        OS="debian"
    elif echo "$OS_ID $OS_ID_LIKE" | grep -Ei "centos|rhel|fedora" >/dev/null; then
        OS="redhat"
    else
        OS="unknown"
    fi
}


# -----------------------
# 检查 root 权限
check_root() {
    if [ "$(id -u)" != "0" ]; then
        err "此脚本需要 root 权限"
        err "请使用: sudo bash -c \"\$(curl -fsSL ...)\" 或切换到 root 用户"
        exit 1
    fi
}

install_sb() {
    local sb_path=/usr/local/bin/sb temporary
    mkdir -p /usr/local/bin || return 1
    temporary=$(mktemp /usr/local/bin/.sb.XXXXXXXX) || return 1
    if ! cat > "$temporary" <<'SB_SCRIPT'
#!/usr/bin/env bash
set -euo pipefail

status_line() {
    local color="$1" label="$2"
    shift 2
    if [[ -t 1 && -z "${NO_COLOR+x}" && "${TERM:-dumb}" != dumb ]]; then
        printf '\033[1;%sm%s\033[0m %s\n' "$color" "$label" "$*"
    else
        printf '%s %s\n' "$label" "$*"
    fi
}

info() { status_line 34 '[信息]' "$@"; }
warn() { status_line 33 '[警告]' "$@"; }
err()  { status_line 31 '[失败]' "$@" >&2; }

CONFIG_PATH="/etc/sing-box/config.json"
CACHE_FILE="/etc/sing-box/.config_cache"
SERVICE_NAME="sing-box"

if (( EUID != 0 )); then err "请以 root 运行 sb"; exit 1; fi
if command -v flock >/dev/null; then
    exec 9>/run/sing-box-sb.lock
    flock -n 9 || { err "另一个 sb 会话正在运行"; exit 1; }
fi

# 检测系统
detect_os() {
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        ID="${ID:-}"
        ID_LIKE="${ID_LIKE:-}"
    else
        ID=""
        ID_LIKE=""
    fi

    if echo "$ID $ID_LIKE" | grep -qi "alpine"; then
        OS="alpine"
    elif echo "$ID $ID_LIKE" | grep -Ei "debian|ubuntu" >/dev/null; then
        OS="debian"
    elif echo "$ID $ID_LIKE" | grep -Ei "centos|rhel|fedora" >/dev/null; then
        OS="redhat"
    else
        OS="unknown"
    fi
}

detect_os

# 服务控制
service_start() {
    [ "$OS" = "alpine" ] && rc-service "$SERVICE_NAME" start || systemctl start "$SERVICE_NAME"
}
service_stop() {
    [ "$OS" = "alpine" ] && rc-service "$SERVICE_NAME" stop || systemctl stop "$SERVICE_NAME"
}
service_restart() {
    if [ "$OS" = "alpine" ]; then rc-service "$SERVICE_NAME" restart; else systemctl restart "$SERVICE_NAME"; fi
}
service_status() {
    if [ "$OS" = "alpine" ]; then rc-service "$SERVICE_NAME" status; else systemctl status "$SERVICE_NAME" --no-pager; fi
}

# 生成随机值
rand_port() { shuf -i 10000-60000 -n 1 2>/dev/null || echo $((RANDOM % 50001 + 10000)); }
rand_pass() { openssl rand -base64 16 | tr -d '\n\r' || head -c 16 /dev/urandom | base64 | tr -d '\n\r'; }
rand_uuid() { cat /proc/sys/kernel/random/uuid 2>/dev/null || openssl rand -hex 16 | sed 's/\(..\)\(..\)\(..\)\(..\)\(..\)\(..\)\(..\)\(..\)\(..\)\(..\)\(..\)\(..\)\(..\)\(..\)\(..\)\(..\)/\1\2\3\4-\5\6-\7\8-\9\10-\11\12\13\14\15\16/'; }

# URL 编码
url_encode() {
    printf "%s" "$1" | sed -e 's/%/%25/g' -e 's/:/%3A/g' -e 's/+/%2B/g' -e 's/\//%2F/g' -e 's/=/%3D/g'
}

# 读取配置
read_config() {
    if [ ! -f "$CONFIG_PATH" ]; then
        err "未找到配置文件: $CONFIG_PATH"
        return 1
    fi
    
    # 优先加载 .protocols 文件（确认协议标记）
    PROTOCOL_FILE="/etc/sing-box/.protocols"
    if [ -f "$PROTOCOL_FILE" ]; then
        . "$PROTOCOL_FILE"
    fi
    
    # 加载缓存文件（包含端口密码等详细配置）
    if [ -f "$CACHE_FILE" ]; then
        . "$CACHE_FILE"
    fi
    
    # 确保有默认值
    REALITY_SNI="${REALITY_SNI:-addons.mozilla.org}"
    ENABLE_ANYTLS="${ENABLE_ANYTLS:-false}"
    CUSTOM_IP="${CUSTOM_IP:-}"

    # 读取各协议配置
    if [ "${ENABLE_SS:-false}" = "true" ]; then
        SS_PORT=$(jq -r '.inbounds[] | select(.type=="shadowsocks") | .listen_port // empty' "$CONFIG_PATH" | head -n1)
        SS_PSK=$(jq -r '.inbounds[] | select(.type=="shadowsocks") | .password // empty' "$CONFIG_PATH" | head -n1)
        SS_METHOD=$(jq -r '.inbounds[] | select(.type=="shadowsocks") | .method // empty' "$CONFIG_PATH" | head -n1)
    fi
    
    if [ "${ENABLE_HY2:-false}" = "true" ]; then
        HY2_PORT=$(jq -r '.inbounds[] | select(.type=="hysteria2") | .listen_port // empty' "$CONFIG_PATH" | head -n1)
        HY2_PSK=$(jq -r '.inbounds[] | select(.type=="hysteria2") | .users[0].password // empty' "$CONFIG_PATH" | head -n1)
    fi
    
    if [ "${ENABLE_TUIC:-false}" = "true" ]; then
        TUIC_PORT=$(jq -r '.inbounds[] | select(.type=="tuic") | .listen_port // empty' "$CONFIG_PATH" | head -n1)
        TUIC_UUID=$(jq -r '.inbounds[] | select(.type=="tuic") | .users[0].uuid // empty' "$CONFIG_PATH" | head -n1)
        TUIC_PSK=$(jq -r '.inbounds[] | select(.type=="tuic") | .users[0].password // empty' "$CONFIG_PATH" | head -n1)
    fi
    
# Reality 公共参数（Reality / AnyTLS 共用）
if [ "${ENABLE_REALITY:-false}" = "true" ] || [ "${ENABLE_ANYTLS:-false}" = "true" ]; then
    REALITY_SID=$(jq -r '
        .inbounds[]
        | select(.tls.reality.enabled == true)
        | .tls.reality.short_id[0] // empty
    ' "$CONFIG_PATH" | head -n1)

    [ -f /etc/sing-box/.reality_pub ] && REALITY_PUB=$(cat /etc/sing-box/.reality_pub)
fi

# VLESS Reality 专属参数
if [ "${ENABLE_REALITY:-false}" = "true" ]; then
    REALITY_PORT=$(jq -r '.inbounds[] | select(.type=="vless") | .listen_port // empty' "$CONFIG_PATH" | head -n1)

    REALITY_UUID=$(jq -r '.inbounds[] | select(.type=="vless") | .users[0].uuid // empty' "$CONFIG_PATH" | head -n1)

    REALITY_PK=$(jq -r '.inbounds[] | select(.type=="vless") | .tls.reality.private_key // empty' "$CONFIG_PATH" | head -n1)
fi

if [ "${ENABLE_ANYTLS:-false}" = "true" ]; then
    ANYTLS_PORT=$(jq -r '.inbounds[] | select(.type=="anytls") | .listen_port // empty' "$CONFIG_PATH" | head -n1)
    ANYTLS_USER=$(jq -r '.inbounds[] | select(.type=="anytls") | .users[0].name // empty' "$CONFIG_PATH" | head -n1)
    ANYTLS_PSK=$(jq -r '.inbounds[] | select(.type=="anytls") | .users[0].password // empty' "$CONFIG_PATH" | head -n1)
fi
}

# 获取公网IP（原始方法）
get_public_ip() {
    local ip=""
    for url in "https://api.ipify.org" "https://ipinfo.io/ip" "https://ifconfig.me"; do
        ip=$(curl -s --max-time 5 "$url" 2>/dev/null | tr -d '[:space:]')
        [ -n "$ip" ] && echo "$ip" && return 0
    done
    echo "YOUR_SERVER_IP"
}

# 生成并保存URI
generate_uris() {
    read_config || return 1

    # 优先使用用户自定义入口 IP
    if [ -n "${CUSTOM_IP:-}" ]; then
        PUBLIC_IP="$CUSTOM_IP"
    else
        PUBLIC_IP=$(get_public_ip)
    fi

    node_suffix=$(cat /root/node_names.txt 2>/dev/null || echo "")
    
    URI_FILE="/etc/sing-box/uris.txt"
    > "$URI_FILE"
    
    if [ "${ENABLE_SS:-false}" = "true" ]; then
        ss_userinfo="${SS_METHOD}:${SS_PSK}"
        ss_encoded=$(url_encode "$ss_userinfo")
        ss_b64=$(printf "%s" "$ss_userinfo" | base64 -w0 2>/dev/null || printf "%s" "$ss_userinfo" | base64 | tr -d '\n')
        
        echo "=== Shadowsocks (SS) ===" >> "$URI_FILE"
        echo "ss://${ss_encoded}@${PUBLIC_IP}:${SS_PORT}#ss${node_suffix}" >> "$URI_FILE"
        echo "ss://${ss_b64}@${PUBLIC_IP}:${SS_PORT}#ss${node_suffix}" >> "$URI_FILE"
        echo "" >> "$URI_FILE"
    fi
    
    if [ "${ENABLE_HY2:-false}" = "true" ]; then
        hy2_encoded=$(url_encode "$HY2_PSK")
        echo "=== Hysteria2 (HY2) ===" >> "$URI_FILE"
        echo "hy2://${hy2_encoded}@${PUBLIC_IP}:${HY2_PORT}/?sni=www.bing.com&alpn=h3&insecure=1#hy2${node_suffix}" >> "$URI_FILE"
        echo "" >> "$URI_FILE"
    fi
    
    if [ "${ENABLE_TUIC:-false}" = "true" ]; then
        tuic_encoded=$(url_encode "$TUIC_PSK")
        echo "=== TUIC ===" >> "$URI_FILE"
        echo "tuic://${TUIC_UUID}:${tuic_encoded}@${PUBLIC_IP}:${TUIC_PORT}/?congestion_control=bbr&alpn=h3&sni=www.bing.com&insecure=1#tuic${node_suffix}" >> "$URI_FILE"
        echo "" >> "$URI_FILE"
    fi
    
    if [ "${ENABLE_REALITY:-false}" = "true" ]; then
        REALITY_SNI="${REALITY_SNI:-addons.mozilla.org}"
        echo "=== VLESS Reality ===" >> "$URI_FILE"
        echo "vless://${REALITY_UUID}@${PUBLIC_IP}:${REALITY_PORT}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${REALITY_SNI}&fp=chrome&pbk=${REALITY_PUB}&sid=${REALITY_SID}#reality${node_suffix}" >> "$URI_FILE"
        echo "" >> "$URI_FILE"
    fi
    
    if [ "${ENABLE_ANYTLS:-false}" = "true" ]; then
        anytls_user_encoded=$(url_encode "$ANYTLS_USER")
        anytls_pass_encoded=$(url_encode "$ANYTLS_PSK")
        echo "=== AnyTLS Reality ===" >> "$URI_FILE"
        echo "anytls://${anytls_pass_encoded}@${PUBLIC_IP}:${ANYTLS_PORT}/?security=reality&sni=${REALITY_SNI}&fp=chrome&pbk=${REALITY_PUB}&sid=${REALITY_SID}#anytls${node_suffix}" >> "$URI_FILE"
        echo "" >> "$URI_FILE"
    fi

    info "URI 已保存到: $URI_FILE"
}

# 查看URI
action_view_uri() {
    info "正在生成并显示 URI..."
    generate_uris || { err "生成 URI 失败"; return 1; }
    echo ""
    cat /etc/sing-box/uris.txt
}

# 查看配置文件路径
action_view_config() {
    echo "$CONFIG_PATH"
}

# 编辑配置
action_edit_config() {
    if [ ! -f "$CONFIG_PATH" ]; then
        err "配置文件不存在: $CONFIG_PATH"
        return 1
    fi
    
    ${EDITOR:-nano} "$CONFIG_PATH" 2>/dev/null || ${EDITOR:-vi} "$CONFIG_PATH"
    
    if command -v sing-box >/dev/null 2>&1; then
        if sing-box check -c "$CONFIG_PATH" >/dev/null 2>&1; then
            info "配置校验通过,已重启服务"
            service_restart || warn "重启失败"
            generate_uris || true
        else
            warn "配置校验失败,服务未重启"
        fi
    fi
}

# 重置SS端口
action_reset_ss() {
    read_config || return 1
    
    if [ "${ENABLE_SS:-false}" != "true" ]; then
        err "SS 协议未启用"
        return 1
    fi
    
    read -p "输入新的 SS 端口(回车保持 $SS_PORT): " new_port
    new_port="${new_port:-$SS_PORT}"
    
    info "正在停止服务..."
    service_stop || warn "停止服务失败"
    
    cp "$CONFIG_PATH" "${CONFIG_PATH}.bak"
    
    jq --argjson port "$new_port" '
    .inbounds |= map(if .type=="shadowsocks" then .listen_port = $port else . end)
    ' "$CONFIG_PATH" > "${CONFIG_PATH}.tmp" && mv "${CONFIG_PATH}.tmp" "$CONFIG_PATH"
    
    info "已启动服务并更新 SS 端口: $new_port"
    service_start || warn "启动服务失败"
    sleep 1
    generate_uris || warn "生成 URI 失败"
}

# 重置HY2端口
action_reset_hy2() {
    read_config || return 1
    
    if [ "${ENABLE_HY2:-false}" != "true" ]; then
        err "HY2 协议未启用"
        return 1
    fi
    
    read -p "输入新的 HY2 端口(回车保持 $HY2_PORT): " new_port
    new_port="${new_port:-$HY2_PORT}"
    
    info "正在停止服务..."
    service_stop || warn "停止服务失败"
    
    cp "$CONFIG_PATH" "${CONFIG_PATH}.bak"
    
    jq --argjson port "$new_port" '
    .inbounds |= map(if .type=="hysteria2" then .listen_port = $port else . end)
    ' "$CONFIG_PATH" > "${CONFIG_PATH}.tmp" && mv "${CONFIG_PATH}.tmp" "$CONFIG_PATH"
    
    info "已启动服务并更新 HY2 端口: $new_port"
    service_start || warn "启动服务失败"
    sleep 1
    generate_uris || warn "生成 URI 失败"
}

# 重置TUIC端口
action_reset_tuic() {
    read_config || return 1
    
    if [ "${ENABLE_TUIC:-false}" != "true" ]; then
        err "TUIC 协议未启用"
        return 1
    fi
    
    read -p "输入新的 TUIC 端口(回车保持 $TUIC_PORT): " new_port
    new_port="${new_port:-$TUIC_PORT}"
    
    info "正在停止服务..."
    service_stop || warn "停止服务失败"
    
    cp "$CONFIG_PATH" "${CONFIG_PATH}.bak"
    
    jq --argjson port "$new_port" '
    .inbounds |= map(if .type=="tuic" then .listen_port = $port else . end)
    ' "$CONFIG_PATH" > "${CONFIG_PATH}.tmp" && mv "${CONFIG_PATH}.tmp" "$CONFIG_PATH"
    
    info "已启动服务并更新 TUIC 端口: $new_port"
    service_start || warn "启动服务失败"
    sleep 1
    generate_uris || warn "生成 URI 失败"
}

# 重置Vless Reality端口
action_reset_reality() {
    read_config || return 1
    
    if [ "${ENABLE_REALITY:-false}" != "true" ]; then
        err "Vless Reality 协议未启用"
        return 1
    fi
    
    read -p "输入新的 Vless Reality 端口(回车保持 $REALITY_PORT): " new_port
    new_port="${new_port:-$REALITY_PORT}"
    
    info "正在停止服务..."
    service_stop || warn "停止服务失败"
    
    cp "$CONFIG_PATH" "${CONFIG_PATH}.bak"
    
    jq --argjson port "$new_port" '
    .inbounds |= map(if .type=="vless" then .listen_port = $port else . end)
    ' "$CONFIG_PATH" > "${CONFIG_PATH}.tmp" && mv "${CONFIG_PATH}.tmp" "$CONFIG_PATH"
    
    info "已启动服务并更新 Vless Reality 端口: $new_port"
    service_start || warn "启动服务失败"
    sleep 1
    generate_uris || warn "生成 URI 失败"
}

# 重置AnyTLS Reality端口
action_reset_anytls() {
    read_config || return 1

    if [ "${ENABLE_ANYTLS:-false}" != "true" ]; then
        err "AnyTLS Reality 协议未启用"
        return 1
    fi

    read -p "输入新的 AnyTLS Reality 端口(回车保持 $ANYTLS_PORT): " new_port
    new_port="${new_port:-$ANYTLS_PORT}"

    info "正在停止服务..."
    service_stop || warn "停止服务失败"

    cp "$CONFIG_PATH" "${CONFIG_PATH}.bak"

    jq --argjson port "$new_port" '
    .inbounds |= map(if .type=="anytls" then .listen_port = $port else . end)
    ' "$CONFIG_PATH" > "${CONFIG_PATH}.tmp" && mv "${CONFIG_PATH}.tmp" "$CONFIG_PATH"

    info "已启动服务并更新 AnyTLS Reality 端口: $new_port"
    service_start || warn "启动服务失败"
    sleep 1
    generate_uris || warn "生成 URI 失败"
}

# 更新sing-box
action_update() {
    info "开始更新 sing-box..."
    if [ "$OS" = "alpine" ]; then
        apk update && apk upgrade sing-box || bash <(curl -fsSL https://sing-box.app/install.sh)
    else
        bash <(curl -fsSL https://sing-box.app/install.sh)
    fi
    
    info "更新完成,已重启服务..."
    if command -v sing-box >/dev/null 2>&1; then
        NEW_VER=$(sing-box version 2>/dev/null | head -n1)
        info "当前版本: $NEW_VER"
        service_restart || warn "重启失败"
    fi
}

# 卸载
action_uninstall() {
    read -p "确认卸载 sing-box?(y/N): " confirm
    [[ ! "$confirm" =~ ^[Yy]$ ]] && info "已取消" && return 0
    
    info "正在卸载..."
    service_stop || true
    if [ "$OS" = "alpine" ]; then
        rc-update del sing-box default 2>/dev/null || true
        rm -f /etc/init.d/sing-box
        apk del sing-box 2>/dev/null || true
    else
        systemctl stop sing-box 2>/dev/null || true
        systemctl disable sing-box 2>/dev/null || true
        rm -f /etc/systemd/system/sing-box.service
        systemctl daemon-reload 2>/dev/null || true
        apt purge -y sing-box >/dev/null 2>&1 || true
    fi
    rm -rf /etc/sing-box /var/log/sing-box* /usr/local/bin/sb /usr/bin/sing-box /root/node_names.txt 2>/dev/null || true
    info "卸载完成"
}

# 解析分享链接；通过标准输入传递凭据，避免写入命令行参数。
decode_share_component() {
    local input="$1" output="" hex
    while [[ "$input" == *%* ]]; do
        output+="${input%%%*}"
        input="${input#*%}"
        hex="${input:0:2}"
        [[ "$hex" =~ ^[[:xdigit:]]{2}$ && "$hex" != 00 ]] || return 1
        printf -v hex '%b' "\\x$hex"
        output+="$hex"
        input="${input:2}"
    done
    printf '%s' "$output$input"
}

decode_share_base64() {
    local value="$1"
    [[ "$value" =~ ^[A-Za-z0-9_+/-]+=*$ ]] || return 1
    value="${value//-/+}"
    value="${value//_//}"
    while (( ${#value} % 4 )); do value+='='; done
    printf '%s' "$value" | base64 -d 2>/dev/null
}

parse_user_outbound() {
    local uri="$1" scheme body address auth server port query="" pair key value
    local method password transport security flow legacy=false tls='null' transport_json='null'
    local -A params=()
    scheme="${uri%%://*}"
    [[ "$scheme" == vless || "$scheme" == ss ]] || return 1
    body="${uri#*://}"
    body="${body%%#*}"
    if [[ "$body" == *\?* ]]; then
        query="${body#*?}"
        body="${body%%?*}"
    fi
    if [[ "$scheme" == ss && "$body" != *@* ]]; then
        body=$(decode_share_base64 "$body") || return 1
        legacy=true
    fi
    [[ "$body" == *@* ]] || return 1
    auth="${body%@*}"
    address="${body##*@}"
    address="${address%/}"
    local address_pattern='^(\[([0-9A-Fa-f:.]+)\]|([A-Za-z0-9._-]+)):([0-9]{1,5})$'
    [[ "$address" =~ $address_pattern ]] || return 1
    server="${BASH_REMATCH[2]:-${BASH_REMATCH[3]}}"
    port=$((10#${BASH_REMATCH[4]}))
    (( port > 0 && port <= 65535 )) || return 1

    if [[ "$scheme" == ss ]]; then
        [[ -z "$query" ]] || return 1
        if ! $legacy; then auth=$(decode_share_component "$auth") || return 1; fi
        if [[ "$auth" != *:* ]]; then auth=$(decode_share_base64 "$auth") || return 1; fi
        [[ "$auth" == *:* ]] || return 1
        method="${auth%%:*}"
        password="${auth#*:}"
        [[ -n "$method" && -n "$password" ]] || return 1
        printf '%s' "$password" | jq -Rs --arg server "$server" --argjson port "$port" --arg method "$method" \
            '{type:"shadowsocks",server:$server,server_port:$port,method:$method,password:.}'
        return $?
    fi

    [[ "$auth" =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$ ]] || return 1
    local -a pairs=()
    IFS='&' read -r -a pairs <<< "$query"
    for pair in "${pairs[@]}"; do
        [[ "$pair" == *=* ]] || return 1
        key="${pair%%=*}"
        case "$key" in
            type|security|flow|encryption|sni|fp|pbk|sid|alpn|host|path|serviceName|mode|headerType) ;;
            *) return 1 ;;
        esac
        [[ ! -v 'params[$key]' ]] || return 1
        value=$(decode_share_component "${pair#*=}") || return 1
        params[$key]="$value"
    done
    [[ "${params[encryption]:-none}" == none && "${params[headerType]:-none}" == none ]] || return 1
    transport="${params[type]:-tcp}"
    security="${params[security]:-none}"
    flow="${params[flow]:-}"
    [[ -z "$flow" || "$flow" == xtls-rprx-vision && ( "$transport" == tcp || "$transport" == raw ) && "$security" != none ]] || return 1
    case "$transport" in
        tcp|raw)
            [[ -z "${params[host]:-}${params[path]:-}${params[serviceName]:-}${params[mode]:-}" ]] || return 1
            ;;
        ws)
            [[ -z "${params[serviceName]:-}${params[mode]:-}" ]] || return 1
            transport_json=$(jq -cn --arg path "${params[path]:-/}" --arg host "${params[host]:-}" '
                {type:"ws", path:$path} + (if $host == "" then {} else {headers:{Host:$host}} end)
            ') || return 1
            ;;
        grpc)
            [[ "${params[mode]:-gun}" == gun && -z "${params[host]:-}${params[path]:-}" ]] || return 1
            transport_json=$(jq -cn --arg service "${params[serviceName]:-}" '{type:"grpc",service_name:$service}') || return 1
            ;;
        *) return 1 ;;
    esac
    case "$security" in
        none)
            [[ -z "${params[sni]:-}${params[fp]:-}${params[pbk]:-}${params[sid]:-}${params[alpn]:-}" ]] || return 1
            ;;
        tls|reality)
            if [[ "$security" == reality ]]; then
                [[ -n "${params[pbk]:-}" && -n "${params[sni]:-}" ]] || return 1
            else
                [[ -z "${params[pbk]:-}${params[sid]:-}" ]] || return 1
            fi
            tls=$(jq -cn --arg security "$security" --arg sni "${params[sni]:-$server}" \
                --arg fp "${params[fp]:-}" --arg alpn "${params[alpn]:-}" \
                --arg pbk "${params[pbk]:-}" --arg sid "${params[sid]:-}" '
                {enabled:true,server_name:$sni}
                + (if $alpn == "" then {} else {alpn:($alpn|split(","))} end)
                + (if $security == "reality" or $fp != "" then
                    {utls:{enabled:true,fingerprint:(if $fp == "" then "chrome" else $fp end)}}
                   else {} end)
                + (if $security == "reality" then {reality:{enabled:true,public_key:$pbk,short_id:$sid}}
                   else {} end)
            ') || return 1
            ;;
        *) return 1 ;;
    esac
    printf '%s' "$auth" | jq -cRs --arg server "$server" --argjson port "$port" --arg flow "$flow" \
        --argjson tls "$tls" --argjson transport "$transport_json" '
        {type:"vless", server:$server, server_port:$port, uuid:., flow:$flow, tls:$tls, transport:$transport}
        | with_entries(select(.value != null and .value != ""))
    '
}

user_protocol_name() {
    case "$1" in
        hysteria2) printf '%s' 'Hysteria2' ;;
        tuic) printf '%s' 'TUIC' ;;
        vless) printf '%s' 'VLESS + REALITY' ;;
        anytls) printf '%s' 'AnyTLS + REALITY' ;;
    esac
}

# 用户凭据直接保存到 sing-box 入站的 users 数组。
user_action() (
    local rows inbound type port choice index op name pass="" uuid="" flow="" entry count host selected_name
    local pending="" backup="" record label sni pub sid action revision link generated_name="" current_exit=""
    local -a options=()
    command -v flock >/dev/null || { err "请先安装 flock 工具"; return 1; }
    revision=$(sha256sum < "$CONFIG_PATH") || return 1
    rows=$(jq -r '
        .inbounds | to_entries[]
        | select(.value.users | type == "array")
        | select(.value.type == "hysteria2" or .value.type == "tuic"
            or ((.value.type == "vless" or .value.type == "anytls")
                and .value.tls.reality.enabled == true))
        | [.key, .value.type, .value.listen_port, (.value.users | length)] | @tsv
    ' "$CONFIG_PATH") || return 1
    [[ -n "$rows" ]] || { warn "暂无支持用户管理的入站"; return 0; }

    printf '\n  ────────────────────────────────────\n'
    status_line 34 '用户管理' '选择入站协议'
    printf '\n'
    while IFS=$'\t' read -r inbound type port count; do
        options+=("$inbound $type $port $count")
        printf '  %s) %s · 端口 %s · %s 位用户\n' "${#options[@]}" "$(user_protocol_name "$type")" "$port" "$count"
    done <<< "$rows"
    printf '\n  0) 返回主菜单\n\n请选择入站：'
    IFS= read -r choice || return 0
    [[ "$choice" == 0 ]] && return 0
    if [[ ! "$choice" =~ ^[1-9][0-9]{0,5}$ ]] || (( choice > ${#options[@]} )); then
        warn "无效选项"
        return 0
    fi
    read -r inbound type port count <<< "${options[choice - 1]}"
    printf '\n  ────────────────────────────────────\n'
    status_line 34 "$(user_protocol_name "$type")" "端口 $port · $count 位用户"
    printf '\n  用户列表\n'
    jq -r --argjson i "$inbound" '
        . as $cfg | .inbounds[$i] as $in
        | $in.users | to_entries[]
        | (.value.name // "") as $name
        | ("sb-user-exit:" + ([$in.tag, $name] | @base64)) as $tag
        | (if $in.type == "tuic" then ""
           elif any($cfg.route.rules[]?; . == {inbound:[$in.tag],auth_user:[$name],action:"route",outbound:$tag})
           then " · 独立出口"
           else " · 默认路由" end) as $status
        | "    \(.key + 1). \(if $name == "" then "未命名账号" else $name end)\($status)"
    ' "$CONFIG_PATH" || return 1
    if (( count == 0 )); then printf '    暂无用户\n'; fi
    printf '\n  操作\n    1) 新增用户\n    2) 查看用户链接\n    3) 删除用户\n'
    if [[ "$type" != tuic ]]; then printf '    4) 配置用户出口\n'; fi
    printf '    0) 返回主菜单\n\n请选择操作：'
    IFS= read -r op || return 0
    case "$op" in
        0) return 0 ;;
        1)
            printf '用户名（1–32 位英文字母、数字、点、下划线或连字符）：'
            IFS= read -r name || return 0
            [[ "$name" =~ ^[A-Za-z0-9._-]{1,32}$ ]] || { warn "用户名格式无效"; return 0; }
            if jq -e --argjson i "$inbound" --arg n "$name" \
                'any(.inbounds[$i].users[]; .name == $n)' "$CONFIG_PATH" >/dev/null; then
                warn "该入站下已存在同名用户"
                return 0
            fi
            case "$type" in
                hysteria2|anytls) pass=$(openssl rand -hex 16) || return 1 ;;
                tuic) uuid=$(rand_uuid) && pass=$(openssl rand -hex 16) || return 1 ;;
                vless)
                    uuid=$(rand_uuid) || return 1
                    flow=$(jq -r --argjson i "$inbound" '.inbounds[$i].users[0].flow // ""' "$CONFIG_PATH") || return 1
                    ;;
            esac
            entry=$(printf '%s\n' "$pass" "$uuid" | jq -cRn --arg n "$name" --arg f "$flow" '
                [inputs] | {name:$n, password:.[0], uuid:.[1], flow:$f}
                | with_entries(select(.value != ""))
            ') || return 1
            index="$count"
            action=add
            ;;
        2|3|4)
            if [[ "$op" == 4 && "$type" == tuic ]]; then warn "该协议不支持配置用户出口"; return 0; fi
            if (( count == 0 )); then warn "此入站没有用户"; return 0; fi
            printf '\n请选择用户编号 [0 取消]：'
            IFS= read -r index || return 0
            [[ "$index" == 0 ]] && return 0
            if [[ ! "$index" =~ ^[1-9][0-9]{0,5}$ ]] || (( index > count )); then
                warn "用户编号无效"
                return 0
            fi
            index=$((index - 1))
            selected_name=$(jq -r --argjson i "$inbound" --argjson j "$index" '.inbounds[$i].users[$j].name // ""' "$CONFIG_PATH") || return 1
            if [[ "$op" == 3 ]]; then
                if (( count == 1 )); then warn "每个入站至少保留一个用户"; return 0; fi
                printf '删除「%s」并重启服务？其链接将失效 [y/N]：' "${selected_name:-未命名账号 #$((index + 1))}"
                IFS= read -r choice || return 0
                [[ "$choice" =~ ^[Yy]$ ]] || return 0
                action=delete
                entry=null
            elif [[ "$op" == 4 ]]; then
                record=$(jq -ce --argjson i "$inbound" --argjson j "$index" '
                    .inbounds[$i] | select(.tag | type == "string" and length > 0)
                    | {tag, name:(.users[$j].name // "")}
                ' "$CONFIG_PATH") || { warn "该入站没有可用的标签"; return 1; }
                name=$(jq -r '.name' <<< "$record") || return 1
                current_exit=$(jq -r --argjson i "$inbound" --argjson j "$index" '
                    .inbounds[$i] as $in
                    | ($in.users[$j].name // "") as $name
                    | ("sb-user-exit:" + ([$in.tag, $name] | @base64)) as $tag
                    | if any(.route.rules[]?; . == {inbound:[$in.tag],auth_user:[$name],action:"route",outbound:$tag})
                      then [.outbounds[] | select(.tag == $tag) | "\(.type) · \(.server):\(.server_port)"][0] // ""
                      else "" end
                ' "$CONFIG_PATH") || return 1
                printf '\n  用户：%s\n  当前出口：%s\n\n' "${selected_name:-未命名账号}" "${current_exit:-使用默认路由}"
                printf '  1) 导入或更换出口\n  2) 恢复默认路由\n  0) 返回\n请选择：'
                IFS= read -r choice || return 0
                action=unbind
                entry=null
                case "$choice" in
                    0) return 0 ;;
                    1)
                        printf '粘贴 vless:// 或 ss:// 链接（输入隐藏）：'
                        IFS= read -rs link || return 0
                        printf '\n'
                        if ! entry=$(parse_user_outbound "$link" 2>/dev/null); then
                            warn "链接格式无效，或传输方式、加密参数暂不支持"
                            return 1
                        fi
                        unset link
                        if [[ -z "$name" ]]; then
                            generated_name=$(rand_uuid) || return 1
                            generated_name="sb-user-$generated_name"
                        fi
                        action=bind
                        ;;
                    2) [[ -n "$current_exit" ]] || return 0 ;;
                    *) warn "无效选项"; return 0 ;;
                esac
                printf '应用出口配置并重启服务？[y/N]：'
                IFS= read -r choice || return 0
                [[ "$choice" =~ ^[Yy]$ ]] || return 0
            fi
            ;;
        *) warn "无效选项"; return 0 ;;
    esac

    if [[ "$op" != 2 ]]; then
        pending=$(mktemp "${CONFIG_PATH%/*}/.users-new.XXXXXXXX.json") || return 1
        trap 'rm -f -- "$pending" "$backup"' EXIT
        backup=$(mktemp "${CONFIG_PATH%/*}/.users-old.XXXXXXXX.json") || return 1
        cat "$CONFIG_PATH" > "$backup" || return 1
        if [[ "$(sha256sum < "$backup")" != "$revision" ]]; then
            err "配置刚刚被修改，请重试"
            return 1
        fi
        jq -e --argjson i "$inbound" --argjson j "$index" --slurpfile data <(printf '%s\n' "$entry") \
            --arg generated_name "$generated_name" --arg op "$action" '
            def route_for($in; $name; $tag):
                {inbound:[$in],auth_user:[$name],action:"route",outbound:$tag};
            def remove_binding($rule):
                if any(.route.rules[]?; . == $rule) then
                    .route.rules |= map(select(. != $rule))
                    | .outbounds |= map(select(.tag != $rule.outbound))
                else . end;
            def add_domain_resolver($out):
                if ($out.server | contains(":") or test("^[0-9.]+$")) then .
                elif .route.default_domain_resolver != null then .
                elif (.dns.servers // [] | length) == 1 then .
                else
                    if any(.dns.servers[]?; .tag == "sb-user-exit-dns" and .type != "local")
                    then error("用户出口 DNS 标签已被占用") else . end
                    | if any(.dns.servers[]?; .tag == "sb-user-exit-dns") then .
                      else .dns.servers = ((.dns.servers // []) + [{type:"local",tag:"sb-user-exit-dns"}])
                      end
                    | .outbounds[-1].domain_resolver = "sb-user-exit-dns"
                end;
            if $op == "add" then .inbounds[$i].users += $data
            else
                .inbounds[$i] as $in
                | ($in.users[$j].name // "") as $original_name
                | (if $original_name == "" then $generated_name else $original_name end) as $name
                | ("sb-user-exit:" + ([$in.tag, $name] | @base64)) as $tag
                | route_for($in.tag; $name; $tag) as $rule
                | remove_binding($rule)
                | if $op == "delete" then del(.inbounds[$i].users[$j])
                  elif $op == "bind" then
                      if $name == "" or ($in.tag // "") == "" or
                          ([.inbounds[] | select(.tag == $in.tag)] | length) != 1 or
                          ([$in.users[] | select(.name == $name)] | length) > (if $original_name == "" then 0 else 1 end) or
                          any(.outbounds[]?; .tag == $tag)
                      then error("入站、用户名或出口标签冲突") else . end
                      | .inbounds[$i].users[$j].name = $name
                      | .outbounds += [$data[0] + {tag:$tag}]
                      | .route.rules = ([$rule] + (.route.rules // []))
                      | add_domain_resolver($data[0])
                  else . end
            end
        ' "$backup" > "$pending" || return 1
        if ! sing-box check -c "$pending" >/dev/null 2>&1; then
            err "新配置校验失败，请核对协议参数和 sing-box 版本。原配置已保留。"
            return 1
        fi
        if ! cmp -s "$backup" "$CONFIG_PATH"; then err "配置刚刚被修改，请重试"; return 1; fi
        mv -f "$pending" "$CONFIG_PATH" || return 1
        if ! (service_restart && sleep 1 && service_status >/dev/null 2>&1); then
            err "服务异常，正在恢复原配置"
            if ! mv -f "$backup" "$CONFIG_PATH"; then
                trap - EXIT
                err "无法恢复原配置，备份位于 $backup"
                return 1
            fi
            service_restart || err "原配置已恢复，请检查服务状态"
            return 1
        fi
        if [[ "$op" == 3 ]]; then info "用户已删除"; return 0; fi
        if [[ "$op" == 4 ]]; then info "用户出口已更新"; return 0; fi
        info "已新增用户 $name"
    fi

    read_config || return 1
    host="${CUSTOM_IP:-}"
    if [[ -z "$host" ]]; then host=$(get_public_ip) || return 1; fi
    if [[ "$host" == *:* && "$host" != \[*\] ]]; then host="[$host]"; fi
    record=$(jq -ce --argjson i "$inbound" --argjson j "$index" '
        .inbounds[$i] | {tls, user: .users[$j]} | select(.user != null)
    ' "$CONFIG_PATH") || return 1
    label=$(jq -r '(.user.name // "现有账号") | @uri' <<< "$record")
    pass=$(jq -r '(.user.password // "") | @uri' <<< "$record")
    uuid=$(jq -r '.user.uuid // ""' <<< "$record")
    sni=$(jq -r '(.tls.server_name // .tls.reality.handshake.server // "www.bing.com") | @uri' <<< "$record")
    case "$type" in
        hysteria2)
            printf '\nhy2://%s@%s:%s/?sni=%s&alpn=h3&insecure=1#%s\n' "$pass" "$host" "$port" "$sni" "$label"
            ;;
        tuic)
            printf '\ntuic://%s:%s@%s:%s/?congestion_control=bbr&alpn=h3&sni=%s&insecure=1#%s\n' "$uuid" "$pass" "$host" "$port" "$sni" "$label"
            ;;
        vless|anytls)
            pub="${REALITY_PUB:-}"
            [[ -n "$pub" ]] || { err "找不到现有 Reality 公钥"; return 1; }
            sid=$(jq -r '.tls.reality.short_id[0] // ""' <<< "$record")
            if [[ "$type" == vless ]]; then
                flow=$(jq -r '(.user.flow // "") | @uri' <<< "$record")
                printf '\nvless://%s@%s:%s?encryption=none&flow=%s&security=reality&sni=%s&fp=chrome&pbk=%s&sid=%s#%s\n' "$uuid" "$host" "$port" "$flow" "$sni" "$pub" "$sid" "$label"
            else
                printf '\nanytls://%s@%s:%s/?security=reality&sni=%s&fp=chrome&pbk=%s&sid=%s#%s\n' "$pass" "$host" "$port" "$sni" "$pub" "$sid" "$label"
            fi
            ;;
    esac
)

# 动态生成菜单
show_menu() {
    read_config 2>/dev/null || true
    
    printf '\n  ────────────────────────────────────\n'
    status_line 34 'Sing-box' '管理面板'
    printf '  ────────────────────────────────────\n\n'
    printf '  %s\n' '1) 查看协议链接' '2) 查看配置文件路径' '3) 编辑配置文件' '4) 用户管理'

    # 构建协议重置选项映射
    declare -g -A MENU_MAP
    local option=5
    
    if [ "${ENABLE_SS:-false}" = "true" ]; then
        printf '  %s\n' "$option) 重置 SS 端口"
        MENU_MAP[$option]="reset_ss"
        option=$((option + 1))
    fi
    
    if [ "${ENABLE_HY2:-false}" = "true" ]; then
        printf '  %s\n' "$option) 重置 HY2 端口"
        MENU_MAP[$option]="reset_hy2"
        option=$((option + 1))
    fi
    
    if [ "${ENABLE_TUIC:-false}" = "true" ]; then
        printf '  %s\n' "$option) 重置 TUIC 端口"
        MENU_MAP[$option]="reset_tuic"
        option=$((option + 1))
    fi
    
    if [ "${ENABLE_REALITY:-false}" = "true" ]; then
        printf '  %s\n' "$option) 重置 Vless Reality 端口"
        MENU_MAP[$option]="reset_reality"
        option=$((option + 1))
    fi
    
    if [ "${ENABLE_ANYTLS:-false}" = "true" ]; then
        printf '  %s\n' "$option) 重置 AnyTLS Reality 端口"
        MENU_MAP[$option]="reset_anytls"
        option=$((option + 1))
    fi

    # 固定功能选项
    MENU_MAP[$option]="start"
    printf '  %s\n' "$option) 启动服务"
    option=$((option + 1))
    
    MENU_MAP[$option]="stop"
    printf '  %s\n' "$option) 停止服务"
    option=$((option + 1))
    
    MENU_MAP[$option]="restart"
    printf '  %s\n' "$option) 重启服务"
    option=$((option + 1))
    
    MENU_MAP[$option]="status"
    printf '  %s\n' "$option) 查看状态"
    option=$((option + 1))
    
    MENU_MAP[$option]="update"
    printf '  %s\n' "$option) 更新 sing-box"
    option=$((option + 1))
    
    MENU_MAP[$option]="uninstall"
    printf '  %s\n' "$option) 卸载 sing-box"
    
    printf '\n  0) 退出\n\n'
}

# 主循环
while true; do
    show_menu
    printf '请选择操作 [0 退出]：'
    IFS= read -r opt || exit 0
    
    # 处理退出
    if [[ ! "$opt" =~ ^[0-9]{1,3}$ ]]; then warn "无效选项"; continue; fi
    if [ "$opt" = "0" ]; then
        exit 0
    fi
    
    # 处理固定选项
    case "$opt" in
        1) action_view_uri ;;
        2) action_view_config ;;
        3) action_edit_config ;;
        4) user_action || warn "用户操作未完成" ;;
        *)
            # 处理动态选项
            action="${MENU_MAP[$opt]:-}"
            case "$action" in
                reset_ss) action_reset_ss ;;
                reset_hy2) action_reset_hy2 ;;
                reset_tuic) action_reset_tuic ;;
                reset_reality) action_reset_reality ;;
                reset_anytls) action_reset_anytls ;;
                start) service_start && info "已启动" ;;
                stop) service_stop && info "已停止" ;;
                restart) service_restart && info "已重启" ;;
                status) service_status ;;
                update) action_update ;;
                uninstall) action_uninstall; exit 0 ;;
                *) warn "无效选项: $opt" ;;
            esac
            ;;
    esac
    
    echo ""
done
SB_SCRIPT
    then
        rm -f "$temporary"
        return 1
    fi
    if ! bash -n "$temporary" || ! chmod 755 "$temporary" || ! mv -f "$temporary" "$sb_path"; then
        rm -f "$temporary"
        return 1
    fi
    ln -sf "$sb_path" /usr/bin/sb || return 1
    ok "管理面板已安装：$sb_path"
}

if [[ "${1:-}" == --update-panel ]]; then
    check_root
    if [[ ! -f /etc/sing-box/config.json ]]; then err "未找到现有 sing-box 配置"; exit 1; fi
    install_sb
    exit 0
fi

printf '\n  Sing-box 安装向导\n  ────────────────────────────────────\n'
step 1 "检查运行环境"
detect_os
check_root
ok "${OS_ID:-unknown} · $(uname -m) · root"

# -----------------------
# 安装依赖
install_deps() {
    info "安装系统依赖..."
    
    case "$OS" in
        alpine)
            apk update || { err "apk update 失败"; return 1; }
            apk add --no-cache bash curl ca-certificates openssl openrc jq flock || {
                err "依赖安装失败"
                return 1
            }
            ;;
        debian)
            export DEBIAN_FRONTEND=noninteractive
            apt-get update -y || { err "apt update 失败"; return 1; }
            apt-get install -y curl ca-certificates openssl jq util-linux || {
                err "依赖安装失败"
                return 1
            }
            ;;
        redhat)
            yum install -y curl ca-certificates openssl jq util-linux || {
                err "依赖安装失败"
                return 1
            }
            ;;
        *)
            warn "未识别的系统类型,尝试继续..."
            ;;
    esac
    
    info "依赖安装完成"
}


# -----------------------
# 工具函数
# 生成随机端口
rand_port() {
    local port
    port=$(shuf -i 10000-60000 -n 1 2>/dev/null) || port=$((RANDOM % 50001 + 10000))
    echo "$port"
}

# 生成随机密码
rand_pass() {
    local pass
    pass=$(openssl rand -base64 16 2>/dev/null | tr -d '\n\r') || pass=$(head -c 16 /dev/urandom | base64 2>/dev/null | tr -d '\n\r')
    echo "$pass"
}

# 生成UUID
rand_uuid() {
    local uuid
    if [ -f /proc/sys/kernel/random/uuid ]; then
        uuid=$(cat /proc/sys/kernel/random/uuid)
    else
        uuid=$(openssl rand -hex 16 | sed 's/\(..\)\(..\)\(..\)\(..\)\(..\)\(..\)\(..\)\(..\)\(..\)\(..\)\(..\)\(..\)\(..\)\(..\)\(..\)\(..\)/\1\2\3\4-\5\6-\7\8-\9\10-\11\12\13\14\15\16/')
    fi
    echo "$uuid"
}

# -----------------------
# 配置节点名称后缀
step 2 "选择并确认安装配置"
echo "请输入节点名称（留空使用默认名称）"
read -r user_name
if [[ -n "$user_name" ]]; then
    suffix="-${user_name}"
else
    suffix=""
fi

# -----------------------
# 选择要部署的协议
select_protocols() {
    info "=== 选择要部署的协议 ==="
    echo "1) Shadowsocks (SS)"
    echo "2) Hysteria2 (HY2)"
    echo "3) TUIC"
    echo "4) VLESS Reality"
    echo "5) AnyTLS Reality"
    echo ""
    echo "请输入要部署的协议编号(多个用空格分隔,如: 1 2 4):"
    read -r protocol_input
    
    # 使用全局变量
    ENABLE_SS=false
    ENABLE_HY2=false
    ENABLE_TUIC=false
    ENABLE_REALITY=false
    ENABLE_ANYTLS=false
    
    for num in $protocol_input; do
        case "$num" in
            1) ENABLE_SS=true ;;
            2) ENABLE_HY2=true ;;
            3) ENABLE_TUIC=true ;;
            4) ENABLE_REALITY=true ;;
            5) ENABLE_ANYTLS=true ;;
            *) warn "无效选项: $num" ;;
        esac
    done
    
    if ! $ENABLE_SS && ! $ENABLE_HY2 && ! $ENABLE_TUIC && ! $ENABLE_REALITY && ! $ENABLE_ANYTLS; then
        err "未选择任何协议,退出安装"
        exit 1
    fi
    
    
    info "已选择协议:"
    $ENABLE_SS && echo "  - Shadowsocks"
    $ENABLE_HY2 && echo "  - Hysteria2"
    $ENABLE_TUIC && echo "  - TUIC"
    $ENABLE_REALITY && echo "  - VLESS Reality"
    $ENABLE_ANYTLS && echo "  - AnyTLS Reality"
    
    # 导出为全局变量（确保后续脚本可以访问）
    export ENABLE_SS
    export ENABLE_HY2
    export ENABLE_TUIC
    export ENABLE_REALITY
    export ENABLE_ANYTLS
}

select_protocols

# -----------------------
# 选择SS加密方式（新增）
select_ss_method() {
    if ! $ENABLE_SS; then
        SS_METHOD="2022-blake3-aes-128-gcm"
        return 0
    fi
    
    info "=== 选择 Shadowsocks 加密方式 ==="
    echo "1) 2022-blake3-aes-128-gcm (推荐)"
    echo "2) aes-128-gcm"
    echo ""
    echo "请输入选择(默认为 1):"
    read -r ss_method_choice
    
    case "${ss_method_choice:-1}" in
        1) SS_METHOD="2022-blake3-aes-128-gcm" ;;
        2) SS_METHOD="aes-128-gcm" ;;
        *) 
            warn "无效选择，使用默认方式: 2022-blake3-aes-128-gcm"
            SS_METHOD="2022-blake3-aes-128-gcm"
            ;;
    esac
    
    info "已选择加密方式: $SS_METHOD"
    export SS_METHOD
}

select_ss_method

# -----------------------
# 在获取公网 IP 之前，询问连接ip和sni配置
echo ""
echo "请输入节点连接 IP 或 DDNS域名(留空默认出口IP):"
read -r CUSTOM_IP
CUSTOM_IP="$(echo "$CUSTOM_IP" | tr -d '[:space:]')"

# 如果用户选择了 Reality 协议，询问 server_name(SNI)
REALITY_SNI=""
if $ENABLE_REALITY || $ENABLE_ANYTLS; then
    echo ""
    echo "请输入 Reality 的 SNI(留空默认 addons.mozilla.org):"
    read -r REALITY_SNI
    REALITY_SNI="$(echo "${REALITY_SNI:-addons.mozilla.org}" | tr -d '[:space:]')"
else
    # 也设默认，方便后续统一处理（若未选 reality，也写入缓存以便 sb 读取）
    REALITY_SNI="addons.mozilla.org"
fi


# -----------------------
# 生成随机端口
rand_port() {
    shuf -i 10000-60000 -n 1 2>/dev/null || echo $((RANDOM % 50001 + 10000))
}

# 生成随机密码
rand_pass() {
    openssl rand -base64 16 | tr -d '\n\r' || head -c 16 /dev/urandom | base64 | tr -d '\n\r'
}

# 生成UUID
rand_uuid() {
    cat /proc/sys/kernel/random/uuid
}

# -----------------------
# 配置端口和密码
get_config() {
    
    if $ENABLE_SS; then
        printf '\n  %s\n' "Shadowsocks (SS)"
        if [ -n "${SINGBOX_PORT_SS:-}" ]; then
            PORT_SS="$SINGBOX_PORT_SS"
        else
            read -p "请输入 SS 端口(留空则随机 10000-60000): " USER_PORT_SS
            PORT_SS="${USER_PORT_SS:-$(rand_port)}"
        fi
    fi

    if $ENABLE_HY2; then
        printf '\n  %s\n' "Hysteria2 (HY2)"
        if [ -n "${SINGBOX_PORT_HY2:-}" ]; then
            PORT_HY2="$SINGBOX_PORT_HY2"
        else
            read -p "请输入 HY2 端口(留空则随机 10000-60000): " USER_PORT_HY2
            PORT_HY2="${USER_PORT_HY2:-$(rand_port)}"
        fi
    fi

    if $ENABLE_TUIC; then
        printf '\n  %s\n' "TUIC"
        if [ -n "${SINGBOX_PORT_TUIC:-}" ]; then
            PORT_TUIC="$SINGBOX_PORT_TUIC"
        else
            read -p "请输入 TUIC 端口(留空则随机 10000-60000): " USER_PORT_TUIC
            PORT_TUIC="${USER_PORT_TUIC:-$(rand_port)}"
        fi
    fi

    if $ENABLE_REALITY; then
        printf '\n  %s\n' "VLESS Reality"
        if [ -n "${SINGBOX_PORT_REALITY:-}" ]; then
            PORT_REALITY="$SINGBOX_PORT_REALITY"
        else
            read -p "请输入 VLESS Reality 端口(留空则随机 10000-60000): " USER_PORT_REALITY
            PORT_REALITY="${USER_PORT_REALITY:-$(rand_port)}"
        fi
    fi
    
    if $ENABLE_ANYTLS; then
        printf '\n  %s\n' "AnyTLS Reality"
        if [ -n "${SINGBOX_PORT_ANYTLS:-}" ]; then
            PORT_ANYTLS="$SINGBOX_PORT_ANYTLS"
        else
            read -p "请输入 AnyTLS Reality 端口(留空则随机 10000-60000): " USER_PORT_ANYTLS
            PORT_ANYTLS="${USER_PORT_ANYTLS:-$(rand_port)}"
        fi
    fi
}

get_config

printf '\n  安装配置\n'
field '连接地址' "${CUSTOM_IP:-安装后自动检测公网 IPv4}"
field '节点名称' "${user_name:-默认名称}"
show_protocol_ports
if $ENABLE_SS; then field 'SS 加密' "$SS_METHOD"; fi
if $ENABLE_REALITY || $ENABLE_ANYTLS; then field 'Reality SNI' "$REALITY_SNI"; fi
if [[ -f /etc/sing-box/config.json ]]; then
    warn "现有配置将由通过校验的新配置替换，随后会重启服务。"
fi
printf '\n继续安装？[y/N] '
if ! IFS= read -r confirm || [[ ! "$confirm" =~ ^([Yy]|[Yy][Ee][Ss])$ ]]; then
    info "已取消安装"
    exit 0
fi

# -----------------------
# 安装 sing-box
install_singbox() {

    if command -v sing-box >/dev/null 2>&1; then
        CURRENT_VERSION=$(sing-box version 2>/dev/null | head -1 || echo "unknown")
        warn "检测到已安装 sing-box: $CURRENT_VERSION"
        printf '是否重新安装？[y/N] '
        IFS= read -r REINSTALL || return 1
        if [[ ! "$REINSTALL" =~ ^[Yy]$ ]]; then
            info "跳过 sing-box 安装"
            return 0
        fi
    fi

    case "$OS" in
        alpine)
            info "使用 Edge 仓库安装 sing-box"
            apk update >> "$install_log" 2>&1 || { err "apk update 失败"; return 1; }
            apk add --repository=http://dl-cdn.alpinelinux.org/alpine/edge/community sing-box >> "$install_log" 2>&1 || {
                err "sing-box 安装失败"
                return 1
            }
            ;;
        debian|redhat)
            local installer
            installer=$(mktemp) || return 1
            if ! { curl -fsSL https://sing-box.app/install.sh -o "$installer" && bash "$installer"; } >> "$install_log" 2>&1; then
                rm -f "$installer"
                err "sing-box 安装失败"
                return 1
            fi
            rm -f "$installer"
            ;;
        *)
            err "未支持的系统,无法安装 sing-box"
            return 1
            ;;
    esac

    if ! command -v sing-box >/dev/null 2>&1; then
        err "sing-box 安装后未找到可执行文件"
        return 1
    fi

    INSTALLED_VERSION=$(sing-box version 2>/dev/null | head -1 || echo "unknown")
    ok "sing-box 已安装：$INSTALLED_VERSION"
}

step 3 "安装系统依赖和 sing-box"
install_log=$(mktemp /var/log/sing-box-install.XXXXXXXX.log)
info "安装系统依赖，详细输出写入 $install_log"
if ! install_deps >> "$install_log" 2>&1; then
    err "依赖安装失败。日志：$install_log"
    tail -n 15 "$install_log" >&2
    exit 1
fi
ok "系统依赖就绪"
if ! install_singbox; then
    err "sing-box 安装失败。日志：$install_log"
    tail -n 15 "$install_log" >&2
    exit 1
fi

step 4 "生成并校验配置"
if $ENABLE_SS; then PSK_SS=$(rand_pass); fi
if $ENABLE_HY2; then PSK_HY2=$(rand_pass); fi
if $ENABLE_TUIC; then
    PSK_TUIC=$(rand_pass)
    UUID_TUIC=$(rand_uuid)
fi
if $ENABLE_REALITY; then UUID=$(rand_uuid); fi
if $ENABLE_ANYTLS; then
    ANYTLS_USER=admin
    ANYTLS_PSK=$(openssl rand -base64 16)
fi

# -----------------------
# 生成 Reality 密钥对（必须在 sing-box 安装之后）
generate_reality_keys() {
    if ! $ENABLE_REALITY && ! $ENABLE_ANYTLS; then
        info "跳过 Reality 密钥生成（未选择 Reality 协议）"
        return 0
    fi
    
    info "生成 Reality 密钥对..."
    
    if ! command -v sing-box >/dev/null 2>&1; then
        err "sing-box 未安装，无法生成 Reality 密钥"
        exit 1
    fi
    
    REALITY_KEYS=$(sing-box generate reality-keypair 2>&1) || {
        err "生成 Reality 密钥失败"
        exit 1
    }
    
    REALITY_PK=$(echo "$REALITY_KEYS" | grep "PrivateKey" | awk '{print $NF}' | tr -d '\r')
    REALITY_PUB=$(echo "$REALITY_KEYS" | grep "PublicKey" | awk '{print $NF}' | tr -d '\r')
    REALITY_SID=$(sing-box generate rand 8 --hex 2>&1) || {
        err "生成 Reality ShortID 失败"
        exit 1
    }
    
    if [ -z "$REALITY_PK" ] || [ -z "$REALITY_PUB" ] || [ -z "$REALITY_SID" ]; then
        err "Reality 密钥生成结果为空"
        exit 1
    fi
    
    mkdir -p /etc/sing-box
    echo -n "$REALITY_PUB" > /etc/sing-box/.reality_pub
    echo -n "$REALITY_SID" > /etc/sing-box/.reality_sid
    
    info "Reality 密钥已生成"
}

generate_reality_keys

# -----------------------
# 生成 HY2/TUIC 自签证书(仅在需要时)
generate_cert() {
    if ! $ENABLE_HY2 && ! $ENABLE_TUIC; then
        info "跳过证书生成(未选择 HY2 或 TUIC)"
        return 0
    fi
    
    info "生成 HY2/TUIC 自签证书..."
    mkdir -p /etc/sing-box/certs
    
    if [ ! -f /etc/sing-box/certs/fullchain.pem ] || [ ! -f /etc/sing-box/certs/privkey.pem ]; then
        openssl req -x509 -newkey rsa:2048 -nodes \
          -keyout /etc/sing-box/certs/privkey.pem \
          -out /etc/sing-box/certs/fullchain.pem \
          -days 3650 \
          -subj "/CN=www.bing.com" || {
            err "证书生成失败"
            exit 1
        }
        info "证书已生成"
    else
        info "证书已存在"
    fi
}

generate_cert

# -----------------------
# 生成配置文件
CONFIG_PATH="/etc/sing-box/config.json"

create_config() {
    info "生成配置文件: $CONFIG_PATH"

    mkdir -p "$(dirname "$CONFIG_PATH")"

    # 构建 inbounds 内容（使用临时文件避免字符串处理问题）
    local TEMP_INBOUNDS="/tmp/singbox_inbounds_$.json"
    > "$TEMP_INBOUNDS"
    
    local need_comma=false
    
    if $ENABLE_SS; then
        cat >> "$TEMP_INBOUNDS" <<'INBOUND_SS'
    {
      "type": "shadowsocks",
      "listen": "::",
      "listen_port": PORT_SS_PLACEHOLDER,
      "method": "METHOD_SS_PLACEHOLDER",
      "password": "PSK_SS_PLACEHOLDER",
      "tag": "ss-in"
    }
INBOUND_SS
        sed -i "s|PORT_SS_PLACEHOLDER|$PORT_SS|g" "$TEMP_INBOUNDS"
        sed -i "s|METHOD_SS_PLACEHOLDER|$SS_METHOD|g" "$TEMP_INBOUNDS"
        sed -i "s|PSK_SS_PLACEHOLDER|$PSK_SS|g" "$TEMP_INBOUNDS"
        need_comma=true
    fi
    
    if $ENABLE_HY2; then
        $need_comma && echo "," >> "$TEMP_INBOUNDS"
        cat >> "$TEMP_INBOUNDS" <<'INBOUND_HY2'
    {
      "type": "hysteria2",
      "tag": "hy2-in",
      "listen": "::",
      "listen_port": PORT_HY2_PLACEHOLDER,
      "users": [
        {
          "name": "admin",
          "password": "PSK_HY2_PLACEHOLDER"
        }
      ],
      "tls": {
        "enabled": true,
        "alpn": ["h3"],
        "certificate_path": "/etc/sing-box/certs/fullchain.pem",
        "key_path": "/etc/sing-box/certs/privkey.pem"
      }
    }
INBOUND_HY2
        sed -i "s|PORT_HY2_PLACEHOLDER|$PORT_HY2|g" "$TEMP_INBOUNDS"
        sed -i "s|PSK_HY2_PLACEHOLDER|$PSK_HY2|g" "$TEMP_INBOUNDS"
        need_comma=true
    fi
    
    if $ENABLE_TUIC; then
        $need_comma && echo "," >> "$TEMP_INBOUNDS"
        cat >> "$TEMP_INBOUNDS" <<'INBOUND_TUIC'
    {
      "type": "tuic",
      "tag": "tuic-in",
      "listen": "::",
      "listen_port": PORT_TUIC_PLACEHOLDER,
      "users": [
        {
          "name": "admin",
          "uuid": "UUID_TUIC_PLACEHOLDER",
          "password": "PSK_TUIC_PLACEHOLDER"
        }
      ],
      "congestion_control": "bbr",
      "tls": {
        "enabled": true,
        "alpn": ["h3"],
        "certificate_path": "/etc/sing-box/certs/fullchain.pem",
        "key_path": "/etc/sing-box/certs/privkey.pem"
      }
    }
INBOUND_TUIC
        sed -i "s|PORT_TUIC_PLACEHOLDER|$PORT_TUIC|g" "$TEMP_INBOUNDS"
        sed -i "s|UUID_TUIC_PLACEHOLDER|$UUID_TUIC|g" "$TEMP_INBOUNDS"
        sed -i "s|PSK_TUIC_PLACEHOLDER|$PSK_TUIC|g" "$TEMP_INBOUNDS"
        need_comma=true
    fi
    
    if $ENABLE_REALITY; then
        $need_comma && echo "," >> "$TEMP_INBOUNDS"
        cat >> "$TEMP_INBOUNDS" <<'INBOUND_REALITY'
    {
      "type": "vless",
      "tag": "vless-in",
      "listen": "::",
      "listen_port": PORT_REALITY_PLACEHOLDER,
      "users": [
        {
          "name": "admin",
          "uuid": "UUID_REALITY_PLACEHOLDER",
          "flow": "xtls-rprx-vision"
        }
      ],
      "tls": {
        "enabled": true,
        "server_name": "REALITY_SNI_PLACEHOLDER",
        "reality": {
          "enabled": true,
          "handshake": {
            "server": "REALITY_SNI_PLACEHOLDER",
            "server_port": 443
          },
          "private_key": "REALITY_PK_PLACEHOLDER",
          "short_id": ["REALITY_SID_PLACEHOLDER"]
        }
      }
    }
INBOUND_REALITY
        sed -i "s|PORT_REALITY_PLACEHOLDER|$PORT_REALITY|g" "$TEMP_INBOUNDS"
        sed -i "s|UUID_REALITY_PLACEHOLDER|$UUID|g" "$TEMP_INBOUNDS"
        sed -i "s|REALITY_PK_PLACEHOLDER|$REALITY_PK|g" "$TEMP_INBOUNDS"
        sed -i "s|REALITY_SID_PLACEHOLDER|$REALITY_SID|g" "$TEMP_INBOUNDS"
        sed -i "s|REALITY_SNI_PLACEHOLDER|$REALITY_SNI|g" "$TEMP_INBOUNDS"
        need_comma=true
    fi

    if $ENABLE_ANYTLS; then
    $need_comma && echo "," >> "$TEMP_INBOUNDS"
    cat >> "$TEMP_INBOUNDS" <<'INBOUND_ANYTLS'
    {
      "type": "anytls",
      "tag": "anytls-in",
      "listen": "::",
      "listen_port": PORT_ANYTLS_PLACEHOLDER,
      "users": [
        {
          "name": "ANYTLS_USER_PLACEHOLDER",
          "password": "ANYTLS_PSK_PLACEHOLDER"
        }
      ],
      "padding_scheme": [],
      "tls": {
        "enabled": true,
        "server_name": "REALITY_SNI_PLACEHOLDER",
        "reality": {
          "enabled": true,
          "handshake": {
            "server": "REALITY_SNI_PLACEHOLDER",
            "server_port": 443
          },
          "private_key": "REALITY_PK_PLACEHOLDER",
          "short_id": [
            "REALITY_SID_PLACEHOLDER"
          ]
        }
      }
    }
INBOUND_ANYTLS

    sed -i "s|PORT_ANYTLS_PLACEHOLDER|$PORT_ANYTLS|g" "$TEMP_INBOUNDS"
    sed -i "s|ANYTLS_USER_PLACEHOLDER|$ANYTLS_USER|g" "$TEMP_INBOUNDS"
    sed -i "s|ANYTLS_PSK_PLACEHOLDER|$ANYTLS_PSK|g" "$TEMP_INBOUNDS"
    sed -i "s|REALITY_PK_PLACEHOLDER|$REALITY_PK|g" "$TEMP_INBOUNDS"
    sed -i "s|REALITY_SID_PLACEHOLDER|$REALITY_SID|g" "$TEMP_INBOUNDS"
    sed -i "s|REALITY_SNI_PLACEHOLDER|$REALITY_SNI|g" "$TEMP_INBOUNDS"

    need_comma=true
    fi

    # 生成最终配置
    local pending_config
    pending_config=$(mktemp "$(dirname "$CONFIG_PATH")/.config.XXXXXXXX.json")
    cat > "$pending_config" <<'CONFIG_HEAD'
{
  "log": {
    "level": "info",
    "timestamp": true
  },
  "ntp": {
    "enabled": true,
    "server": "time.apple.com",
    "server_port": 123,
    "interval": "30m"
  },
  "inbounds": [
CONFIG_HEAD
    
    cat "$TEMP_INBOUNDS" >> "$pending_config"
    
    cat >> "$pending_config" <<'CONFIG_TAIL'
  ],
  "outbounds": [
    {
      "type": "direct",
      "tag": "direct-out"
    }
  ]
}
CONFIG_TAIL

    rm -f "$TEMP_INBOUNDS"

    if ! sing-box check -c "$pending_config" >> "$install_log" 2>&1; then
        rm -f "$pending_config"
        err "新配置校验失败。日志：$install_log"
        tail -n 15 "$install_log" >&2
        exit 1
    fi
    mv -f "$pending_config" "$CONFIG_PATH"
    ok "配置校验通过：$CONFIG_PATH"

    # 保存协议选择到文件（确保持久化）
    cat > /etc/sing-box/.protocols <<EOF
ENABLE_SS=$ENABLE_SS
ENABLE_HY2=$ENABLE_HY2
ENABLE_TUIC=$ENABLE_TUIC
ENABLE_REALITY=$ENABLE_REALITY
ENABLE_ANYTLS=$ENABLE_ANYTLS
EOF
    if [[ -n "$suffix" ]]; then
        printf '%s\n' "$suffix" > /root/node_names.txt
    fi

    # 保存配置缓存（追加/覆盖）
    cat > /etc/sing-box/.config_cache <<CACHEEOF
ENABLE_SS=$ENABLE_SS
ENABLE_HY2=$ENABLE_HY2
ENABLE_TUIC=$ENABLE_TUIC
ENABLE_REALITY=$ENABLE_REALITY
ENABLE_ANYTLS=$ENABLE_ANYTLS
CACHEEOF

    $ENABLE_SS && cat >> /etc/sing-box/.config_cache <<CACHEEOF
SS_PORT=$PORT_SS
SS_PSK=$PSK_SS
SS_METHOD=$SS_METHOD
CACHEEOF

    $ENABLE_HY2 && cat >> /etc/sing-box/.config_cache <<CACHEEOF
HY2_PORT=$PORT_HY2
HY2_PSK=$PSK_HY2
CACHEEOF

    $ENABLE_TUIC && cat >> /etc/sing-box/.config_cache <<CACHEEOF
TUIC_PORT=$PORT_TUIC
TUIC_UUID=$UUID_TUIC
TUIC_PSK=$PSK_TUIC
CACHEEOF

    $ENABLE_REALITY && cat >> /etc/sing-box/.config_cache <<CACHEEOF
REALITY_PORT=$PORT_REALITY
REALITY_UUID=$UUID
REALITY_PK=$REALITY_PK
REALITY_SID=$REALITY_SID
REALITY_PUB=$REALITY_PUB
REALITY_SNI=$REALITY_SNI
CACHEEOF

    $ENABLE_ANYTLS && cat >> /etc/sing-box/.config_cache <<CACHEEOF
ANYTLS_PORT=$PORT_ANYTLS
ANYTLS_USER=$ANYTLS_USER
ANYTLS_PSK=$ANYTLS_PSK
CACHEEOF

    # 全局写入 CUSTOM_IP（哪怕为空也写）
    echo "CUSTOM_IP=$CUSTOM_IP" >> /etc/sing-box/.config_cache

    info "配置缓存已保存到 /etc/sing-box/.config_cache"
}

# 调用配置生成
create_config

step 5 "配置并启动服务"

# -----------------------
# 设置服务
setup_service() {
    info "配置系统服务..."
    
    if [ "$OS" = "alpine" ]; then
        SERVICE_PATH="/etc/init.d/sing-box"
        
        cat > "$SERVICE_PATH" <<'OPENRC'
#!/sbin/openrc-run

name="sing-box"
description="Sing-box Proxy Server"
command="/usr/bin/sing-box"
command_args="run -c /etc/sing-box/config.json"
pidfile="/run/${RC_SVCNAME}.pid"
command_background="yes"
output_log="/var/log/sing-box.log"
error_log="/var/log/sing-box.err"
# 自动拉起（程序崩溃、OOM、被 kill 后自动恢复）
supervisor=supervise-daemon
supervise_daemon_args="--respawn-max 0 --respawn-delay 5"

depend() {
    need net
    after firewall
}

start_pre() {
    checkpath --directory --mode 0755 /var/log
    checkpath --directory --mode 0755 /run
}
OPENRC
        
        chmod +x "$SERVICE_PATH"
        rc-update add sing-box default >/dev/null 2>&1 || warn "添加开机自启失败"
        rc-service sing-box restart || {
            err "服务启动失败"
            tail -20 /var/log/sing-box.err 2>/dev/null || tail -20 /var/log/sing-box.log 2>/dev/null || true
            exit 1
        }
        
        sleep 2
        if rc-service sing-box status >/dev/null 2>&1; then
            ok "OpenRC 服务正在运行"
        else
            err "服务状态异常"
            exit 1
        fi
        
    else
        SERVICE_PATH="/etc/systemd/system/sing-box.service"
        
        cat > "$SERVICE_PATH" <<'SYSTEMD'
[Unit]
Description=Sing-box Proxy Server
Documentation=https://sing-box.sagernet.org
After=network.target nss-lookup.target
Wants=network.target

[Service]
Type=simple
User=root
WorkingDirectory=/etc/sing-box
ExecStart=/usr/bin/sing-box run -c /etc/sing-box/config.json
ExecReload=/bin/kill -HUP $MAINPID
Restart=on-failure
RestartSec=10s
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
SYSTEMD
        
        systemctl daemon-reload
        systemctl enable sing-box >/dev/null 2>&1
        systemctl restart sing-box || {
            err "服务启动失败"
            journalctl -u sing-box -n 30 --no-pager
            exit 1
        }
        
        sleep 2
        if systemctl is-active sing-box >/dev/null 2>&1; then
            ok "Systemd 服务正在运行"
        else
            err "服务状态异常"
            exit 1
        fi
    fi
    
    info "服务配置完成: $SERVICE_PATH"
}

setup_service

# -----------------------
# 获取公网 IP
get_public_ip() {
    local ip=""
    for url in \
        "https://api.ipify.org" \
        "https://ipinfo.io/ip" \
        "https://ifconfig.me" \
        "https://icanhazip.com" \
        "https://ipecho.net/plain"; do
        ip=$(curl -s --max-time 5 "$url" 2>/dev/null | tr -d '[:space:]' || true)
        if [ -n "$ip" ] && [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
            echo "$ip"
            return 0
        fi
    done
    return 1
}

# 如果用户提供了 CUSTOM_IP，则优先使用；否则自动检测出口 IP
if [ -n "${CUSTOM_IP:-}" ]; then
    PUB_IP="$CUSTOM_IP"
    info "使用用户提供的连接IP或ddns域名 : $PUB_IP"
else
    PUB_IP=$(get_public_ip || echo "YOUR_SERVER_IP")
    if [ "$PUB_IP" = "YOUR_SERVER_IP" ]; then
        warn "无法获取公网 IP,请手动替换"
    else
        info "检测到公网 IP: $PUB_IP"
    fi
fi

# -----------------------
# 生成链接(仅生成已选择的协议)
generate_uris() {
    local host="$PUB_IP"
    
    if $ENABLE_SS; then
        local ss_userinfo="${SS_METHOD}:${PSK_SS}"
        ss_encoded=$(printf "%s" "$ss_userinfo" | sed 's/:/%3A/g; s/+/%2B/g; s/\//%2F/g; s/=/%3D/g')
        ss_b64=$(printf "%s" "$ss_userinfo" | base64 -w0 2>/dev/null || printf "%s" "$ss_userinfo" | base64 | tr -d '\n')

        printf '  %s\n' "Shadowsocks (SS)"
        echo "ss://${ss_encoded}@${host}:${PORT_SS}#ss${suffix}"
        echo "ss://${ss_b64}@${host}:${PORT_SS}#ss${suffix}"
        echo ""
    fi
    
    if $ENABLE_HY2; then
        hy2_encoded=$(printf "%s" "$PSK_HY2" | sed 's/:/%3A/g; s/+/%2B/g; s/\//%2F/g; s/=/%3D/g')
        printf '  %s\n' "Hysteria2 (HY2)"
        echo "hy2://${hy2_encoded}@${host}:${PORT_HY2}/?sni=www.bing.com&alpn=h3&insecure=1#hy2${suffix}"
        echo ""
    fi

    if $ENABLE_TUIC; then
        tuic_encoded=$(printf "%s" "$PSK_TUIC" | sed 's/:/%3A/g; s/+/%2B/g; s/\//%2F/g; s/=/%3D/g')
        printf '  %s\n' "TUIC"
        echo "tuic://${UUID_TUIC}:${tuic_encoded}@${host}:${PORT_TUIC}/?congestion_control=bbr&alpn=h3&sni=www.bing.com&insecure=1#tuic${suffix}"
        echo ""
    fi
    
    if $ENABLE_REALITY; then
        printf '  %s\n' "VLESS Reality"
        echo "vless://${UUID}@${host}:${PORT_REALITY}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${REALITY_SNI}&fp=chrome&pbk=${REALITY_PUB}&sid=${REALITY_SID}#reality${suffix}"
        echo ""
    fi

    if $ENABLE_ANYTLS; then
        anytls_user_encoded=$(printf "%s" "$ANYTLS_USER" | sed 's/:/%3A/g; s/+/%2B/g; s/\//%2F/g; s/=/%3D/g')
        anytls_pass_encoded=$(printf "%s" "$ANYTLS_PSK" | sed 's/:/%3A/g; s/+/%2B/g; s/\//%2F/g; s/=/%3D/g')
        printf '  %s\n' "AnyTLS Reality"
        echo "anytls://${anytls_pass_encoded}@${host}:${PORT_ANYTLS}/?security=reality&sni=${REALITY_SNI}&fp=chrome&pbk=${REALITY_PUB}&sid=${REALITY_SID}#anytls${suffix}"
        echo ""
    fi
}

# -----------------------
# -----------------------
install_sb

printf '\n  ────────────────────────────────────\n'
ok "Sing-box 部署完成"
field '连接地址' "$PUB_IP"
show_protocol_ports
if $ENABLE_REALITY || $ENABLE_ANYTLS; then field 'Reality SNI' "$REALITY_SNI"; fi
field '配置文件' "$CONFIG_PATH"
field '服务文件' "$SERVICE_PATH"
field '安装日志' "$install_log"
field '管理命令' 'sb'

printf '\n  客户端链接\n\n'
generate_uris
