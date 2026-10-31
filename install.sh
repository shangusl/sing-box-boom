#!/usr/bin/env bash
# =========================================================================
#  Project:   sing-box-boom (233boy 全量协议迁移 & 智能防封增强版)
#  Protocols: VLESS-Reality / Hysteria 2 / TUIC v5 / Shadowsocks 2022
#  Features:  多节点共存 / 全球高校独立源站引擎 / BBR加速 / 完整CLI菜单
# =========================================================================

set -e

# --- 终端颜色 ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
MAGENTA='\033[0;35m'
CYAN='\033[0;36m'
PLAIN='\033[0m'

# --- 核心路径与常量 ---
APP_NAME="sing-box"
BIN_PATH="/usr/local/bin/${APP_NAME}"
CONF_DIR="/etc/${APP_NAME}"
CONF_FILE="${CONF_DIR}/config.json"
NODES_FILE="${CONF_DIR}/nodes.json"
CERT_FILE="${CONF_DIR}/cert.crt"
KEY_FILE="${CONF_DIR}/cert.key"
SERVICE_FILE="/etc/systemd/system/${APP_NAME}.service"
SCRIPT_INSTALL_PATH="/usr/local/bin/sb"

# -------------------------------------------------------------
# 0. 基础环境检测与依赖安装
# -------------------------------------------------------------
check_root() {
    if [[ $EUID -ne 0 ]]; then
        echo -e "${RED}[错误]${PLAIN} 必须以 root 权限执行此脚本！"
        exit 1
    fi
}

check_arch() {
    local machine
    machine=$(uname -m)
    case "$machine" in
        x86_64|amd64) ARCH="amd64" ;;
        aarch64|arm64) ARCH="arm64" ;;
        *)
            echo -e "${RED}[错误]${PLAIN} 暂不支持该系统架构: ${machine}"
            exit 1
            ;;
    esac
}

