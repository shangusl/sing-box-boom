#!/usr/bin/env bash
# =========================================================================
#  Project:   sing-box-boom (233boy 全量协议迁移 & 智能防封增强版)
#  Protocols: VLESS-Reality / Hysteria 2 / TUIC v5 / Shadowsocks 2022
#  Features:  多节点共存 / 全球高校独立源站引擎 / BBR加速 / 完整CLI菜单
# =========================================================================

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
CONF_DIR="/etc/${APP_NAME}"
CONF_FILE="${CONF_DIR}/config.json"
NODES_FILE="${CONF_DIR}/nodes.json"
CERT_FILE="${CONF_DIR}/cert.crt"
KEY_FILE="${CONF_DIR}/cert.key"
SERVICE_FILE="/etc/systemd/system/${APP_NAME}.service"
SCRIPT_INSTALL_PATH="/usr/local/bin/sbox"
CORE_BIN_DIR="${CONF_DIR}/bin"
CORE_BIN="${CORE_BIN_DIR}/sing-box"
BIN_PATH="${CORE_BIN}"

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
ensure_valid_json_file() {
    local f="$1"
    local default_content="$2"
    local expected_type="${3:-}"

    local valid=1
    if [[ ! -f "$f" || ! -s "$f" ]]; then
        valid=0
    elif ! jq empty "$f" >/dev/null 2>&1; then
        valid=0
    elif [[ -n "$expected_type" ]]; then
        if ! jq -e "type == \"$expected_type\"" "$f" >/dev/null 2>&1; then
            valid=0
        fi
    fi

    if [[ "$valid" -eq 0 ]]; then
        echo "$default_content" > "$f"
    fi
}

ensure_systemd_service() {
    local need_update=0
    if [[ ! -f "$SERVICE_FILE" ]]; then
        need_update=1
    elif ! grep -q "ExecStart=${CORE_BIN}" "$SERVICE_FILE" 2>/dev/null; then
        need_update=1
    fi

    if [[ "$need_update" -eq 1 ]]; then
        cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=sing-box Full Suite Service
Documentation=https://sing-box.sagernet.org
After=network.target nss-lookup.target

[Service]
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
NoNewPrivileges=true
ExecStart=${CORE_BIN} run -c ${CONF_FILE}
Restart=on-failure
RestartPreventExitStatus=23
LimitNPROC=10000
LimitNOFILE=1000000

[Install]
WantedBy=multi-user.target
EOF
        systemctl daemon-reload
        systemctl enable "${APP_NAME}" >/dev/null 2>&1
    fi
}

init_environment() {
    mkdir -p "${CONF_DIR}" "${CORE_BIN_DIR}"
    ensure_valid_json_file "$CONF_FILE" '{"log":{"level":"warn","timestamp":true},"inbounds":[],"outbounds":[{"type":"direct","tag":"direct"}]}' "object"
    ensure_valid_json_file "$NODES_FILE" "[]" "array"
    ensure_systemd_service

    import_legacy_and_233boy_nodes
    sync_and_clean_inbounds
}

