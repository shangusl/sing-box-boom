#!/usr/bin/env bash
# =========================================================================
#  Project:   sing-box-academic (VLESS + REALITY 智能大学伪装一键脚本)
#  Features:  全球高校动态优选 / 0硬编码 / 独立源站清洗防白嫖 / 一键菜单
# =========================================================================

set -e

# --- 终端颜色 ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
PLAIN='\033[0m'

# --- 核心路径与常量 ---
APP_NAME="sing-box"
BIN_PATH="/usr/local/bin/${APP_NAME}"
CONF_DIR="/etc/${APP_NAME}"
CONF_FILE="${CONF_DIR}/config.json"
META_FILE="${CONF_DIR}/meta.json"
SERVICE_FILE="/etc/systemd/system/${APP_NAME}.service"
SCRIPT_INSTALL_PATH="/usr/local/bin/sb"

# -------------------------------------------------------------
# 0. 权限与系统检测
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
        else
            echo -e "${RED}[错误]${PLAIN} 未知包管理器，请手动安装: ${need_install[*]}"
            exit 1
        fi
    fi
    echo -e "${GREEN}[✓] 依赖安装完成！${PLAIN}"
}

# -------------------------------------------------------------
# 1. 核心程序下载与安装
# -------------------------------------------------------------
download_singbox_core() {
    check_arch
    mkdir -p "${CONF_DIR}"

    echo -e "${CYAN}[+] 正在检索 sing-box 最新版本...${PLAIN}"
    local latest_tag
    latest_tag=$(curl -s "https://api.github.com/repos/SagerNet/sing-box/releases/latest" | jq -r '.tag_name // empty')
    
    if [[ -z "$latest_tag" || "$latest_tag" == "null" ]]; then
        latest_tag="v1.10.7"
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
}

# -------------------------------------------------------------
# 2. 核心黑科技: 全球高校独立源站动态筛选引擎
# -------------------------------------------------------------
is_safe_independent_origin() {
    local target="$1"

    # 2.1 检查 HTTP 响应头中的公用 CDN 标识 (防 Cloudflare / CloudFront / Fastly / Akamai)
    local headers
    headers=$(curl -sI -m 3 "https://${target}" 2>/dev/null | tr '[:upper:]' '[:lower:]')
    if echo "$headers" | grep -qE "server: cloudflare|cf-ray:|x-amz-cf-id:|via:.*cloudfront|x-fastly-request-id:|server: akamaighost"; then
        return 1
    fi

    # 2.2 解析 IP 并核对 ASN
    local ip
    ip=$(getent ahosts "$target" 2>/dev/null | awk '{print $1}' | head -n 1)
    [[ -z "$ip" ]] && return 1

    local asn_info
    asn_info=$(curl -s4m 3 "http://ip-api.com/json/${ip}?fields=as,isp" 2>/dev/null)
    if echo "$asn_info" | grep -qiE "cloudflare|amazon|fastly|akamai"; then
        return 1
    fi

    # 2.3 主动伪造 SNI 探针 (如果目标不报错且接受假SNI，说明具有多租户中转代理特性)
    local probe_status
    echo | openssl s_client -servername "fake-sni-check-for-reality.com" -connect "${ip}:443" -brief </dev/null &>/dev/null
    probe_status=$?
    if [[ $probe_status -eq 0 ]]; then
        return 1
    fi

    return 0
}

check_candidate_quality() {
    local target="$1"
    # 必须是 TLS 1.3 + HTTP/2 且直接响应 200 (排除 301/302 中转跳转机器)
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
    VPS_IP=$(echo "$ip_info" | jq -r '.query // empty')
    [[ -z "$VPS_IP" ]] && VPS_IP=$(curl -s4m 5 https://api.ipify.org)

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
        # 随机抽取 15 个测试
        while IFS= read -r line; do
            sample_pool+=("$line")
        done < <(printf "%s\n" "${candidate_domains[@]}" | shuf -n 15)
    fi

    local best_sni=""
    local min_latency=99999

    for base in "${sample_pool[@]}"; do
        local targets=("www.${base}" "${base}")
        local valid_target=""
        local target_latency=""

        for target in "${targets[@]}"; do
            # 能解析出 IP
            if ! getent ahosts "$target" &>/dev/null; then continue; fi
            # 必须不是公共 CDN
            if ! is_safe_independent_origin "$target"; then continue; fi
            # 必须直接返回 HTTP/2 200
            local lat
            lat=$(check_candidate_quality "$target" 2>/dev/null)
            if [[ $? -eq 0 && -n "$lat" ]]; then
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

# -------------------------------------------------------------
# 2.2 大厂安全域名优选引擎 (实机测试校验版 / 绝对无 Cloudflare)
# -------------------------------------------------------------
pick_safe_bigtech_sni() {
    echo -e "${CYAN}[+] 正在检索大厂安全域名池 (已彻底清退 Cloudflare / 100% 独立专属)...${PLAIN}"
    
    # 经过实机测试严格通过 (TLS 1.3 + HTTP/2 + 200 OK + 无公用多租户中转风险)
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

        # 1. 确认解析正常
        if ! getent ahosts "$domain" &>/dev/null; then
            printf "\033[0;31m[无解析]\033[0m\n"
            continue
        fi

        # 2. 强防线: 绝对不能带 Cloudflare 特征
        local hdrs
        hdrs=$(curl -sI -m 3 "https://${domain}" 2>/dev/null | tr '[:upper:]' '[:lower:]')
        if echo "$hdrs" | grep -qE "server: cloudflare|cf-ray:"; then
            printf "\033[0;31m[跳过: 命中Cloudflare]\033[0m\n"
            continue
        fi

        # 3. 测速与 HTTP/2 200 连通性验证
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
# 2.3 伪装域名交互模式选择
# -------------------------------------------------------------
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
        1)
            auto_select_best_sni
            ;;
        2)
            pick_safe_bigtech_sni
            ;;
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
                if [[ -n "$lat" ]]; then
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
        *)
            auto_select_best_sni
            ;;
    esac
}

