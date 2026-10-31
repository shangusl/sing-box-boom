#!/usr/bin/env bash
# =========================================================================
#  Project:   Reality SNI Scout (VLESS-Reality 极客级伪装域名智能雷达)
#  Author:    shangusl
#  Features:  TLS 1.3 / HTTP/2 握手检测 / 纯净独立源站排查 (彻底清退 CDN) /
#             VPS 地理同城高校检索 / 握手物理延迟多维测速与综合打分
# =========================================================================

# --- 终端高饱和配色 ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
CYAN='\033[0;36m'
BOLD='\033[1m'
PLAIN='\033[0m'

# --- 依赖检测与自动安装 ---
check_deps() {
    local missing=()
    for cmd in curl openssl jq; do
        if ! command -v "$cmd" &>/dev/null; then
            missing+=("$cmd")
        fi
    done

    if [[ ${#missing[@]} -gt 0 ]]; then
        echo -e "${CYAN}[+] 正在安装必需测试工具: ${missing[*]}...${PLAIN}"
        if command -v apt-get &>/dev/null; then
            apt-get update -y >/dev/null 2>&1 && apt-get install -y "${missing[@]}" >/dev/null 2>&1
        elif command -v yum &>/dev/null; then
            yum install -y "${missing[@]}" >/dev/null 2>&1
        elif command -v dnf &>/dev/null; then
            dnf install -y "${missing[@]}" >/dev/null 2>&1
        elif command -v apk &>/dev/null; then
            apk add --no-cache "${missing[@]}" >/dev/null 2>&1
        fi
    fi
}

# --- 获取本机地理信息 ---
get_vps_geo() {
    echo -e "${CYAN}[1/3] 正在探测 VPS 出口公网 IP 及地理位置...${PLAIN}"
    local ip_json
    ip_json=$(curl -s4m 5 "http://ip-api.com/json/?fields=status,country,countryCode,city,query,org,as" 2>/dev/null || true)
    
    if command -v jq &>/dev/null; then
        VPS_IP=$(echo "$ip_json" | jq -r '.query // empty')
        VPS_COUNTRY=$(echo "$ip_json" | jq -r '.country // "United States"')
        VPS_CODE=$(echo "$ip_json" | jq -r '.countryCode // "US"')
        VPS_CITY=$(echo "$ip_json" | jq -r '.city // "Unknown"')
        VPS_ASN=$(echo "$ip_json" | jq -r '.as // "Unknown ASN"')
    else
        VPS_IP=$(echo "$ip_json" | grep -o '"query":"[^"]*' | cut -d'"' -f4)
        VPS_COUNTRY=$(echo "$ip_json" | grep -o '"country":"[^"]*' | cut -d'"' -f4)
        VPS_CODE=$(echo "$ip_json" | grep -o '"countryCode":"[^"]*' | cut -d'"' -f4)
        VPS_CITY=$(echo "$ip_json" | grep -o '"city":"[^"]*' | cut -d'"' -f4)
        VPS_ASN=$(echo "$ip_json" | grep -o '"as":"[^"]*' | cut -d'"' -f4)
    fi

    [[ -z "$VPS_IP" ]] && VPS_IP=$(curl -s4m 4 https://api.ipify.org 2>/dev/null || curl -s4m 4 https://ifconfig.me 2>/dev/null || echo "127.0.0.1")
    VPS_COUNTRY=${VPS_COUNTRY:-"United States"}
    VPS_CITY=${VPS_CITY:-"Unknown"}
    VPS_ASN=${VPS_ASN:-"Unknown ASN"}

    echo -e "${GREEN}[✓] VPS 归属地: ${BOLD}${VPS_COUNTRY} - ${VPS_CITY}${PLAIN} | IP: ${CYAN}${VPS_IP}${PLAIN} | ASN: ${PURPLE}${VPS_ASN}${PLAIN}"
}

# --- 深度体检单个域名 ---
# 返回格式: "状态码|TLS1.3|H2|CDN|延迟ms|评级"
test_single_domain() {
    local domain="$1"
    domain=$(echo "$domain" | tr -d '\r\n[:space:]')
    [[ -z "$domain" ]] && return

    # 1. 检查连通性、HTTP 响应与 CDN 头部
    local curl_header_file="/tmp/sni_hdr_$$.tmp"
    local http_code
    http_code=$(curl -sI -m 3 --connect-timeout 2 "https://${domain}" -D "$curl_header_file" -o /dev/null -w "%{http_code}" 2>/dev/null || echo "000")
    
    if [[ "$http_code" == "000" ]]; then
        rm -f "$curl_header_file"
        echo "DOWN|否|否|连接失败|999|不可用 (连接超时或无法解析)"
        return
    fi
    
    local headers_lower=""
    if [[ -f "$curl_header_file" ]]; then
        headers_lower=$(cat "$curl_header_file" | tr '[:upper:]' '[:lower:]')
        rm -f "$curl_header_file"
    fi

    # 严格 CDN 筛查：彻底排查 Cloudflare 与借道白嫖源
    local cdn_type="独立源站"
    if echo "$headers_lower" | grep -qE "server:[[:space:]]*cloudflare|cf-ray|cf-cache-status"; then
        cdn_type="Cloudflare (极高封锁风险)"
    elif echo "$headers_lower" | grep -qE "server:[[:space:]]*cloudfront|x-amz-cf-id"; then
        cdn_type="AWS CloudFront"
    elif echo "$headers_lower" | grep -qE "server:[[:space:]]*akamai|x-akamai"; then
        cdn_type="Akamai CDN"
    elif echo "$headers_lower" | grep -qE "fastly|x-fastly"; then
        cdn_type="Fastly CDN"
    fi

    # 2. 握手延迟测量与 TLS 1.3 / HTTP/2 检验 (OpenSSL 真实探测)
    local start_ts end_ts rtt_ms="999"
    local openssl_out
    start_ts=$(date +%s%3N 2>/dev/null || python3 -c 'import time; print(int(time.time()*1000))' 2>/dev/null || echo 0)
    
    # 模拟真实客户端进行 TLS 1.3 + ALPN (h2) 协商 (设置 2.5s 硬超时防卡死)
    if command -v timeout &>/dev/null; then
        openssl_out=$(timeout 2.5 openssl s_client -tls1_3 -alpn h2,http/1.1 -connect "${domain}:443" -servername "${domain}" </dev/null 2>&1 || true)
    else
        openssl_out=$(echo -n "" | openssl s_client -tls1_3 -alpn h2,http/1.1 -connect "${domain}:443" -servername "${domain}" 2>&1 || true)
    fi
    
    end_ts=$(date +%s%3N 2>/dev/null || python3 -c 'import time; print(int(time.time()*1000))' 2>/dev/null || echo 0)
    if [[ "$start_ts" -gt 0 && "$end_ts" -gt 0 && "$end_ts" -ge "$start_ts" ]]; then
        rtt_ms=$((end_ts - start_ts))
    fi

    # 3. 特性判断
    local is_tls13="否"
    if echo "$openssl_out" | grep -qE "TLSv1.3|TLS 1.3"; then
        is_tls13="是"
    fi

    local is_h2="否"
    if echo "$openssl_out" | grep -qE "ALPN protocol: h2"; then
        is_h2="是"
    fi

    # 4. 综合评级
    local rating="不推荐"
    if [[ "$is_tls13" == "是" && "$cdn_type" == "独立源站" ]]; then
        if [[ "$http_code" =~ ^(200|301|302|304|307|308)$ ]]; then
            if [[ "$is_h2" == "是" ]]; then
                rating="⭐⭐⭐⭐⭐ 极品完美"
            else
                rating="⭐⭐⭐⭐ 优秀"
            fi
        else
            rating="⭐⭐⭐ 可用 (非标准响应)"
        fi
    elif [[ "$is_tls13" == "是" && "$cdn_type" != *"Cloudflare"* ]]; then
        rating="⭐⭐ 一般 (大型CDN)"
    fi

    echo "${http_code}|${is_tls13}|${is_h2}|${cdn_type}|${rtt_ms}|${rating}"
}

# --- 策略 1: 智能优选当地独立高校 ---
scan_local_universities() {
    echo -e "\n${CYAN}[2/3] 正在加载全球高校数据库并检索当地 (${VPS_COUNTRY}) 机构...${PLAIN}"
    local cache_file="/tmp/sni_universities.json"
    if [[ ! -s "$cache_file" ]]; then
        local u_raw="https://raw.githubusercontent.com/Hipo/university-domains-list/master/world_universities_and_domains.json"
        local u_cdn="https://cdn.jsdelivr.net/gh/Hipo/university-domains-list@master/world_universities_and_domains.json"
        curl -s4m 8 "$u_raw" -o "$cache_file" 2>/dev/null || curl -s4m 8 "$u_cdn" -o "$cache_file" 2>/dev/null || true
    fi

    local domains=()
    if [[ -s "$cache_file" ]]; then
        while IFS= read -r line; do
            line=$(echo "$line" | tr -d '\r\n[:space:]')
            [[ -n "$line" ]] && domains+=("$line")
        done < <(jq -r --arg c "$VPS_COUNTRY" '.[] | select(.country == $c) | .domains[]?' "$cache_file" 2>/dev/null | sort -u)
    fi

    if [[ ${#domains[@]} -eq 0 ]]; then
        echo -e "${YELLOW}[!] 当前地区暂未匹配到独立大学数据库，自动载入全球精选候选池...${PLAIN}"
        domains=(
            "www.harvard.edu" "www.mit.edu" "www.stanford.edu" "www.ox.ac.uk"
            "www.cam.ac.uk" "www.nus.edu.sg" "www.hku.hk" "www.u-tokyo.ac.jp"
        )
    else
        echo -e "${GREEN}[✓] 在当地成功匹配到 ${#domains[@]} 个大学独立域名！${PLAIN}"
        if [[ ${#domains[@]} -gt 25 ]]; then
            if command -v shuf &>/dev/null; then
                domains=($(printf "%s\n" "${domains[@]}" | shuf -n 25))
            else
                domains=("${domains[@]:0:25}")
            fi
            echo -e "${CYAN}[i] 机构库规模庞大，已智能随机精选 25 所代表性大学进行极速体检 (达标即停)...${PLAIN}"
        fi
    fi

    run_batch_test "${domains[@]}"
}

# --- 策略 2: 精选全球大厂安全随机源站 ---
scan_bigtech_origins() {
    echo -e "\n${CYAN}[2/3] 载入全球大厂高信誉安全源站 (彻底剔除 Cloudflare)...${PLAIN}"
    local bigtech_list=(
        "www.apple.com" "gateway.icloud.com" "itunes.apple.com" "www.icloud.com"
        "www.microsoft.com" "azure.microsoft.com" "www.amazon.com" "aws.amazon.com"
        "www.nvidia.com" "www.intel.com" "www.sony.com" "www.samsung.com"
        "www.bmw.com" "www.mercedes-benz.com" "www.tesla.com" "www.adobe.com"
    )
    run_batch_test "${bigtech_list[@]}"
}

# --- 策略 3: 用户自定义域名/列表测试 ---
scan_custom_domains() {
    echo -e "\n--------------------------------------------------------"
    echo -e " 请输入你想测试的域名 (多个域名请用空格分隔):"
    echo -e " 例如: www.apple.com www.cityu.edu.hk www.lovelive-anime.jp"
    echo -e "--------------------------------------------------------"
    read -rp "输入域名: " input_domains
    if [[ -z "$input_domains" ]]; then
        echo -e "${RED}[错误] 输入不能为空！${PLAIN}"
        return
    fi

    local domains=($input_domains)
    run_batch_test "${domains[@]}"
}

# --- 批量并发/快速体检调度器与结果制表 ---
run_batch_test() {
    local target_list=("$@")
    echo -e "\n${CYAN}[3/3] 正在对候选域名执行 [TLS1.3 + HTTP/2 + CDN排查 + 物理延迟] 深度体检...${PLAIN}"
    echo -e "--------------------------------------------------------------------------------------------------------"
    printf "${BOLD}%-28s | %-6s | %-7s | %-6s | %-16s | %-6s | %-16s${PLAIN}\n" "域名 (Domain)" "HTTP" "TLS 1.3" "HTTP/2" "CDN属性" "延迟" "推荐指数"
    echo -e "--------------------------------------------------------------------------------------------------------"

    local qualified_results=()

    for d in "${target_list[@]}"; do
        d=$(echo "$d" | tr -d '\r\n[:space:]')
        [[ -z "$d" ]] && continue

        local res
        res=$(test_single_domain "$d")
        
        IFS='|' read -r code tls13 h2 cdn rtt rating <<< "$res"

        local c_code="$code"
        local c_tls="$tls13"
        local c_h2="$h2"
        local c_cdn="$cdn"
        local c_rtt="${rtt} ms"

        if ! [[ "$rtt" =~ ^[0-9]+$ ]]; then
            c_rtt="超时/失败"
        elif (( rtt < 80 )); then
            c_rtt="${rtt} ms (极速)"
        elif (( rtt < 200 )); then
            c_rtt="${rtt} ms (良好)"
        else
            c_rtt="${rtt} ms (一般)"
        fi

        printf "%-28s | %-6s | %-7s | %-6s | %-24s | %-14s | %s\n" "$d" "$c_code" "$c_tls" "$c_h2" "$c_cdn" "$c_rtt" "$rating"

        # 收集优质候选
        if [[ "$tls13" == "是" && "$cdn" == "独立源站" && "$code" =~ ^(200|301|302|304|307|308)$ ]]; then
            qualified_results+=("${rtt}|${d}|${h2}|${code}")
            # 若已捕获 3 个极速五星源站，提前收工无需傻等
            if [[ "$h2" == "是" && ${#qualified_results[@]} -ge 3 ]]; then
                echo -e "--------------------------------------------------------------------------------------------------------"
                echo -e "${GREEN}[✓] 已成功捕获 3 个五星极品独立源站，无需继续等待，自动提前完成！${PLAIN}"
                break
            fi
        fi
    done

    if [[ ${#qualified_results[@]} -lt 3 ]]; then
        echo -e "--------------------------------------------------------------------------------------------------------"
    fi
    
    # 汇总最佳推荐
    if [[ ${#qualified_results[@]} -gt 0 ]]; then
        # 按延迟从低到高排序
        IFS=$'\n' sorted=($(sort -t'|' -k1 -n <<<"${qualified_results[*]}"))
        unset IFS

        echo -e "\n${BOLD}${GREEN}🎉 深度体检完成！为你精选出最适合偷的 TOP 最佳源站：${PLAIN}"
        local rank=1
        for item in "${sorted[@]}"; do
            IFS='|' read -r q_rtt q_domain q_h2 q_code <<< "$item"
            echo -e " ${BOLD}[Top ${rank}]${PLAIN} \033[1;32m${q_domain}\033[0m"
            echo -e "       - 本地物理握手延迟: ${GREEN}${q_rtt} ms${PLAIN}"
            echo -e "       - HTTP/2 支持状态  : ${CYAN}${q_h2}${PLAIN} (状态码: ${q_code})"
            echo -e "       - 客户端配置参数   : \033[1;33msni: ${q_domain}\033[0m | server_name: ${q_domain} | port: 443"
            ((rank++))
            [[ "$rank" -gt 3 ]] && break
        done
        echo ""
    else
        echo -e "\n${YELLOW}[!] 本轮候选域名均未达到五星极品标准，建议尝试【策略 2: 大厂安全源站】或重新优选。${PLAIN}\n"
    fi
}

# --- 主界面 ---
main_menu() {
    clear
    echo -e "========================================================================"
    echo -e "    ${BOLD}${CYAN}Reality SNI Scout 🚀 VLESS-Reality 极客级伪装域名智能雷达${PLAIN}"
    echo -e "========================================================================"
    check_deps
    get_vps_geo
    echo -e "------------------------------------------------------------------------"
    echo -e " 请选择要执行的 SNI 探测模式:"
    echo -e " ${GREEN}1.${PLAIN} \033[1;32m扫描当前 VPS 所在地的高校独立源站\033[0m (防封极品，同城IP，最逼真流量)"
    echo -e " ${GREEN}2.${PLAIN} \033[1;36m扫描全球高信誉大厂独立源站\033[0m     (彻底清退 Cloudflare，稳健通用)"
    echo -e " ${GREEN}3.${PLAIN} 自定义输入域名进行深度体检 (支持单个或多个域名批量)"
    echo -e " ${GREEN}0.${PLAIN} 退出测试"
    echo -e "========================================================================"
    read -rp "请输入选项 [0-3, 默认 1]: " opt
    opt=${opt:-1}

    case "$opt" in
        1) scan_local_universities ;;
        2) scan_bigtech_origins ;;
        3) scan_custom_domains ;;
        0) exit 0 ;;
        *) scan_local_universities ;;
    esac

    echo ""
    read -n 1 -s -r -p "按任意键返回主菜单..."
    main_menu
}

main() {
    if [[ $# -gt 0 ]]; then
        check_deps
        get_vps_geo
        case "$1" in
            1|local|edu)
                scan_local_universities
                ;;
            2|bigtech|top)
                scan_bigtech_origins
                ;;
            3|test|custom)
                shift
                if [[ $# -gt 0 ]]; then
                    run_batch_test "$@"
                else
                    scan_custom_domains
                fi
                ;;
            *)
                run_batch_test "$@"
                ;;
        esac
    else
        main_menu
    fi
}

main "$@"