# -------------------------------------------------------------
# 1.1 自动兼容与迁移 233boy 及已有历史节点
# -------------------------------------------------------------
import_legacy_and_233boy_nodes() {
    ensure_valid_json_file "$NODES_FILE" "[]" "array"
    ensure_valid_json_file "$CONF_FILE" '{"log":{"level":"warn","timestamp":true},"inbounds":[],"outbounds":[{"type":"direct","tag":"direct"}]}' "object"
    get_public_ip

    local target_files=()
    if [[ -d "${CONF_DIR}" ]]; then
        while IFS= read -r f; do
            [[ -f "$f" ]] && target_files+=("$f")
        done < <(find "${CONF_DIR}" -type f -name "*.json" ! -name "nodes.json" ! -name "*.tmp" ! -name "*.bak" 2>/dev/null)
    fi

    [[ ${#target_files[@]} -eq 0 ]] && return 0

    local imported_any=0

    for file in "${target_files[@]}"; do
        # 兼容提取嵌套或单层 inbounds（无论是否有 inbounds 键包装）
        local in_objs
        in_objs=$(jq -c '[.. | select(type == "object" and (.type | IN("vless", "hysteria2", "tuic", "shadowsocks", "trojan", "vmess")) and has("listen_port"))]' "$file" 2>/dev/null || echo "[]")
        local count
        count=$(echo "$in_objs" | jq 'length' 2>/dev/null || echo 0)
        count=${count:-0}
        [[ "$count" -eq 0 ]] && continue

        for ((i=0; i<count; i++)); do
            local in_obj
            in_obj=$(echo "$in_objs" | jq -c --argjson idx "$i" '.[$idx]' 2>/dev/null)
            local itype
            itype=$(echo "$in_obj" | jq -r '.type // empty')
            local iport
            iport=$(echo "$in_obj" | jq -r '.listen_port // empty')
            local itag
            itag=$(echo "$in_obj" | jq -r '.tag // empty')

            [[ -z "$itype" || -z "$iport" ]] && continue
            [[ -z "$itag" ]] && itag="${itype}-${iport}"

            # 校验是否已在 nodes.json 中
            local exist
            exist=$(jq --arg t "$itag" --arg p "$iport" '.[] | select(.tag == $t or (.port | tostring) == $p) | .tag' "$NODES_FILE" 2>/dev/null)
            if [[ -n "$exist" ]]; then
                continue
            fi

            local node_entry=""

            if [[ "$itype" == "vless" ]]; then
                local uuid=$(echo "$in_obj" | jq -r '.users[0].uuid // empty')
                local sni=$(echo "$in_obj" | jq -r '.tls.server_name // .tls.reality.handshake.server // "www.apple.com"')
                local sid=$(echo "$in_obj" | jq -r '.tls.reality.short_id[0] // empty')
                # 233boy 常用模式：outbounds 中存放 public_key_<key>，或者 reality 自身携带 public_key
                local pbk=$(jq -r '.outbounds[]? | select(.tag | startswith("public_key_")) | .tag | sub("public_key_"; "")' "$file" 2>/dev/null)
                if [[ -z "$pbk" || "$pbk" == "null" ]]; then
                    pbk=$(echo "$in_obj" | jq -r '.tls.reality.public_key // empty')
                fi
                pbk=${pbk:-""}
                local is_reality=$(echo "$in_obj" | jq -r '.tls.reality.enabled // false')
                local share_link=""
                if [[ "$is_reality" == "true" || -n "$sid" || -n "$pbk" ]]; then
                    share_link="vless://${uuid}@${VPS_IP}:${iport}?security=reality&flow=xtls-rprx-vision&pbk=${pbk}&sni=${sni}&sid=${sid}&type=tcp&fp=chrome#Reality-${sni}-${iport}"
                    node_entry=$(jq -n \
                        --arg tag "$itag" --arg type "vless-reality" --argjson port "$iport" \
                        --arg uuid "$uuid" --arg pbk "$pbk" --arg sni "$sni" --arg sid "$sid" --arg link "$share_link" \
                        '{tag: $tag, type: $type, port: $port, uuid: $uuid, public_key: $pbk, sni: $sni, short_id: $sid, link: $link}')
                else
                    share_link="vless://${uuid}@${VPS_IP}:${iport}?security=none&type=tcp#VLESS-${iport}"
                    node_entry=$(jq -n \
                        --arg tag "$itag" --arg type "vless" --argjson port "$iport" \
                        --arg uuid "$uuid" --arg link "$share_link" \
                        '{tag: $tag, type: $type, port: $port, uuid: $uuid, link: $link}')
                fi

            elif [[ "$itype" == "hysteria2" ]]; then
                local pwd=$(echo "$in_obj" | jq -r '.users[0].password // empty')
                local sni=$(echo "$in_obj" | jq -r '.tls.server_name // "bing.com"')
                local link="hysteria2://${pwd}@${VPS_IP}:${iport}?insecure=1&sni=${sni}#Hy2-${iport}"
                node_entry=$(jq -n \
                    --arg tag "$itag" --arg type "hysteria2" --argjson port "$iport" \
                    --arg pwd "$pwd" --arg link "$link" \
                    '{tag: $tag, type: $type, port: $port, password: $pwd, link: $link}')

            elif [[ "$itype" == "tuic" ]]; then
                local uuid=$(echo "$in_obj" | jq -r '.users[0].uuid // empty')
                local pwd=$(echo "$in_obj" | jq -r '.users[0].password // empty')
                local link="tuic://${uuid}:${pwd}@${VPS_IP}:${iport}?congestion_control=bbr&alpn=h3&allow_insecure=1&sni=bing.com#TUIC-${iport}"
                node_entry=$(jq -n \
                    --arg tag "$itag" --arg type "tuic" --argjson port "$iport" \
                    --arg uuid "$uuid" --arg pwd "$pwd" --arg link "$link" \
                    '{tag: $tag, type: $type, port: $port, uuid: $uuid, password: $pwd, link: $link}')

            elif [[ "$itype" == "shadowsocks" ]]; then
                local method=$(echo "$in_obj" | jq -r '.method // "2022-blake3-aes-128-gcm"')
                local pwd=$(echo "$in_obj" | jq -r '.password // empty')
                local ss_userinfo=$(echo -n "${method}:${pwd}" | base64 2>/dev/null | tr -d '\r\n')
                local link="ss://${ss_userinfo}@${VPS_IP}:${iport}#SS-${iport}"
                node_entry=$(jq -n \
                    --arg tag "$itag" --arg type "shadowsocks-2022" --argjson port "$iport" \
                    --arg method "$method" --arg pwd "$pwd" --arg link "$link" \
                    '{tag: $tag, type: $type, port: $port, method: $method, password: $pwd, link: $link}')
            fi

            if [[ -n "$node_entry" ]]; then
                ensure_valid_json_file "$NODES_FILE" "[]" "array"
                jq --argjson n "$node_entry" '. = ((. // []) + [$n])' "$NODES_FILE" > "${NODES_FILE}.tmp" 2>/dev/null
                if [[ -s "${NODES_FILE}.tmp" ]] && jq -e 'type == "array"' "${NODES_FILE}.tmp" >/dev/null 2>&1; then
                    mv -f "${NODES_FILE}.tmp" "$NODES_FILE"
                fi

                # 如果这个来自 conf/*.json 或非主配置文件，合并同步到主 config.json
                if [[ "$file" != "$CONF_FILE" ]]; then
                    ensure_valid_json_file "$CONF_FILE" '{"log":{"level":"warn","timestamp":true},"inbounds":[],"outbounds":[{"type":"direct","tag":"direct"}]}' "object"
                    # 确保 in_obj 有 tag
                    if [[ -z $(echo "$in_obj" | jq -r '.tag // empty') ]]; then
                        in_obj=$(echo "$in_obj" | jq --arg t "$itag" '. + {tag: $t}')
                    fi
                    jq --arg t "$itag" --arg p "$iport" '.inbounds = [(.inbounds // [])[]? | select(.tag != $t and (.listen_port | tostring) != $p)]' "$CONF_FILE" > "${CONF_FILE}.tmp" 2>/dev/null
                    if [[ -s "${CONF_FILE}.tmp" ]]; then
                        mv -f "${CONF_FILE}.tmp" "$CONF_FILE"
                    fi
                    jq --argjson new_in "$in_obj" '.inbounds = ((.inbounds // []) + [$new_in])' "$CONF_FILE" > "${CONF_FILE}.tmp" 2>/dev/null
                    if [[ -s "${CONF_FILE}.tmp" ]]; then
                        mv -f "${CONF_FILE}.tmp" "$CONF_FILE"
                    fi
                fi
                imported_any=1
            fi
        done
    done

    if [[ "$imported_any" -eq 1 ]]; then
        echo -e "${GREEN}[✓] 成功从已有环境 (如 233boy) 自动识别并迁移所有历史节点！${PLAIN}"
    fi
}

sync_and_clean_inbounds() {
    [[ ! -f "$CONF_FILE" || ! -f "$NODES_FILE" ]] && return 0
    ensure_valid_json_file "$NODES_FILE" "[]" "array"
    ensure_valid_json_file "$CONF_FILE" '{"log":{"level":"warn","timestamp":true},"inbounds":[],"outbounds":[{"type":"direct","tag":"direct"}]}' "object"

    local count
    count=$(jq 'length' "$NODES_FILE" 2>/dev/null || echo 0)
    count=${count:-0}
    if [[ "$count" -gt 0 ]]; then
        local valid_tags
        valid_tags=$(jq -c '[.[].tag]' "$NODES_FILE" 2>/dev/null)
        if [[ -n "$valid_tags" && "$valid_tags" != "[]" ]]; then
            # 展平所有可能被多重包装的数组，提取有效 tag 并按 listen_port 保证 1D 数组去重
            jq --argjson tags "$valid_tags" \
               '.inbounds = ([.inbounds | .. | select(type == "object" and has("tag") and has("listen_port")) | select(.tag as $t | $tags | index($t))] | reverse | unique_by(.listen_port) | reverse)' \
               "$CONF_FILE" > "${CONF_FILE}.tmp" 2>/dev/null
            if [[ -s "${CONF_FILE}.tmp" ]] && jq -e 'type == "object"' "${CONF_FILE}.tmp" >/dev/null 2>&1; then
                mv -f "${CONF_FILE}.tmp" "$CONF_FILE"
            fi
        fi
    fi

    # 如果存在节点但服务未运行，自动清除孤儿进程并拉起服务
    if [[ "$count" -gt 0 ]] && ! systemctl is-active --quiet "${APP_NAME}" 2>/dev/null; then
        killall -9 sing-box 2>/dev/null || true
        systemctl daemon-reload
        systemctl restart "${APP_NAME}" 2>/dev/null || true
    fi
}

download_singbox_core() {
    check_arch
    mkdir -p "${CORE_BIN_DIR}"
    init_environment

    # 优先检测 /etc/sing-box/bin/sing-box 是否已是真正的二进制核心 (ELF 格式)
    if [[ -f "$CORE_BIN" ]] && head -c 4 "$CORE_BIN" 2>/dev/null | grep -q "ELF"; then
        chmod +x "$CORE_BIN"
        return
    fi

    # 如果 /usr/local/bin/sing-box 存在且是真实的 ELF 核心，直接复用
    if [[ -f "/usr/local/bin/sing-box" ]] && head -c 4 "/usr/local/bin/sing-box" 2>/dev/null | grep -q "ELF"; then
        cp -f "/usr/local/bin/sing-box" "$CORE_BIN"
        chmod +x "$CORE_BIN"
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
    cp -f "/tmp/sing-box-${version}-linux-${ARCH}/sing-box" "$CORE_BIN"
    chmod +x "$CORE_BIN"
    rm -rf "/tmp/sing-box"*
    echo -e "${GREEN}[✓] sing-box 核心安装成功 -> ${CORE_BIN}${PLAIN}"

    init_environment
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
    headers=$(curl -sI -m 3 "https://${target}" 2>/dev/null | tr '[:upper:]' '[:lower:]' || true)
    if echo "$headers" | grep -qE "server: cloudflare|cf-ray:|x-amz-cf-id:|via:.*cloudfront|x-fastly-request-id:|server: akamaighost"; then
        return 1
    fi

    local ip
    ip=$(getent ahosts "$target" 2>/dev/null | awk '{print $1}' | head -n 1 || true)
    [[ -z "$ip" ]] && return 1

    local asn_info
    asn_info=$(curl -s4m 3 "http://ip-api.com/json/${ip}?fields=as,isp" 2>/dev/null || true)
    if [[ -n "$asn_info" ]] && echo "$asn_info" | grep -qiE "cloudflare|amazon|fastly|akamai"; then
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
        "https://${target}" 2>/dev/null || echo "000|0.000000")

    local http_code
    http_code=$(echo "$result" | cut -d'|' -f1)
    local appconnect_time
    appconnect_time=$(echo "$result" | cut -d'|' -f2)

    # 兼容支持 200, 301, 302, 304, 307, 308 等 HTTP/2 TLS 握手正常应答
    if [[ ("$http_code" =~ ^(200|301|302|304|307|308)$) && -n "$appconnect_time" && "$appconnect_time" != "0.000000" ]]; then
        awk -v t="$appconnect_time" 'BEGIN { printf "%.0f", t * 1000 }'
        return 0
    fi
    return 1
}

auto_select_best_sni() {
    echo -e "${CYAN}[1/3] 正在获取 VPS 归属地理信息...${PLAIN}"
    local ip_info
    ip_info=$(curl -s4m 5 "http://ip-api.com/json/?fields=status,country,city,query" 2>/dev/null || true)
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
        curl -s4m 10 "$raw_url" -o "$json_cache" 2>/dev/null || curl -s4m 10 "$cdn_url" -o "$json_cache" 2>/dev/null || true
    fi

    local candidate_domains=()
    if [[ -s "$json_cache" ]]; then
        while IFS= read -r line; do
            line=$(echo "$line" | tr -d '\r\n[:space:]')
            [[ -n "$line" ]] && candidate_domains+=("$line")
        done < <(jq -r --arg c "$country" '.[] | select(.country == $c) | .domains[]?' "$json_cache" 2>/dev/null | sort -u)
    fi

    local total=${#candidate_domains[@]}
    echo -e "${GREEN}[✓] 在当地匹配到 ${total} 个大学独立域名${PLAIN}"

    echo -e "${CYAN}[3/3] 正在进行 [防白嫖清洗 + HTTP/2 200 + 本地物理延迟] 综合体检...${PLAIN}"
    local sample_pool=()
    if [[ $total -gt 0 ]]; then
        while IFS= read -r line; do
            [[ -n "$line" ]] && sample_pool+=("$line")
        done < <(printf "%s\n" "${candidate_domains[@]}" | shuf -n 12 2>/dev/null || printf "%s\n" "${candidate_domains[@]}" | head -n 12)
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
        SELECTED_SNI=$(echo "$best_sni" | tr -d '\r\n[:space:]')
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

choose_sni_workflow() {
    echo -e "\n--------------------------------------------------------"
    echo -e " 请选择伪装域名 (SNI) 匹配策略:"
    echo -e " ${GREEN}1.${PLAIN} \033[1;32m智能优选当地独立高校\033[0m (推荐: 极客防封, 自动排查CDN与白嫖风险, 失败自动降级大厂)"
    echo -e " ${GREEN}2.${PLAIN} \033[1;36m精选大厂安全随机\033[0m     (彻底剔除 Cloudflare, 快速稳妥)"
    echo -e " ${GREEN}3.${PLAIN} 自定义输入域名"
    echo -e "--------------------------------------------------------"
    read -rp "请输入选项 [1-3, 默认 1]: " sni_opt
    sni_opt=${sni_opt:-1}

    case "$sni_opt" in
        1) auto_select_best_sni ;;
        2) pick_safe_bigtech_sni ;;
        3)
            while true; do
                read -rp "请输入你想伪装的合法域名 (例如 www.apple.com): " custom_domain
                if [[ -z "$custom_domain" ]]; then
                    echo -e "${RED}域名不能为空！${PLAIN}"
                    continue
                fi
                echo -e "${CYAN}[+] 正在体检该域名的 TLS 1.3 / HTTP/2 连通性...${PLAIN}"
                local lat
                lat=$(check_candidate_quality "$custom_domain" 2>/dev/null || true)
                if [[ -n "$lat" && "$lat" != "0" ]]; then
                    echo -e "${GREEN}[✓] 域名校验通过！(握手延迟: ${lat} ms)${PLAIN}"
                    SELECTED_SNI="$custom_domain"
                    break
                else
                    echo -e "${YELLOW}[警告] 目标域名不支持 TLS 1.3 / HTTP/2 或无法访问！${PLAIN}"
                    read -rp "确定仍要强行使用吗？[y/N]: " force_use
                    if [[ "$force_use" =~ ^[Yy]$ ]]; then
                        SELECTED_SNI="$custom_domain"
                        break
                    fi
                fi
            done
            ;;
        *) auto_select_best_sni ;;
    esac
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

    choose_sni_workflow

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

    # 清理所有变量防控制字符/换行符注入
    port=$(echo "$port" | tr -d '\r\n[:space:]')
    uuid=$(echo "$uuid" | tr -d '\r\n[:space:]')
    private_key=$(echo "$private_key" | tr -d '\r\n[:space:]')
    public_key=$(echo "$public_key" | tr -d '\r\n[:space:]')
    short_id=$(echo "$short_id" | tr -d '\r\n[:space:]')
    SELECTED_SNI=$(echo "$SELECTED_SNI" | tr -d '\r\n[:space:]')

    local tag="vless-reality-${port}"
    local inbound_json
    inbound_json=$(jq -n \
        --arg tag "$tag" \
        --argjson port "$port" \
        --arg uuid "$uuid" \
        --arg sni "$SELECTED_SNI" \
        --arg priv "$private_key" \
        --arg sid "$short_id" \
        '{
            type: "vless",
            tag: $tag,
            listen: "::",
            listen_port: $port,
            users: [{uuid: $uuid, flow: "xtls-rprx-vision"}],
            tls: {
                enabled: true,
                server_name: $sni,
                reality: {
                    enabled: true,
                    handshake: {server: $sni, server_port: 443},
                    private_key: $priv,
                    short_id: [$sid]
                }
            }
        }')

    get_public_ip
    local share_link="vless://${uuid}@${VPS_IP}:${port}?security=reality&flow=xtls-rprx-vision&pbk=${public_key}&sni=${SELECTED_SNI}&sid=${short_id}&type=tcp&fp=chrome#Reality-${SELECTED_SNI}-${port}"

    local node_meta
    node_meta=$(jq -n \
        --arg tag "$tag" \
        --arg type "vless-reality" \
        --argjson port "$port" \
        --arg uuid "$uuid" \
        --arg sni "$SELECTED_SNI" \
        --arg pbk "$public_key" \
        --arg priv "$private_key" \
        --arg sid "$short_id" \
        --arg link "$share_link" \
        '{tag: $tag, type: $type, port: $port, uuid: $uuid, sni: $sni, public_key: $pbk, private_key: $priv, short_id: $sid, link: $link}')

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

    port=$(echo "$port" | tr -d '\r\n[:space:]')
    password=$(echo "$password" | tr -d '\r\n[:space:]')
    local tag="hysteria2-${port}"

    local inbound_json
    inbound_json=$(jq -n \
        --arg tag "$tag" \
        --argjson port "$port" \
        --arg pwd "$password" \
        --arg cert "$CERT_FILE" \
        --arg key "$KEY_FILE" \
        '{
            type: "hysteria2",
            tag: $tag,
            listen: "::",
            listen_port: $port,
            users: [{password: $pwd}],
            tls: {
                enabled: true,
                certificate_path: $cert,
                key_path: $key
            }
        }')

    get_public_ip
    local share_link="hysteria2://${password}@${VPS_IP}:${port}?insecure=1&sni=bing.com#Hy2-${port}"

    local node_meta
    node_meta=$(jq -n \
        --arg tag "$tag" \
        --arg type "hysteria2" \
        --argjson port "$port" \
        --arg pwd "$password" \
        --arg sni "bing.com" \
        --arg link "$share_link" \
        '{tag: $tag, type: $type, port: $port, password: $pwd, sni: $sni, link: $link}')

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

    port=$(echo "$port" | tr -d '\r\n[:space:]')
    uuid=$(echo "$uuid" | tr -d '\r\n[:space:]')
    password=$(echo "$password" | tr -d '\r\n[:space:]')
    local tag="tuic-${port}"

    local inbound_json
    inbound_json=$(jq -n \
        --arg tag "$tag" \
        --argjson port "$port" \
        --arg uuid "$uuid" \
        --arg pwd "$password" \
        --arg cert "$CERT_FILE" \
        --arg key "$KEY_FILE" \
        '{
            type: "tuic",
            tag: $tag,
            listen: "::",
            listen_port: $port,
            users: [{uuid: $uuid, password: $pwd}],
            congestion_control: "bbr",
            tls: {
                enabled: true,
                server_name: "bing.com",
                alpn: ["h3"],
                certificate_path: $cert,
                key_path: $key
            }
        }')

    get_public_ip
    local share_link="tuic://${uuid}:${password}@${VPS_IP}:${port}?congestion_control=bbr&alpn=h3&allow_insecure=1&sni=bing.com#TUIC-${port}"

    local node_meta
    node_meta=$(jq -n \
        --arg tag "$tag" \
        --arg type "tuic" \
        --argjson port "$port" \
        --arg uuid "$uuid" \
        --arg pwd "$password" \
        --arg link "$share_link" \
        '{tag: $tag, type: $type, port: $port, uuid: $uuid, password: $pwd, link: $link}')

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

    port=$(echo "$port" | tr -d '\r\n[:space:]')
    password=$(echo "$password" | tr -d '\r\n[:space:]')
    local tag="ss-${port}"
    local method="2022-blake3-aes-128-gcm"

    local inbound_json
    inbound_json=$(jq -n \
        --arg tag "$tag" \
        --argjson port "$port" \
        --arg method "$method" \
        --arg pwd "$password" \
        '{
            type: "shadowsocks",
            tag: $tag,
            listen: "::",
            listen_port: $port,
            network: "tcp,udp",
            method: $method,
            password: $pwd
        }')

    get_public_ip
    local creds
    creds=$(echo -n "${method}:${password}" | base64 2>/dev/null | tr -d '\r\n')
    local share_link="ss://${creds}@${VPS_IP}:${port}#SS-${port}"

    local node_meta
    node_meta=$(jq -n \
        --arg tag "$tag" \
        --arg type "shadowsocks-2022" \
        --argjson port "$port" \
        --arg method "$method" \
        --arg pwd "$password" \
        --arg link "$share_link" \
        '{tag: $tag, type: $type, port: $port, method: $method, password: $pwd, link: $link}')

    apply_inbound_config "$tag" "$inbound_json" "$node_meta"
}