install_dependencies() {
    echo -e "${CYAN}[+] 正在检查并安装基础依赖环境...${PLAIN}"
    local deps=("curl" "wget" "tar" "jq" "openssl" "qrencode")
    local need_install=()

    for dep in "${deps[@]}"; do
        if ! command -v "$dep" &>/dev/null; then
            need_install+=("$dep")
        fi
    done

    if [[ ${#need_install[@]} -gt 0 ]]; then
        if command -v apt-get &>/dev/null; then
            apt-get update -y && apt-get install -y "${need_install[@]}"
        elif command -v dnf &>/dev/null; then
            dnf install -y "${need_install[@]}"
        elif command -v yum &>/dev/null; then
            yum install -y "${need_install[@]}"
        elif command -v apk &>/dev/null; then
            apk update && apk add "${need_install[@]}"
        fi
    fi
    echo -e "${GREEN}[✓] 依赖安装完成！${PLAIN}"
}

# -------------------------------------------------------------
# 1. 核心下载与初始环境初始化
# -------------------------------------------------------------
download_singbox_core() {
    check_arch
    mkdir -p "${CONF_DIR}"

    if [[ -f "$BIN_PATH" ]]; then
        return
    fi

    echo -e "${CYAN}[+] 正在检索 sing-box 最新版本...${PLAIN}"
    local latest_tag
    latest_tag=$(curl -s4m 5 "https://api.github.com/repos/SagerNet/sing-box/releases/latest" | jq -r '.tag_name // empty' 2>/dev/null || true)
    
    if [[ -z "$latest_tag" || "$latest_tag" == "null" ]]; then
        latest_tag="v1.11.3"
    fi
    local version="${latest_tag#v}"
    echo -e "${GREEN}[✓] 选定版本: ${latest_tag} (${ARCH})${PLAIN}"

    local download_url="https://github.com/SagerNet/sing-box/releases/download/${latest_tag}/sing-box-${version}-linux-${ARCH}.tar.gz"
    local proxy_url="https://ghfast.top/${download_url}"
    local tmp_tar="/tmp/sing-box.tar.gz"
    
    echo -e "${CYAN}[+] 正在下载核心二进制...${PLAIN}"
    wget -qO "$tmp_tar" "$download_url" || curl -fsSL "$download_url" -o "$tmp_tar" || \
    wget -qO "$tmp_tar" "$proxy_url" || curl -fsSL "$proxy_url" -o "$tmp_tar"
    
    tar -zxvf "$tmp_tar" -C /tmp/ >/dev/null
    cp -f "/tmp/sing-box-${version}-linux-${ARCH}/sing-box" "$BIN_PATH"
    chmod +x "$BIN_PATH"
    rm -rf "/tmp/sing-box"*
    echo -e "${GREEN}[✓] sing-box 核心安装成功 -> ${BIN_PATH}${PLAIN}"

    # 初始化空白骨架配置
    if [[ ! -f "$CONF_FILE" ]]; then
        cat > "$CONF_FILE" <<EOF
{
  "log": {
    "level": "warn",
    "timestamp": true
  },
  "inbounds": [],
  "outbounds": [
    {
      "type": "direct",
      "tag": "direct"
    }
  ]
}
EOF
    fi

    # 初始化节点元数据文件
    if [[ ! -f "$NODES_FILE" ]]; then
        echo "[]" > "$NODES_FILE"
    fi

    # 注册 systemd 守护进程
    cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=sing-box Full Suite Service
Documentation=https://sing-box.sagernet.org
After=network.target nss-lookup.target

[Service]
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
NoNewPrivileges=true
ExecStart=${BIN_PATH} run -c ${CONF_FILE}
Restart=on-failure
RestartPreventExitStatus=23
LimitNPROC=10000
LimitNOFILE=1000000

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable "${APP_NAME}" >/dev/null 2>&1
}

ensure_tls_cert() {
    if [[ ! -f "$CERT_FILE" || ! -f "$KEY_FILE" ]]; then
        echo -e "${CYAN}[+] 正在生成标准 ECDSA 高性能自签证书...${PLAIN}"
        openssl req -x509 -nodes -newkey ec:<(openssl ecparam -name prime256v1) \
            -keyout "$KEY_FILE" -out "$CERT_FILE" \
            -days 3650 -subj "/CN=bing.com" >/dev/null 2>&1
        echo -e "${GREEN}[✓] 证书生成完毕！${PLAIN}"
    fi
}

get_public_ip() {
    if [[ -z "$VPS_IP" ]]; then
        VPS_IP=$(curl -s4m 4 https://api.ipify.org || curl -s4m 4 https://ifconfig.me || curl -s4m 4 http://ip-api.com/line/?fields=query || echo "127.0.0.1")
    fi
}

# -------------------------------------------------------------
# 2. 高校与大厂防白嫖 SNI 优选引擎 (针对 VLESS-Reality)
# -------------------------------------------------------------
is_safe_independent_origin() {
    local target="$1"
    local headers
    headers=$(curl -sI -m 3 "https://${target}" 2>/dev/null | tr '[:upper:]' '[:lower:]')
    if echo "$headers" | grep -qE "server: cloudflare|cf-ray:|x-amz-cf-id:|via:.*cloudfront|x-fastly-request-id:|server: akamaighost"; then
        return 1
    fi

    local ip
    ip=$(getent ahosts "$target" 2>/dev/null | awk '{print $1}' | head -n 1)
    [[ -z "$ip" ]] && return 1

    local asn_info
    asn_info=$(curl -s4m 3 "http://ip-api.com/json/${ip}?fields=as,isp" 2>/dev/null)
    if echo "$asn_info" | grep -qiE "cloudflare|amazon|fastly|akamai"; then
        return 1
    fi
    return 0
}

check_candidate_quality() {
    local target="$1"
    local result
    result=$(curl -s -o /dev/null \
        --tlsv1.3 --http2 \
        -w "%{http_code}|%{time_appconnect}" \
        --connect-timeout 2 -m 3 \
        "https://${target}" 2>/dev/null)

    local http_code
    http_code=$(echo "$result" | cut -d'|' -f1)
    local appconnect_time
    appconnect_time=$(echo "$result" | cut -d'|' -f2)

    if [[ $? -eq 0 && "$http_code" == "200" && -n "$appconnect_time" && "$appconnect_time" != "0.000000" ]]; then
        awk -v t="$appconnect_time" 'BEGIN { printf "%.0f", t * 1000 }'
        return 0
    fi
    return 1
}

auto_select_best_sni() {
    echo -e "${CYAN}[1/3] 正在获取 VPS 归属地理信息...${PLAIN}"
    local ip_info
    ip_info=$(curl -s4m 5 "http://ip-api.com/json/?fields=status,country,city,query")
    local country
    country=$(echo "$ip_info" | jq -r '.country // "United States"')
    local city
    city=$(echo "$ip_info" | jq -r '.city // "Unknown"')
    get_public_ip

    echo -e "${GREEN}[✓] VPS 所在地: ${country} (${city}) | 公网 IP: ${VPS_IP}${PLAIN}"

    echo -e "${CYAN}[2/3] 检索全球高校数据库镜像 (本地高速运算)...${PLAIN}"
    local json_cache="/tmp/world_universities.json"
    if [[ ! -s "$json_cache" ]]; then
        local raw_url="https://raw.githubusercontent.com/Hipo/university-domains-list/master/world_universities_and_domains.json"
        local cdn_url="https://cdn.jsdelivr.net/gh/Hipo/university-domains-list@master/world_universities_and_domains.json"
        curl -s4m 10 "$raw_url" -o "$json_cache" || curl -s4m 10 "$cdn_url" -o "$json_cache"
    fi

    local candidate_domains=()
    if [[ -s "$json_cache" ]]; then
        while IFS= read -r line; do
            [[ -n "$line" ]] && candidate_domains+=("$line")
        done < <(jq -r --arg c "$country" '.[] | select(.country == $c) | .domains[]?' "$json_cache" | sort -u)
    fi

    local total=${#candidate_domains[@]}
    echo -e "${GREEN}[✓] 在当地匹配到 ${total} 个大学独立域名${PLAIN}"

    echo -e "${CYAN}[3/3] 正在进行 [防白嫖清洗 + HTTP/2 200 + 本地物理延迟] 综合体检...${PLAIN}"
    local sample_pool=()
    if [[ $total -gt 0 ]]; then
        while IFS= read -r line; do
            sample_pool+=("$line")
        done < <(printf "%s\n" "${candidate_domains[@]}" | shuf -n 12)
    fi

    local best_sni=""
    local min_latency=99999

    for base in "${sample_pool[@]}"; do
        local targets=("www.${base}" "${base}")
        local valid_target=""
        local target_latency=""

        for target in "${targets[@]}"; do
            if ! getent ahosts "$target" &>/dev/null; then continue; fi
            if ! is_safe_independent_origin "$target"; then continue; fi
            local lat
            lat=$(check_candidate_quality "$target" 2>/dev/null || true)
            if [[ -n "$lat" && "$lat" != "0" ]]; then
                valid_target="$target"
                target_latency="$lat"
                break
            fi
        done

        if [[ -n "$valid_target" ]]; then
            printf "    - 高校 \033[1;37m%-30s\033[0m ... \033[0;32m[合格] HTTP/2 200 (延迟: %d ms)\033[0m\n" "$valid_target" "$target_latency"
            if (( target_latency < min_latency )); then
                min_latency=$target_latency
                best_sni=$valid_target
            fi
        else
            printf "    - 高校 %-30s ... \033[0;31m[淘汰] (套CDN/非200/不支持H2)\033[0m\n" "$base"
        fi
    done

    if [[ -n "$best_sni" ]]; then
        SELECTED_SNI="$best_sni"
        echo -e "${GREEN}[★] 高校优选成功！选用独立大学源站: \033[1;33m${SELECTED_SNI}\033[0;32m (本地延迟: ${min_latency} ms)${PLAIN}"
    else
        echo -e "${YELLOW}[!] 本地候选高校未能通过严苛体检，平滑降级启动 [大厂安全随机池]...${PLAIN}"
        pick_safe_bigtech_sni
    fi
}

pick_safe_bigtech_sni() {
    echo -e "${CYAN}[+] 正在检索大厂安全域名池 (已彻底清退 Cloudflare / 100% 独立专属)...${PLAIN}"
    local safe_bigtech_pool=(
        "gateway.icloud.com"
        "www.apple.com"
        "swdist.apple.com"
        "itunes.apple.com"
        "addons.mozilla.org"
        "www.paypal.com"
        "www.ebay.com"
        "www.amazon.com"
        "aws.amazon.com"
    )

    local shuffled=()
    while IFS= read -r line; do
        [[ -n "$line" ]] && shuffled+=("$line")
    done < <(printf "%s\n" "${safe_bigtech_pool[@]}" | shuf)

    local best_tech=""
    local min_lat=99999

    for domain in "${shuffled[@]}"; do
        printf "    - 抽检大厂安全节点 \033[1;37m%-32s\033[0m ... " "$domain"
        if ! getent ahosts "$domain" &>/dev/null; then continue; fi
        local lat
        lat=$(check_candidate_quality "$domain" 2>/dev/null || true)
        if [[ -n "$lat" && "$lat" != "0" ]]; then
            printf "\033[0;32m[合格] HTTP/2 200 (延迟: %d ms)\033[0m\n" "$lat"
            if (( lat < min_lat )); then
                min_lat=$lat
                best_tech=$domain
            fi
        else
            printf "\033[0;31m[跳过: 握手不符或超时]\033[0m\n"
        fi
    done

    if [[ -n "$best_tech" ]]; then
        SELECTED_SNI="$best_tech"
        echo -e "${GREEN}[★] 大厂安全域名优选成功: \033[1;33m${SELECTED_SNI}\033[0;32m (本地延迟: ${min_lat} ms)${PLAIN}"
    else
        SELECTED_SNI="gateway.icloud.com"
        echo -e "${YELLOW}[!] 兜底选用 Apple 官方节点: ${SELECTED_SNI}${PLAIN}"
    fi
}

# -------------------------------------------------------------
# 3. 协议配置生成器 (四大核心协议)
# -------------------------------------------------------------

# 3.1 VLESS-Reality
add_vless_reality() {
    echo -e "\n${CYAN}>>> 配置 VLESS-Reality 节点 <<<${PLAIN}"
    local default_port=$((RANDOM % 20000 + 30000))
    read -rp "请输入监听端口 [默认: ${default_port}]: " port
    port=${port:-$default_port}

    auto_select_best_sni

    local uuid
    uuid=$("${BIN_PATH}" generate uuid)

    # 修复并兼容私钥解析
    local keypair
    keypair=$("${BIN_PATH}" generate reality-keypair)
    local private_key
    private_key=$(echo "$keypair" | grep -iE "PrivateKey|Private key" | head -n 1 | sed 's/.*:[[:space:]]*//' | tr -d ' "\r\n')
    local public_key
    public_key=$(echo "$keypair" | grep -iE "PublicKey|Public key" | head -n 1 | sed 's/.*:[[:space:]]*//' | tr -d ' "\r\n')

    if [[ -z "$private_key" || -z "$public_key" ]]; then
        local tmp_keys=($(echo "$keypair" | sed 's/.*://'))
        private_key=$(echo "${tmp_keys[0]}" | tr -d ' "\r\n')
        public_key=$(echo "${tmp_keys[1]}" | tr -d ' "\r\n')
    fi

    local short_id
    short_id=$(openssl rand -hex 8)

    local tag="vless-reality-${port}"
    local inbound_json=$(cat <<EOF
{
  "type": "vless",
  "tag": "${tag}",
  "listen": "::",
  "listen_port": ${port},
  "users": [
    {
      "uuid": "${uuid}",
      "flow": "xtls-rprx-vision"
    }
  ],
  "tls": {
    "enabled": true,
    "server_name": "${SELECTED_SNI}",
    "reality": {
      "enabled": true,
      "handshake": {
        "server": "${SELECTED_SNI}",
        "server_port": 443
      },
      "private_key": "${private_key}",
      "short_id": [
        "${short_id}"
      ]
    }
  }
}
EOF
)

    get_public_ip
    local share_link="vless://${uuid}@${VPS_IP}:${port}?security=reality&flow=xtls-rprx-vision&pbk=${public_key}&sni=${SELECTED_SNI}&sid=${short_id}&type=tcp&fp=chrome#Reality-${SELECTED_SNI}-${port}"

    local node_meta=$(cat <<EOF
{
  "tag": "${tag}",
  "type": "vless-reality",
  "port": ${port},
  "uuid": "${uuid}",
  "sni": "${SELECTED_SNI}",
  "public_key": "${public_key}",
  "short_id": "${short_id}",
  "link": "${share_link}"
}
EOF
)

    apply_inbound_config "$tag" "$inbound_json" "$node_meta"
}

# 3.2 Hysteria 2 (UDP 极速冲浪)
add_hysteria2() {
    echo -e "\n${CYAN}>>> 配置 Hysteria 2 节点 (UDP暴力加速) <<<${PLAIN}"
    local default_port=$((RANDOM % 20000 + 30000))
    read -rp "请输入监听端口 [默认: ${default_port}]: " port
    port=${port:-$default_port}

    local password
    password=$(openssl rand -hex 16)
    ensure_tls_cert

    local tag="hysteria2-${port}"
    local inbound_json=$(cat <<EOF
{
  "type": "hysteria2",
  "tag": "${tag}",
  "listen": "::",
  "listen_port": ${port},
  "users": [
    {
      "password": "${password}"
    }
  ],
  "tls": {
    "enabled": true,
    "certificate_path": "${CERT_FILE}",
    "key_path": "${KEY_FILE}"
  }
}
EOF
)

    get_public_ip
    local share_link="hysteria2://${password}@${VPS_IP}:${port}?insecure=1&sni=bing.com#Hy2-${port}"

    local node_meta=$(cat <<EOF
{
  "tag": "${tag}",
  "type": "hysteria2",
  "port": ${port},
  "password": "${password}",
  "sni": "bing.com",
  "link": "${share_link}"
}
EOF
)

    apply_inbound_config "$tag" "$inbound_json" "$node_meta"
}

# 3.3 TUIC v5 (QUIC 协议)
add_tuic() {
    echo -e "\n${CYAN}>>> 配置 TUIC v5 节点 (QUIC 双栈) <<<${PLAIN}"
    local default_port=$((RANDOM % 20000 + 30000))
    read -rp "请输入监听端口 [默认: ${default_port}]: " port
    port=${port:-$default_port}

    local uuid
    uuid=$("${BIN_PATH}" generate uuid)
    local password
    password=$(openssl rand -hex 12)
    ensure_tls_cert

    local tag="tuic-${port}"
    local inbound_json=$(cat <<EOF
{
  "type": "tuic",
  "tag": "${tag}",
  "listen": "::",
  "listen_port": ${port},
  "users": [
    {
      "uuid": "${uuid}",
      "password": "${password}"
    }
  ],
  "congestion_control": "bbr",
  "tls": {
    "enabled": true,
    "alpn": ["h3"],
    "certificate_path": "${CERT_FILE}",
    "key_path": "${KEY_FILE}"
  }
}
EOF
)

    get_public_ip
    local share_link="tuic://${uuid}:${password}@${VPS_IP}:${port}?congestion_control=bbr&alpn=h3&allow_insecure=1&sni=bing.com#TUIC-${port}"

    local node_meta=$(cat <<EOF
{
  "tag": "${tag}",
  "type": "tuic",
  "port": ${port},
  "uuid": "${uuid}",
  "password": "${password}",
  "sni": "bing.com",
  "link": "${share_link}"
}
EOF
)

    apply_inbound_config "$tag" "$inbound_json" "$node_meta"
}

# 3.4 Shadowsocks 2022
add_shadowsocks() {
    echo -e "\n${CYAN}>>> 配置 Shadowsocks 2022 节点 <<<${PLAIN}"
    local default_port=$((RANDOM % 20000 + 30000))
    read -rp "请输入监听端口 [默认: ${default_port}]: " port
    port=${port:-$default_port}

    # 2022-blake3-aes-128-gcm 要求 16 字节密钥 (Base64)
    local password
    password=$(openssl rand -base64 16)

    local tag="ss-${port}"
    local inbound_json=$(cat <<EOF
{
  "type": "shadowsocks",
  "tag": "${tag}",
  "listen": "::",
  "listen_port": ${port},
  "network": "tcp,udp",
  "method": "2022-blake3-aes-128-gcm",
  "password": "${password}"
}
EOF
)

    get_public_ip
    # Shadowsocks 2022 SIP002 格式: ss://base64(method:password)@ip:port#tag
    local creds
    creds=$(echo -n "2022-blake3-aes-128-gcm:${password}" | base64 | tr -d '\n')
    local share_link="ss://${creds}@${VPS_IP}:${port}#SS-${port}"

    local node_meta=$(cat <<EOF
{
  "tag": "${tag}",
  "type": "shadowsocks-2022",
  "port": ${port},
  "method": "2022-blake3-aes-128-gcm",
  "password": "${password}",
  "link": "${share_link}"
}
EOF
)

    apply_inbound_config "$tag" "$inbound_json" "$node_meta"
}

# 写入配置与重启服务
apply_inbound_config() {
    local tag="$1"
    local inbound_json="$2"
    local node_meta="$3"

    echo -e "${CYAN}[+] 正在将入站规则写入核心配置...${PLAIN}"
    # 移除同名 tag (如果存在)
    jq --arg t "$tag" '.inbounds = [.inbounds[] | select(.tag != $t)]' "$CONF_FILE" > "${CONF_FILE}.tmp"
    # 追加新入站
    jq --argjson new_in "$inbound_json" '.inbounds += [$new_in]' "${CONF_FILE}.tmp" > "$CONF_FILE"
    rm -f "${CONF_FILE}.tmp"

    # 语法检测
    if ! "$BIN_PATH" check -c "$CONF_FILE"; then
        echo -e "${RED}[错误] sing-box 语法校验失败！正在回滚...${PLAIN}"
        exit 1
    fi

    # 更新元数据
    jq --arg t "$tag" '[.[] | select(.tag != $t)]' "$NODES_FILE" > "${NODES_FILE}.tmp"
    jq --argjson new_node "$node_meta" '. += [$new_node]' "${NODES_FILE}.tmp" > "$NODES_FILE"
    rm -f "${NODES_FILE}.tmp"

    systemctl restart "${APP_NAME}"
    echo -e "${GREEN}[✓] 节点 [${tag}] 已成功添加并激活！${PLAIN}"
    print_single_node "$tag"
}

# -------------------------------------------------------------
# 4. 节点删除与列表管理
# -------------------------------------------------------------
delete_node() {
    local count
    count=$(jq 'length' "$NODES_FILE" 2>/dev/null || echo 0)
    if [[ "$count" -eq 0 ]]; then
        echo -e "${YELLOW}[!] 当前没有任何节点！${PLAIN}"
        return
    fi

    echo -e "\n${CYAN}当前存在的节点列表:${PLAIN}"
    jq -r 'to_entries[] | "\(.key + 1). [\(.value.type)] 端口: \(.value.port) (tag: \(.value.tag))"' "$NODES_FILE"
    echo ""
    read -rp "请输入你想删除的节点编号 [1-${count}]: " idx

    if [[ "$idx" =~ ^[0-9]+$ ]] && (( idx >= 1 && idx <= count )); then
        local real_idx=$((idx - 1))
        local del_tag
        del_tag=$(jq -r --argjson i "$real_idx" '.[$i].tag' "$NODES_FILE")

        # 从配置文件中删除
        jq --arg t "$del_tag" '.inbounds = [.inbounds[] | select(.tag != $t)]' "$CONF_FILE" > "${CONF_FILE}.tmp" && mv "${CONF_FILE}.tmp" "$CONF_FILE"
        # 从元数据中删除
        jq --arg t "$del_tag" '[.[] | select(.tag != $t)]' "$NODES_FILE" > "${NODES_FILE}.tmp" && mv "${NODES_FILE}.tmp" "$NODES_FILE"

        systemctl restart "${APP_NAME}"
        echo -e "${GREEN}[✓] 节点 [${del_tag}] 已彻底删除！${PLAIN}"
    else
        echo -e "${RED}[错误] 无效的编号！${PLAIN}"
    fi
}

# -------------------------------------------------------------
# 5. 节点信息展示与二维码导出
# -------------------------------------------------------------
print_single_node() {
    local target_tag="$1"
    local node
    node=$(jq --arg t "$target_tag" '.[] | select(.tag == $t)' "$NODES_FILE")
    [[ -z "$node" ]] && return

    local type port link
    type=$(echo "$node" | jq -r '.type')
    port=$(echo "$node" | jq -r '.port')
    link=$(echo "$node" | jq -r '.link')

    get_public_ip

    echo -e "\n========================================================"
    echo -e " 协议类型 (Type)     : ${YELLOW}${type}${PLAIN}"
    echo -e " 监听端口 (Port)     : ${CYAN}${port}${PLAIN}"
    echo -e " 节点标签 (Tag)      : ${CYAN}${target_tag}${PLAIN}"

    case "$type" in
        vless-reality)
            echo -e " 用户 ID (UUID)      : ${CYAN}$(echo "$node" | jq -r '.uuid')${PLAIN}"
            echo -e " 伪装域名 (SNI)      : ${GREEN}$(echo "$node" | jq -r '.sni')${PLAIN}"
            echo -e " 公钥 (Public Key)   : ${CYAN}$(echo "$node" | jq -r '.public_key')${PLAIN}"
            echo -e " Short ID            : ${CYAN}$(echo "$node" | jq -r '.short_id')${PLAIN}"
            ;;
        hysteria2)
            echo -e " 认证密码 (Password) : ${CYAN}$(echo "$node" | jq -r '.password')${PLAIN}"
            echo -e " 伪装 SNI            : ${GREEN}$(echo "$node" | jq -r '.sni')${PLAIN}"
            ;;
        tuic)
            echo -e " 用户 ID (UUID)      : ${CYAN}$(echo "$node" | jq -r '.uuid')${PLAIN}"
            echo -e " 认证密码 (Password) : ${CYAN}$(echo "$node" | jq -r '.password')${PLAIN}"
            ;;
        shadowsocks-2022)
            echo -e " 加密方式 (Method)   : ${CYAN}$(echo "$node" | jq -r '.method')${PLAIN}"
            echo -e " 密码 (Password)     : ${CYAN}$(echo "$node" | jq -r '.password')${PLAIN}"
            ;;
    esac

    echo -e "--------------------------------------------------------"
    echo -e " 分享链接 (Share Link):"
    echo -e " ${GREEN}${link}${PLAIN}"
    echo -e "========================================================"

    if command -v qrencode &>/dev/null; then
        echo -e "\n终端二维码 (直接扫码导入客户端):"
        qrencode -t ANSIUTF8 "${link}"
    fi
}

show_all_nodes() {
    local count
    count=$(jq 'length' "$NODES_FILE" 2>/dev/null || echo 0)
    if [[ "$count" -eq 0 ]]; then
        echo -e "${YELLOW}[!] 当前未配置任何节点，请选择添加节点！${PLAIN}"
        return
    fi

    echo -e "\n========================================================"
    echo -e "              ${GREEN}已激活的节点连接信息列表${PLAIN}"
    echo -e "========================================================"
    local tags=($(jq -r '.[].tag' "$NODES_FILE"))
    for t in "${tags[@]}"; do
        print_single_node "$t"
        echo ""
    done
}

# -------------------------------------------------------------
# 6. 系统 BBR 加速一键开启
# -------------------------------------------------------------
enable_bbr() {
    echo -e "${CYAN}[+] 正在配置 Linux 内核原版 BBR + FQ 算法...${PLAIN}"
    if ! grep -q "net.core.default_qdisc=fq" /etc/sysctl.conf; then
        echo "net.core.default_qdisc=fq" >> /etc/sysctl.conf
    fi
    if ! grep -q "net.ipv4.tcp_congestion_control=bbr" /etc/sysctl.conf; then
        echo "net.ipv4.tcp_congestion_control=bbr" >> /etc/sysctl.conf
    fi
    sysctl -p >/dev/null 2>&1
    local current_cc
    current_cc=$(sysctl net.ipv4.tcp_congestion_control | awk '{print $NF}')
    echo -e "${GREEN}[✓] 开启成功！当前系统 TCP 拥塞控制算法为: ${current_cc}${PLAIN}"
}

# -------------------------------------------------------------
# 7. 全局 CLI 快捷键注册
# -------------------------------------------------------------
install_cli_shortcut() {
    cp -f "$0" "$SCRIPT_INSTALL_PATH" 2>/dev/null || true
    chmod +x "$SCRIPT_INSTALL_PATH" 2>/dev/null || true
}

# -------------------------------------------------------------
# 8. 添加新节点路由器
# -------------------------------------------------------------
menu_add_node() {
    echo -e "\n--------------------------------------------------------"
    echo -e " 请选择要添加的协议类型:"
    echo -e " ${GREEN}1.${PLAIN} \033[1;32mVLESS-Reality\033[0m   (Vision 流控 + 高校动态优选防白嫖，最稳推特)"
    echo -e " ${GREEN}2.${PLAIN} \033[1;33mHysteria 2\033[0m      (UDP 极速冲浪，适合晚高峰/恶劣网络)"
    echo -e " ${GREEN}3.${PLAIN} \033[1;36mTUIC v5\033[0m         (基于 QUIC 协议，极低延迟 0-RTT 握手)"
    echo -e " ${GREEN}4.${PLAIN} \033[1;35mShadowsocks 2022\033[0m(2022-blake3-aes-128-gcm，轻量纯净)"
    echo -e " ${GREEN}0.${PLAIN} 返回上一级"
    echo -e "--------------------------------------------------------"
    read -rp "请输入选项 [0-4]: " p_opt

    case "$p_opt" in
        1) add_vless_reality ;;
        2) add_hysteria2 ;;
        3) add_tuic ;;
        4) add_shadowsocks ;;
        0) return ;;
        *) echo -e "${RED}无效选项！${PLAIN}" ;;
    esac
}