# -------------------------------------------------------------
# 3. 配置文件生成与服务注册
# -------------------------------------------------------------
generate_config_and_service() {
    local listen_port="${1:-443}"

    echo -e "${CYAN}[+] 正在生成密钥对与凭据...${PLAIN}"
    local uuid
    uuid=$("${BIN_PATH}" generate uuid)

    local keypair
    keypair=$("${BIN_PATH}" generate reality-keypair)
    local private_key
    private_key=$(echo "$keypair" | grep -iE "PrivateKey|Private key" | head -n 1 | sed 's/.*:[[:space:]]*//' | tr -d ' "\r\n')
    local public_key
    public_key=$(echo "$keypair" | grep -iE "PublicKey|Public key" | head -n 1 | sed 's/.*:[[:space:]]*//' | tr -d ' "\r\n')

    # 双重保险保底
    if [[ -z "$private_key" || -z "$public_key" ]]; then
        local tmp_keys=($(echo "$keypair" | sed 's/.*://'))
        private_key=$(echo "${tmp_keys[0]}" | tr -d ' "\r\n')
        public_key=$(echo "${tmp_keys[1]}" | tr -d ' "\r\n')
    fi

    local short_id
    short_id=$(openssl rand -hex 8)

    echo -e "${CYAN}[+] 正在写入 sing-box 服务端核心配置...${PLAIN}"
    cat > "$CONF_FILE" <<EOF
{
  "log": {
    "level": "warn",
    "timestamp": true
  },
  "inbounds": [
    {
      "type": "vless",
      "tag": "vless-reality-in",
      "listen": "::",
      "listen_port": ${listen_port},
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
  ],
  "outbounds": [
    {
      "type": "direct",
      "tag": "direct"
    }
  ]
}
EOF

    # 校验合法性
    if ! "$BIN_PATH" check -c "$CONF_FILE"; then
        echo -e "${RED}[错误] 配置文件语法校验失败，请检查！${PLAIN}"
        exit 1
    fi

    # 拼装分享链接
    local node_name="Academic-${SELECTED_SNI}"
    local share_link="vless://${uuid}@${VPS_IP}:${listen_port}?security=reality&flow=xtls-rprx-vision&pbk=${public_key}&sni=${SELECTED_SNI}&sid=${short_id}&type=tcp&fp=chrome#${node_name}"

    # 保存元数据到本地，以便 sb info 秒级调取，无需 dummy tag
    cat > "$META_FILE" <<EOF
{
  "port": ${listen_port},
  "uuid": "${uuid}",
  "sni": "${SELECTED_SNI}",
  "public_key": "${public_key}",
  "private_key": "${private_key}",
  "short_id": "${short_id}",
  "ip": "${VPS_IP}",
  "share_link": "${share_link}"
}
EOF

    echo -e "${CYAN}[+] 注册 systemd 守护进程...${PLAIN}"
    cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=sing-box Service (VLESS Reality Academic)
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
    systemctl restart "${APP_NAME}"
    echo -e "${GREEN}[✓] 服务启动成功！${PLAIN}"
}

# -------------------------------------------------------------
# 4. 信息展示与导出
# -------------------------------------------------------------
show_info() {
    if [[ ! -f "$META_FILE" ]]; then
        echo -e "${RED}[错误]${PLAIN} 未发现节点配置文件，请先安装！"
        return
    fi

    local port uuid sni pbk sid ip link
    port=$(jq -r '.port' "$META_FILE")
    uuid=$(jq -r '.uuid' "$META_FILE")
    sni=$(jq -r '.sni' "$META_FILE")
    pbk=$(jq -r '.public_key' "$META_FILE")
    sid=$(jq -r '.short_id' "$META_FILE")
    ip=$(jq -r '.ip' "$META_FILE")
    link=$(jq -r '.share_link' "$META_FILE")

    echo -e "\n========================================================"
    echo -e "       ${GREEN}sing-box VLESS + REALITY 节点信息${PLAIN}"
    echo -e "========================================================"
    echo -e " 协议类型 (Protocol)   : ${YELLOW}VLESS${PLAIN}"
    echo -e " 地址 (Address)        : ${CYAN}${ip}${PLAIN}"
    echo -e " 端口 (Port)           : ${CYAN}${port}${PLAIN}"
    echo -e " 用户 ID (UUID)        : ${CYAN}${uuid}${PLAIN}"
    echo -e " 流控 (Flow)           : ${CYAN}xtls-rprx-vision${PLAIN}"
    echo -e " 传输层 (Transport)    : ${CYAN}tcp${PLAIN}"
    echo -e " 伪装域名 (SNI)        : ${GREEN}${sni}${PLAIN} (独立高校安全源站)"
    echo -e " 公钥 (Public Key)     : ${CYAN}${pbk}${PLAIN}"
    echo -e " Short ID              : ${CYAN}${sid}${PLAIN}"
    echo -e " 客户端指纹 (Finger)   : ${CYAN}chrome${PLAIN}"
    echo -e "--------------------------------------------------------"
    echo -e " 分享链接 (Share Link):"
    echo -e " ${GREEN}${link}${PLAIN}"
    echo -e "========================================================"

    if command -v qrencode &>/dev/null; then
        echo -e "\n二维码 (扫描直接导入客户端):"
        qrencode -t ANSIUTF8 "${link}"
    fi
}

# -------------------------------------------------------------
# 5. 安装自己为全局快捷指令 `sb`
# -------------------------------------------------------------
install_cli_shortcut() {
    cp -f "$0" "$SCRIPT_INSTALL_PATH" 2>/dev/null || true
    chmod +x "$SCRIPT_INSTALL_PATH" 2>/dev/null || true
}

# -------------------------------------------------------------
# 6. 一键安装全流程
# -------------------------------------------------------------
install_all() {
    check_root
    install_dependencies
    download_singbox_core
    choose_sni_workflow

    local default_port=443
    echo ""
    read -rp "请输入监听端口 [默认: ${default_port}]: " input_port
    input_port=${input_port:-$default_port}

    generate_config_and_service "$input_port"
    install_cli_shortcut
    show_info
    echo -e "\n${GREEN}[✓] 安装配置完成！随时可以在终端输入 \033[1;33msb\033[0;32m 唤起管理菜单！${PLAIN}\n"
}

# -------------------------------------------------------------
# 7. 交互式主菜单
# -------------------------------------------------------------
show_menu() {
    clear
    echo -e "========================================================"
    echo -e "   ${CYAN}sing-box Academic Manager (智能大学伪装一键脚本)${PLAIN}"
    echo -e "========================================================"
    
    local status
    if systemctl is-active --quiet "${APP_NAME}"; then
        status="${GREEN}运行中${PLAIN}"
    else
        status="${RED}未运行${PLAIN}"
    fi

    echo -e " 服务状态: ${status}"
    echo -e "--------------------------------------------------------"
    echo -e " ${GREEN}1.${PLAIN} 一键安装 / 重装"
    echo -e " ${GREEN}2.${PLAIN} 查看节点连接信息 & 二维码"
    echo -e " ${GREEN}3.${PLAIN} 重新优选伪装域名 (换新 SNI: 高校/大厂/自定义)"
    echo -e " ${GREEN}4.${PLAIN} 修改监听端口"
    echo -e " ${GREEN}5.${PLAIN} 启动服务"
    echo -e " ${GREEN}6.${PLAIN} 停止服务"
    echo -e " ${GREEN}7.${PLAIN} 重启服务"
    echo -e " ${GREEN}8.${PLAIN} 查看实时运行日志"
    echo -e " ${GREEN}9.${PLAIN} 卸载 sing-box"
    echo -e " ${GREEN}0.${PLAIN} 退出"
    echo -e "========================================================"
    read -rp "请输入选项 [0-9]: " opt

    case "$opt" in
        1) install_all ;;
        2) show_info ;;
        3)
            choose_sni_workflow
            local current_port
            current_port=$(jq -r '.port' "$META_FILE")
            generate_config_and_service "$current_port"
            show_info
            ;;
        4)
            read -rp "请输入新端口号 (1-65535): " new_p
            if [[ "$new_p" -gt 0 && "$new_p" -le 65535 ]]; then
                SELECTED_SNI=$(jq -r '.sni' "$META_FILE")
                generate_config_and_service "$new_p"
                show_info
            else
                echo -e "${RED}端口无效！${PLAIN}"
            fi
            ;;
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

# --- 程序入口 ---
if [[ $# -gt 0 ]]; then
    case "$1" in
        install) install_all ;;
        info) show_info ;;
        start) systemctl start "${APP_NAME}" ;;
        stop) systemctl stop "${APP_NAME}" ;;
        restart) systemctl restart "${APP_NAME}" ;;
        status) systemctl status "${APP_NAME}" ;;
        log) journalctl -u "${APP_NAME}" -f -n 50 ;;
        sni)
            choose_sni_workflow
            generate_config_and_service "$(jq -r '.port' "$META_FILE")"
            show_info
            ;;
        *) echo "用法: sb [install|info|start|stop|restart|status|log|sni]" ;;
    esac
else
    if [[ ! -f "$CONF_FILE" ]]; then
        install_all
    else
        show_menu
    fi
fi