open_port() {
    local p="$1"
    [[ -z "$p" ]] && return 0
    if command -v ufw &>/dev/null; then
        ufw allow "$p" >/dev/null 2>&1 || true
    fi
    if command -v iptables &>/dev/null; then
        iptables -I INPUT -p tcp --dport "$p" -j ACCEPT 2>/dev/null || true
        iptables -I INPUT -p udp --dport "$p" -j ACCEPT 2>/dev/null || true
    fi
}

# 写入配置与重启服务
apply_inbound_config() {
    local tag="$1"
    local inbound_json="$2"
    local node_meta="$3"

    if [[ -z "$tag" || -z "$inbound_json" || -z "$node_meta" ]]; then
        echo -e "${RED}[错误] 入站配置生成失败，无法写入配置！${PLAIN}"
        return 1
    fi

    ensure_valid_json_file "$CONF_FILE" '{"log":{"level":"warn","timestamp":true},"inbounds":[],"outbounds":[{"type":"direct","tag":"direct"}]}' "object"
    ensure_valid_json_file "$NODES_FILE" "[]" "array"

    local p
    p=$(echo "$node_meta" | jq -r '.port // empty')
    p=${p:-0}

    # 步骤 1：必须先更新/登记 nodes.json 元数据白名单！
    # 彻底解决“先杀新节点再登记元数据”的时序颠倒 Bug
    jq --arg t "$tag" --arg p "$p" '[(. // [])[]? | select(.tag != $t and (.port | tostring) != $p)]' "$NODES_FILE" > "${NODES_FILE}.tmp" 2>/dev/null
    if [[ -s "${NODES_FILE}.tmp" ]]; then
        mv -f "${NODES_FILE}.tmp" "$NODES_FILE"
    fi

    jq --argjson new_node "$node_meta" '. = ((. // []) + [$new_node])' "$NODES_FILE" > "${NODES_FILE}.tmp" 2>/dev/null
    if [[ -s "${NODES_FILE}.tmp" ]]; then
        mv -f "${NODES_FILE}.tmp" "$NODES_FILE"
    fi

    # 步骤 2：将新入站规则写入核心配置 config.json
    echo -e "${CYAN}[+] 正在将入站规则写入核心配置...${PLAIN}"
    # 移除同名 tag 或相同端口的旧入站
    jq --arg t "$tag" --arg p "$p" '.inbounds = [(.inbounds // [])[]? | select(.tag != $t and (.listen_port | tostring) != $p)]' "$CONF_FILE" > "${CONF_FILE}.tmp" 2>/dev/null
    if [[ -s "${CONF_FILE}.tmp" ]]; then
        mv -f "${CONF_FILE}.tmp" "$CONF_FILE"
    fi

    # 追加新入站
    jq --argjson new_in "$inbound_json" '.inbounds = ((.inbounds // []) + [$new_in])' "$CONF_FILE" > "${CONF_FILE}.tmp" 2>/dev/null
    if [[ -s "${CONF_FILE}.tmp" ]]; then
        mv -f "${CONF_FILE}.tmp" "$CONF_FILE"
    fi

    # 步骤 3：严格清理与端口去重（此时 nodes.json 白名单中已有新 tag，绝不会误杀！）
    sync_and_clean_inbounds

    # 步骤 4：核心语法检测与防御性回滚
    if ! "$BIN_PATH" check -c "$CONF_FILE"; then
        echo -e "${RED}[错误] sing-box 语法校验失败！正在回滚...${PLAIN}"
        jq --arg t "$tag" '[(. // [])[]? | select(.tag != $t)]' "$NODES_FILE" > "${NODES_FILE}.tmp" 2>/dev/null && mv -f "${NODES_FILE}.tmp" "$NODES_FILE"
        return 1
    fi

    # 步骤 5：释放孤儿端口、放行防火墙并拉起服务
    fuser -k "${p}/tcp" 2>/dev/null || true
    fuser -k "${p}/udp" 2>/dev/null || true

    open_port "$p"
    systemctl daemon-reload
    systemctl enable --now "${APP_NAME}" >/dev/null 2>&1
    systemctl restart "${APP_NAME}"
    echo -e "${GREEN}[✓] 节点 [${tag}] 已成功添加并激活！服务已自动重启并在后台常驻！${PLAIN}"
    print_single_node "$tag"
}