# -------------------------------------------------------------
# 9. 交互式主菜单 (全面超越 233boy 体验)
# -------------------------------------------------------------
show_menu() {
    clear
    echo -e "========================================================"
    echo -e "    ${CYAN}sing-box Full Suite Manager (233boy 增强重构版)${PLAIN}"
    echo -e "========================================================"

    local status
    if systemctl is-active --quiet "${APP_NAME}" 2>/dev/null; then
        status="${GREEN}运行中${PLAIN}"
    else
        status="${RED}未运行${PLAIN}"
    fi

    local core_ver="未知"
    if [[ -f "$BIN_PATH" ]]; then
        core_ver=$("$BIN_PATH" version | head -n 1 | awk '{print $3}')
    fi

    echo -e " 服务状态: ${status} | 核心版本: ${CYAN}${core_ver}${PLAIN}"
    echo -e "--------------------------------------------------------"
    
    local count
    count=$(jq 'length' "$NODES_FILE" 2>/dev/null || echo 0)
    echo -e " 已配置活跃节点总数: ${YELLOW}${count}${PLAIN} 个"
    if [[ "$count" -gt 0 ]]; then
        jq -r 'to_entries[] | "  [\(.key + 1)] \(.value.type) (端口: \(.value.port))"' "$NODES_FILE" 2>/dev/null || true
    fi

    echo -e "--------------------------------------------------------"
    echo -e " ${GREEN}1.${PLAIN} 添加新节点 (VLESS-Reality / Hysteria2 / TUIC / SS)"
    echo -e " ${GREEN}2.${PLAIN} 删除现有节点"
    echo -e " ${GREEN}3.${PLAIN} 查看所有节点连接信息 & 二维码"
    echo -e " ${GREEN}4.${PLAIN} 一键开启系统 BBR 拥塞控制加速"
    echo -e " ${GREEN}5.${PLAIN} 启动服务"
    echo -e " ${GREEN}6.${PLAIN} 停止服务"
    echo -e " ${GREEN}7.${PLAIN} 重启服务"
    echo -e " ${GREEN}8.${PLAIN} 查看实时运行日志 (tail -f)"
    echo -e " ${GREEN}9.${PLAIN} 彻底卸载 sing-box"
    echo -e " ${GREEN}0.${PLAIN} 退出管理"
    echo -e "========================================================"
    read -rp "请输入选项 [0-9]: " opt

    case "$opt" in
        1) menu_add_node ;;
        2) delete_node ;;
        3) show_all_nodes ;;
        4) enable_bbr ;;
        5) systemctl start "${APP_NAME}" && echo -e "${GREEN}服务已启动！${PLAIN}" ;;
        6) systemctl stop "${APP_NAME}" && echo -e "${YELLOW}服务已停止！${PLAIN}" ;;
        7) systemctl restart "${APP_NAME}" && echo -e "${GREEN}服务已重启！${PLAIN}" ;;
        8) journalctl -u "${APP_NAME}" -f -n 50 ;;
        9)
            systemctl stop "${APP_NAME}" 2>/dev/null || true
            systemctl disable "${APP_NAME}" 2>/dev/null || true
            rm -rf "${CONF_DIR}" "${SERVICE_FILE}" "${BIN_PATH}" "${SCRIPT_INSTALL_PATH}"
            systemctl daemon-reload
            echo -e "${GREEN}卸载清理完成！${PLAIN}"
            exit 0
            ;;
        0) exit 0 ;;
        *) echo -e "${RED}输入无效！${PLAIN}" ;;
    esac

    echo ""
    read -n 1 -s -r -p "按任意键返回主菜单..."
    show_menu
}

# -------------------------------------------------------------
# 10. 程序主入口 (支持子命令直接调用)
# -------------------------------------------------------------
check_root
install_dependencies
download_singbox_core
install_cli_shortcut

if [[ $# -gt 0 ]]; then
    case "$1" in
        add) menu_add_node ;;
        del) delete_node ;;
        info|list) show_all_nodes ;;
        bbr) enable_bbr ;;
        start) systemctl start "${APP_NAME}" ;;
        stop) systemctl stop "${APP_NAME}" ;;
        restart) systemctl restart "${APP_NAME}" ;;
        status) systemctl status "${APP_NAME}" ;;
        log) journalctl -u "${APP_NAME}" -f -n 50 ;;
        *) echo "用法: sb [add|del|info|list|bbr|start|stop|restart|status|log]" ;;
    esac
else
    # 初次安装若无节点，引导添加第一个节点
    local current_nodes
    current_nodes=$(jq 'length' "$NODES_FILE" 2>/dev/null || echo 0)
    if [[ "$current_nodes" -eq 0 ]]; then
        echo -e "${GREEN}首次安装，请添加你的第一个代理节点：${PLAIN}"
        menu_add_node
    fi
    show_menu
fi