# -------------------------------------------------------------
# 4. 节点修改与维护
# -------------------------------------------------------------
modify_node() {
    local count
    count=$(jq 'length' "$NODES_FILE" 2>/dev/null || echo 0)
    if [[ "$count" -eq 0 ]]; then
        echo -e "${YELLOW}[!] 当前未配置任何节点，无法修改！${PLAIN}"
        return
    fi

    echo -e "\n${CYAN}请选择要修改的节点编号:${PLAIN}"
    jq -r 'to_entries[] | "  [\(.key + 1)] \(.value.type) (端口: \(.value.port) | tag: \(.value.tag))"' "$NODES_FILE"
    echo -e "  [0] 返回上一级"
    read -rp "请输入选项 [0-${count}]: " idx

    [[ "$idx" == "0" ]] && return
    if ! [[ "$idx" =~ ^[0-9]+$ ]] || (( idx < 1 || idx > count )); then
        echo -e "${RED}[错误] 无效的编号！${PLAIN}"
        return
    fi

    local real_idx=$((idx - 1))
    local target_tag
    target_tag=$(jq -r --argjson i "$real_idx" '.[$i].tag' "$NODES_FILE")
    local node_type
    node_type=$(jq -r --argjson i "$real_idx" '.[$i].type' "$NODES_FILE")
    local current_port
    current_port=$(jq -r --argjson i "$real_idx" '.[$i].port' "$NODES_FILE")

    echo -e "\n--------------------------------------------------------"
    echo -e " 正在修改节点: \033[1;33m${target_tag}\033[0m (${node_type})"
    echo -e " ${GREEN}1.${PLAIN} 修改监听端口 (当前: ${current_port})"
    if [[ "$node_type" == "vless-reality" ]]; then
        local current_sni=$(jq -r --argjson i "$real_idx" '.[$i].sni' "$NODES_FILE")
        echo -e " ${GREEN}2.${PLAIN} 更换伪装域名 SNI (当前: ${current_sni})"
        echo -e " ${GREEN}3.${PLAIN} 刷新/重新生成 UUID"
    elif [[ "$node_type" == "hysteria2" || "$node_type" == "tuic" ]]; then
        echo -e " ${GREEN}2.${PLAIN} 刷新/重新生成认证密码"
    elif [[ "$node_type" == "shadowsocks-2022" ]]; then
        echo -e " ${GREEN}2.${PLAIN} 刷新/重新生成 2022 密钥"
    fi
    echo -e " ${GREEN}0.${PLAIN} 返回上一级"
    echo -e "--------------------------------------------------------"
    read -rp "请选择修改项: " m_opt

    case "$m_opt" in
        1)
            read -rp "请输入新端口号 (1-65535): " new_p
            if [[ "$new_p" -gt 0 && "$new_p" -le 65535 ]]; then
                jq --arg t "$target_tag" --argjson p "$new_p" '(.inbounds[] | select(.tag == $t)).listen_port = $p' "$CONF_FILE" > "${CONF_FILE}.tmp" && mv "${CONF_FILE}.tmp" "$CONF_FILE"
                get_public_ip
                local old_link
                old_link=$(jq -r --arg t "$target_tag" '.[] | select(.tag == $t) | .link' "$NODES_FILE")
                local new_link
                new_link=$(echo "$old_link" | sed -E "s/:${current_port}(\/|\?|#)/:${new_p}\1/")
                jq --arg t "$target_tag" --argjson p "$new_p" --arg l "$new_link" '(.[] | select(.tag == $t)).port = $p | (.[] | select(.tag == $t)).link = $l' "$NODES_FILE" > "${NODES_FILE}.tmp" && mv "${NODES_FILE}.tmp" "$NODES_FILE"

                if "$BIN_PATH" check -c "$CONF_FILE"; then
                    systemctl restart "${APP_NAME}"
                    echo -e "${GREEN}[✓] 端口已成功修改为: ${new_p}${PLAIN}"
                    print_single_node "$target_tag"
                else
                    echo -e "${RED}[错误] 配置校验失败，已放弃修改！${PLAIN}"
                fi
            else
                echo -e "${RED}端口无效！${PLAIN}"
            fi
            ;;
        2)
            if [[ "$node_type" == "vless-reality" ]]; then
                choose_sni_workflow
                jq --arg t "$target_tag" --arg s "$SELECTED_SNI" '(.inbounds[] | select(.tag == $t)).tls.server_name = $s | (.inbounds[] | select(.tag == $t)).tls.reality.handshake.server = $s' "$CONF_FILE" > "${CONF_FILE}.tmp" && mv "${CONF_FILE}.tmp" "$CONF_FILE"
                local uuid pbk sid port
                uuid=$(jq -r --arg t "$target_tag" '.[] | select(.tag == $t) | .uuid' "$NODES_FILE")
                pbk=$(jq -r --arg t "$target_tag" '.[] | select(.tag == $t) | .public_key' "$NODES_FILE")
                sid=$(jq -r --arg t "$target_tag" '.[] | select(.tag == $t) | .short_id' "$NODES_FILE")
                port=$(jq -r --arg t "$target_tag" '.[] | select(.tag == $t) | .port' "$NODES_FILE")
                get_public_ip
                local new_link="vless://${uuid}@${VPS_IP}:${port}?security=reality&flow=xtls-rprx-vision&pbk=${pbk}&sni=${SELECTED_SNI}&sid=${sid}&type=tcp&fp=chrome#Reality-${SELECTED_SNI}-${port}"
                jq --arg t "$target_tag" --arg s "$SELECTED_SNI" --arg l "$new_link" '(.[] | select(.tag == $t)).sni = $s | (.[] | select(.tag == $t)).link = $l' "$NODES_FILE" > "${NODES_FILE}.tmp" && mv "${NODES_FILE}.tmp" "$NODES_FILE"

                systemctl restart "${APP_NAME}"
                echo -e "${GREEN}[✓] 伪装域名 SNI 已成功更换为: ${SELECTED_SNI}${PLAIN}"
                print_single_node "$target_tag"
            elif [[ "$node_type" == "hysteria2" ]]; then
                local new_pwd=$(openssl rand -hex 16)
                jq --arg t "$target_tag" --arg p "$new_pwd" '(.inbounds[] | select(.tag == $t)).users[0].password = $p' "$CONF_FILE" > "${CONF_FILE}.tmp" && mv "${CONF_FILE}.tmp" "$CONF_FILE"
                get_public_ip
                local new_link="hysteria2://${new_pwd}@${VPS_IP}:${current_port}?insecure=1&sni=bing.com#Hy2-${current_port}"
                jq --arg t "$target_tag" --arg p "$new_pwd" --arg l "$new_link" '(.[] | select(.tag == $t)).password = $p | (.[] | select(.tag == $t)).link = $l' "$NODES_FILE" > "${NODES_FILE}.tmp" && mv "${NODES_FILE}.tmp" "$NODES_FILE"
                systemctl restart "${APP_NAME}"
                echo -e "${GREEN}[✓] Hysteria 2 认证密码已更新！${PLAIN}"
                print_single_node "$target_tag"
            elif [[ "$node_type" == "tuic" ]]; then
                local new_pwd=$(openssl rand -hex 12)
                jq --arg t "$target_tag" --arg p "$new_pwd" '(.inbounds[] | select(.tag == $t)).users[0].password = $p' "$CONF_FILE" > "${CONF_FILE}.tmp" && mv "${CONF_FILE}.tmp" "$CONF_FILE"
                local uuid=$(jq -r --arg t "$target_tag" '.[] | select(.tag == $t) | .uuid' "$NODES_FILE")
                get_public_ip
                local new_link="tuic://${uuid}:${new_pwd}@${VPS_IP}:${current_port}?congestion_control=bbr&alpn=h3&allow_insecure=1&sni=bing.com#TUIC-${current_port}"
                jq --arg t "$target_tag" --arg p "$new_pwd" --arg l "$new_link" '(.[] | select(.tag == $t)).password = $p | (.[] | select(.tag == $t)).link = $l' "$NODES_FILE" > "${NODES_FILE}.tmp" && mv "${NODES_FILE}.tmp" "$NODES_FILE"
                systemctl restart "${APP_NAME}"
                echo -e "${GREEN}[✓] TUIC 密码已更新！${PLAIN}"
                print_single_node "$target_tag"
            elif [[ "$node_type" == "shadowsocks-2022" ]]; then
                local new_pwd=$(openssl rand -base64 16)
                jq --arg t "$target_tag" --arg p "$new_pwd" '(.inbounds[] | select(.tag == $t)).password = $p' "$CONF_FILE" > "${CONF_FILE}.tmp" && mv "${CONF_FILE}.tmp" "$CONF_FILE"
                get_public_ip
                local creds=$(echo -n "2022-blake3-aes-128-gcm:${new_pwd}" | base64 | tr -d '\n')
                local new_link="ss://${creds}@${VPS_IP}:${current_port}#SS-${current_port}"
                jq --arg t "$target_tag" --arg p "$new_pwd" --arg l "$new_link" '(.[] | select(.tag == $t)).password = $p | (.[] | select(.tag == $t)).link = $l' "$NODES_FILE" > "${NODES_FILE}.tmp" && mv "${NODES_FILE}.tmp" "$NODES_FILE"
                systemctl restart "${APP_NAME}"
                echo -e "${GREEN}[✓] Shadowsocks 2022 密钥已更新！${PLAIN}"
                print_single_node "$target_tag"
            fi
            ;;
        3)
            if [[ "$node_type" == "vless-reality" ]]; then
                local new_uuid
                new_uuid=$("${BIN_PATH}" generate uuid)
                jq --arg t "$target_tag" --arg u "$new_uuid" '(.inbounds[] | select(.tag == $t)).users[0].uuid = $u' "$CONF_FILE" > "${CONF_FILE}.tmp" && mv "${CONF_FILE}.tmp" "$CONF_FILE"
                local pbk sid port sni
                pbk=$(jq -r --arg t "$target_tag" '.[] | select(.tag == $t) | .public_key' "$NODES_FILE")
                sid=$(jq -r --arg t "$target_tag" '.[] | select(.tag == $t) | .short_id' "$NODES_FILE")
                port=$(jq -r --arg t "$target_tag" '.[] | select(.tag == $t) | .port' "$NODES_FILE")
                sni=$(jq -r --arg t "$target_tag" '.[] | select(.tag == $t) | .sni' "$NODES_FILE")
                get_public_ip
                local new_link="vless://${new_uuid}@${VPS_IP}:${port}?security=reality&flow=xtls-rprx-vision&pbk=${pbk}&sni=${sni}&sid=${sid}&type=tcp&fp=chrome#Reality-${sni}-${port}"
                jq --arg t "$target_tag" --arg u "$new_uuid" --arg l "$new_link" '(.[] | select(.tag == $t)).uuid = $u | (.[] | select(.tag == $t)).link = $l' "$NODES_FILE" > "${NODES_FILE}.tmp" && mv "${NODES_FILE}.tmp" "$NODES_FILE"
                systemctl restart "${APP_NAME}"
                echo -e "${GREEN}[✓] UUID 已成功更新为: ${new_uuid}${PLAIN}"
                print_single_node "$target_tag"
            fi
            ;;
        0) return ;;
        *) echo -e "${RED}无效选项！${PLAIN}" ;;
    esac
}

# -------------------------------------------------------------
# 5. 节点删除与列表管理
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
    count=$(jq 'length' "$NODES_FILE" 2>/dev/null)
    count=${count:-0}
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
# 7. 全局 CLI 快捷键注册 (独立命令: sbox，不与 233boy sb 冲突)
# -------------------------------------------------------------
install_cli_shortcut() {
    # 保持 233boy 原汁原味：若之前有备份的 sb-233，自动恢复回 /usr/local/bin/sb
    if [[ -f "/usr/local/bin/sb-233" ]]; then
        mv -f "/usr/local/bin/sb-233" "/usr/local/bin/sb" 2>/dev/null || true
        chmod +x "/usr/local/bin/sb" 2>/dev/null || true
    fi

    # 本增强版独立注册专属快捷指令: sbox
    local target="$SCRIPT_INSTALL_PATH"
    if [[ ! -f "$0" || "$0" == /dev/fd/* || "$0" == /proc/* || "$0" == "bash" ]]; then
        local github_raw="https://raw.githubusercontent.com/shangusl/sing-box-boom/main/install.sh"
        local proxy_script="https://ghfast.top/https://raw.githubusercontent.com/shangusl/sing-box-boom/main/install.sh"
        local cdn_script="https://cdn.jsdelivr.net/gh/shangusl/sing-box-boom@main/install.sh"
        curl -fsSL "$github_raw" -o "$target" 2>/dev/null || \
        curl -fsSL "$proxy_script" -o "$target" 2>/dev/null || \
        curl -fsSL "$cdn_script" -o "$target" 2>/dev/null || \
        wget -qO "$target" "$github_raw" 2>/dev/null || \
        wget -qO "$target" "$proxy_script" 2>/dev/null || true
    else
        cp -f "$0" "$target" 2>/dev/null || true
    fi
    chmod +x "$target" 2>/dev/null || true
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
# 9. 一键在线升级模块 (脚本自更新 & 核心版本更新)
# -------------------------------------------------------------
update_self() {
    echo -e "${CYAN}[+] 正在检索 GitHub 原生最新脚本版本...${PLAIN}"
    local github_raw="https://raw.githubusercontent.com/shangusl/sing-box-boom/main/install.sh"
    local proxy_script="https://ghfast.top/https://raw.githubusercontent.com/shangusl/sing-box-boom/main/install.sh"
    local cdn_script="https://cdn.jsdelivr.net/gh/shangusl/sing-box-boom@main/install.sh"
    local tmp_file="/tmp/sb_latest.sh"

    if curl -fsSL "$github_raw" -o "$tmp_file" 2>/dev/null || \
       curl -fsSL "$proxy_script" -o "$tmp_file" 2>/dev/null || \
       curl -fsSL "$cdn_script" -o "$tmp_file" 2>/dev/null || \
       wget -qO "$tmp_file" "$github_raw" 2>/dev/null || \
       wget -qO "$tmp_file" "$proxy_script" 2>/dev/null; then
        
        # 严格语法校验，避免更新到错误页面
        if bash -n "$tmp_file" &>/dev/null; then
            cp -f "$tmp_file" "$SCRIPT_INSTALL_PATH"
            chmod +x "$SCRIPT_INSTALL_PATH" 2>/dev/null || true
            rm -f "$tmp_file"
            echo -e "${GREEN}[✓] 管理脚本已成功更新至最新版！所有配置与节点完好保留。${PLAIN}"
            sleep 1
            exec "$SCRIPT_INSTALL_PATH"
        else
            echo -e "${RED}[错误] 下载到的脚本校验失败，已放弃更新！${PLAIN}"
            rm -f "$tmp_file"
        fi
    else
        echo -e "${RED}[错误] 网络连接失败，未能获取到最新脚本！${PLAIN}"
    fi
}

update_core() {
    echo -e "${CYAN}[+] 正在检查 sing-box 官方最新发行版...${PLAIN}"
    local current_ver="未知"
    if [[ -f "$BIN_PATH" ]]; then
        current_ver=$("$BIN_PATH" version | head -n 1 | awk '{print $3}')
    fi
    echo -e " 当前运行核心版本: ${YELLOW}${current_ver}${PLAIN}"

    local latest_tag
    latest_tag=$(curl -s4m 5 "https://api.github.com/repos/SagerNet/sing-box/releases/latest" | jq -r '.tag_name // empty' 2>/dev/null || true)
    if [[ -z "$latest_tag" || "$latest_tag" == "null" ]]; then
        echo -e "${RED}[错误] 无法获取 GitHub 最新版本号！${PLAIN}"
        return
    fi
    local version="${latest_tag#v}"

    if [[ "$current_ver" == "$version" || "$current_ver" == "$latest_tag" ]]; then
        echo -e "${GREEN}[✓] 当前已经是最新核心版本 (${current_ver})，无需升级！${PLAIN}"
        return
    fi

    echo -e "${CYAN}[+] 发现新版本: ${GREEN}${latest_tag}${PLAIN}，正在升级...${PLAIN}"
    check_arch
    local download_url="https://github.com/SagerNet/sing-box/releases/download/${latest_tag}/sing-box-${version}-linux-${ARCH}.tar.gz"
    local proxy_url="https://ghfast.top/${download_url}"
    local tmp_tar="/tmp/sing-box-update.tar.gz"

    wget -qO "$tmp_tar" "$download_url" || curl -fsSL "$download_url" -o "$tmp_tar" || \
    wget -qO "$tmp_tar" "$proxy_url" || curl -fsSL "$proxy_url" -o "$tmp_tar"

    tar -zxvf "$tmp_tar" -C /tmp/ >/dev/null
    systemctl stop "${APP_NAME}" 2>/dev/null || true
    cp -f "/tmp/sing-box-${version}-linux-${ARCH}/sing-box" "$BIN_PATH"
    chmod +x "$BIN_PATH"
    rm -rf "/tmp/sing-box"*

    systemctl start "${APP_NAME}" 2>/dev/null || true
    echo -e "${GREEN}[✓] sing-box 核心升级成功！当前版本: ${latest_tag}${PLAIN}"
}

update_menu() {
    echo -e "\n--------------------------------------------------------"
    echo -e " 请选择更新项:"
    echo -e " ${GREEN}1.${PLAIN} \033[1;32m更新管理脚本自身\033[0m (保留所有节点与配置，拉取 GitHub 最新特性)"
    echo -e " ${GREEN}2.${PLAIN} \033[1;36m升级 sing-box 核心\033[0m (更新到官方 GitHub 发布的最新二进制)"
    echo -e " ${GREEN}0.${PLAIN} 返回上一级"
    echo -e "--------------------------------------------------------"
    read -rp "请输入选项 [0-2]: " u_opt

    case "$u_opt" in
        1) update_self ;;
        2) update_core ;;
        0) return ;;
        *) echo -e "${RED}无效选项！${PLAIN}" ;;
    esac
}

# -------------------------------------------------------------
# 10. 交互式主菜单 (全面超越 233boy 体验)
# -------------------------------------------------------------
show_menu() {
    clear
    import_legacy_and_233boy_nodes
    sync_and_clean_inbounds
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
    count=$(jq 'length' "$NODES_FILE" 2>/dev/null)
    count=${count:-0}
    echo -e " 已配置活跃节点总数: ${YELLOW}${count}${PLAIN} 个"
    if [[ "$count" -gt 0 ]]; then
        jq -r 'to_entries[] | "  [\(.key + 1)] \(.value.type) (端口: \(.value.port))"' "$NODES_FILE" 2>/dev/null || true
    fi

    echo -e "--------------------------------------------------------"
    echo -e " ${GREEN}1.${PLAIN} 添加新节点 (VLESS-Reality / Hysteria2 / TUIC / SS)"
    echo -e " ${GREEN}2.${PLAIN} 修改现有节点 (修改端口 / 更换SNI / 刷新凭据)"
    echo -e " ${GREEN}3.${PLAIN} 删除现有节点"
    echo -e " ${GREEN}4.${PLAIN} 查看所有节点连接信息 & 二维码"
    echo -e " ${GREEN}5.${PLAIN} 一键在线更新 (更新脚本自身 / 升级 sing-box 核心)"
    echo -e " ${GREEN}6.${PLAIN} 一键开启系统 BBR 拥塞控制加速"
    echo -e " ${GREEN}7.${PLAIN} 启动服务"
    echo -e " ${GREEN}8.${PLAIN} 停止服务"
    echo -e " ${GREEN}9.${PLAIN} 重启服务"
    echo -e " ${GREEN}10.${PLAIN} 查看实时运行日志 (tail -f)"
    echo -e " ${GREEN}11.${PLAIN} 彻底卸载 sing-box"
    echo -e " ${GREEN}0.${PLAIN} 退出管理"
    echo -e "========================================================"
    read -rp "请输入选项 [0-11]: " opt

    case "$opt" in
        1) menu_add_node ;;
        2) modify_node ;;
        3) delete_node ;;
        4) show_all_nodes ;;
        5) update_menu ;;
        6) enable_bbr ;;
        7) 
            sync_and_clean_inbounds
            systemctl start "${APP_NAME}" && echo -e "${GREEN}服务已启动！${PLAIN}" 
            ;;
        8) 
            systemctl stop "${APP_NAME}" && echo -e "${YELLOW}服务已停止！${PLAIN}" 
            ;;
        9) 
            sync_and_clean_inbounds
            systemctl restart "${APP_NAME}" && echo -e "${GREEN}服务已重启！${PLAIN}" 
            ;;
        10) journalctl -u "${APP_NAME}" -f -n 50 ;;
        11)
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
main() {
    check_root
    install_dependencies
    download_singbox_core
    install_cli_shortcut
    import_legacy_and_233boy_nodes
    sync_and_clean_inbounds

    if [[ $# -gt 0 ]]; then
        case "$1" in
            add) menu_add_node ;;
            modify|change) modify_node ;;
            del) delete_node ;;
            info|list) show_all_nodes ;;
            update) update_menu ;;
            update-sh) update_self ;;
            update-core) update_core ;;
            bbr) enable_bbr ;;
            start) systemctl start "${APP_NAME}" ;;
            stop) systemctl stop "${APP_NAME}" ;;
            restart) systemctl restart "${APP_NAME}" ;;
            status) systemctl status "${APP_NAME}" ;;
            log) journalctl -u "${APP_NAME}" -f -n 50 ;;
            *) echo "用法: sbox [add|modify|del|info|list|update|bbr|start|stop|restart|status|log]" ;;
        esac
    else
        # 初次安装若无节点，引导添加第一个节点
        local current_nodes
        current_nodes=$(jq 'length' "$NODES_FILE" 2>/dev/null)
        current_nodes=${current_nodes:-0}
        if [[ "$current_nodes" -eq 0 ]]; then
            echo -e "${GREEN}首次安装，请添加你的第一个代理节点：${PLAIN}"
            menu_add_node
            echo ""
            read -n 1 -s -r -p "按任意键进入主菜单..."
        fi
        show_menu
    fi
}

main "$@"
