#!/bin/bash

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
CYAN='\033[0;36m'
NC='\033[0m'

# 配置文件路径
RULES_FILE="/etc/realm/rules.conf"
REALM_CONFIG="/etc/realm/config.toml"
REALM_BIN="/usr/local/bin/realm"
SERVICE_FILE="/etc/systemd/system/realm-forward.service"
CRM_SCRIPT="/usr/local/bin/crm"

# GitHub 仓库
GITHUB_REPO="zhboner/realm"

show_header() {
    clear
    echo -e "${GREEN}========================================${NC}"
    echo -e "${GREEN}   Realm 端口转发管理工具安装程序      ${NC}"
    echo -e "${GREEN}========================================${NC}"
    echo ""
}

check_root() {
    if [[ $EUID -ne 0 ]]; then
        echo -e "${RED}错误: 此脚本必须以root权限运行${NC}"
        exit 1
    fi
}

detect_arch() {
    local arch
    arch=$(uname -m)
    case "$arch" in
        x86_64)
            echo "x86_64-unknown-linux-gnu"
            ;;
        aarch64|arm64)
            echo "aarch64-unknown-linux-gnu"
            ;;
        *)
            echo ""
            ;;
    esac
}

# 检查系统是否支持 IPv6
ipv6_available() {
    if [ -f /proc/net/if_inet6 ] && [ -s /proc/net/if_inet6 ]; then
        return 0
    fi
    if [ -f /proc/sys/net/ipv6/conf/all/disable_ipv6 ]; then
        local disabled
        disabled=$(cat /proc/sys/net/ipv6/conf/all/disable_ipv6 2>/dev/null)
        [ "$disabled" = "0" ] && return 0
    fi
    return 1
}

install_realm() {
    echo -e "${BLUE}[1/5] 安装 realm (最新版本)...${NC}"
    
    if [ -x "$REALM_BIN" ]; then
        echo -e "${GREEN}realm 已安装${NC}"
        return
    fi
    
    ARCH_SUFFIX=$(detect_arch)
    if [ -z "$ARCH_SUFFIX" ]; then
        echo -e "${RED}错误: 不支持的架构 $(uname -m)，仅支持 x86_64 和 aarch64${NC}"
        exit 1
    fi
    
    echo -e "${YELLOW}正在获取最新版本信息...${NC}"
    
    local api_url="https://api.github.com/repos/${GITHUB_REPO}/releases/latest"
    local release_data
    if command -v curl &>/dev/null; then
        release_data=$(curl -sL "$api_url")
    elif command -v wget &>/dev/null; then
        release_data=$(wget -qO- "$api_url")
    else
        echo -e "${RED}错误: 需要 curl 或 wget${NC}"
        exit 1
    fi
    
    local latest_version download_url
    if command -v jq &>/dev/null; then
        latest_version=$(echo "$release_data" | jq -r '.tag_name')
        download_url=$(echo "$release_data" | jq -r --arg suffix "$ARCH_SUFFIX" '
            [ .assets[] | select(.name | contains($suffix)) ] as $assets |
            ( $assets | map(select(.name | test("slim") | not)) | first? ) // $assets[0] | .browser_download_url
        ')
    else
        latest_version=$(echo "$release_data" | grep -oP '"tag_name":\s*"\K[^"]+')
        download_url=$(echo "$release_data" | grep -oP '"browser_download_url":\s*"\K[^"]+' | grep "$ARCH_SUFFIX" | grep -v 'slim' | head -1)
        [ -z "$download_url" ] && download_url=$(echo "$release_data" | grep -oP '"browser_download_url":\s*"\K[^"]+' | grep "$ARCH_SUFFIX" | head -1)
    fi
    
    if [ -z "$latest_version" ] || [ -z "$download_url" ]; then
        echo -e "${RED}错误: 无法获取最新版本信息或下载链接${NC}"
        exit 1
    fi
    
    echo -e "${GREEN}最新版本: ${latest_version}${NC}"
    echo -e "${YELLOW}下载链接: ${download_url}${NC}"
    
    local tmp_dir=$(mktemp -d)
    echo -e "${YELLOW}正在下载 realm...${NC}"
    if command -v curl &>/dev/null; then
        curl -L "$download_url" -o "$tmp_dir/realm.tar.gz" --retry 3
    else
        wget -O "$tmp_dir/realm.tar.gz" "$download_url" -t 3
    fi
    
    if [ $? -ne 0 ]; then
        echo -e "${RED}下载失败${NC}"
        rm -rf "$tmp_dir"
        exit 1
    fi
    
    mkdir -p /usr/local/bin
    tar -xzf "$tmp_dir/realm.tar.gz" -C "$tmp_dir"
    local realm_path=$(find "$tmp_dir" -type f -name realm -executable | head -1)
    if [ -z "$realm_path" ]; then
        echo -e "${RED}解压后未找到 realm 可执行文件${NC}"
        rm -rf "$tmp_dir"
        exit 1
    fi
    mv "$realm_path" "$REALM_BIN"
    chmod +x "$REALM_BIN"
    rm -rf "$tmp_dir"
    
    if [ -x "$REALM_BIN" ]; then
        echo -e "${GREEN}realm 安装成功${NC}"
    else
        echo -e "${RED}realm 安装失败${NC}"
        exit 1
    fi
}

create_rules_file() {
    echo -e "${BLUE}[2/5] 创建规则文件...${NC}"
    mkdir -p /etc/realm
    if [ ! -f "$RULES_FILE" ]; then
        cat > "$RULES_FILE" << 'EOF'
# Realm 端口转发规则
# 格式: 本地端口:远程地址:远程端口
# 远程地址可以为 IP 或域名
# 每个规则将通过 IPv6 双栈套接字（若系统支持）同时接受 IPv4/IPv6 连接，转发 TCP 与 UDP
EOF
        chmod 644 "$RULES_FILE"
        echo -e "${GREEN}规则文件已创建: $RULES_FILE${NC}"
    else
        echo -e "${YELLOW}规则文件已存在，保留原有配置${NC}"
    fi
}

# 核心：生成 realm 配置（使用单 IPv6 双栈端点）
generate_realm_config() {
    local config_tmp=$(mktemp)
    local use_ipv6="no"
    if ipv6_available; then
        use_ipv6="yes"
    fi

    cat > "$config_tmp" << 'EOF'
[log]
level = "warn"
output = "realm.log"

[network]
no_tcp = false
use_udp = true

EOF

    if [ -f "$RULES_FILE" ]; then
        grep -v '^#' "$RULES_FILE" | grep -v '^$' | while IFS=':' read local_port remote_addr remote_port; do
            if [ -n "$local_port" ] && [ -n "$remote_addr" ] && [ -n "$remote_port" ]; then
                if [ "$use_ipv6" = "yes" ]; then
                    # 双栈：仅使用 [::] 端点，同时接受 IPv4 和 IPv6
                    cat >> "$config_tmp" << INNEREOF
[[endpoints]]
listen = "[::]:${local_port}"
remote = "${remote_addr}:${remote_port}"

INNEREOF
                else
                    # IPv6 不可用，仅 IPv4
                    cat >> "$config_tmp" << INNEREOF
[[endpoints]]
listen = "0.0.0.0:${local_port}"
remote = "${remote_addr}:${remote_port}"

INNEREOF
                fi
            fi
        done
    fi
    
    mv "$config_tmp" "$REALM_CONFIG"
    chmod 644 "$REALM_CONFIG"
}

create_systemd_service() {
    echo -e "${BLUE}[3/5] 创建系统服务...${NC}"
    cat > "$SERVICE_FILE" << EOF
[Unit]
Description=Realm Port Forwarding Service
After=network.target
Wants=network.target

[Service]
Type=simple
ExecStart=${REALM_BIN} -c ${REALM_CONFIG}
ExecReload=/bin/kill -HUP \$MAINPID
Restart=on-failure
RestartSec=5s

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    echo -e "${GREEN}系统服务已创建${NC}"
}

# 创建 crm 管理脚本（内嵌相同逻辑）
create_crm_script() {
    echo -e "${BLUE}[4/5] 创建管理脚本...${NC}"
    cat > "$CRM_SCRIPT" << 'CRM_EOF'
#!/bin/bash

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

RULES_FILE="/etc/realm/rules.conf"
REALM_CONFIG="/etc/realm/config.toml"
SERVICE_NAME="realm-forward.service"

show_header() {
    clear
    echo -e "${CYAN}========================================${NC}"
    echo -e "${CYAN}   Realm 端口转发管理工具 v2.0        ${NC}"
    echo -e "${CYAN}========================================${NC}"
    echo ""
}

ipv6_available() {
    if [ -f /proc/net/if_inet6 ] && [ -s /proc/net/if_inet6 ]; then
        return 0
    fi
    if [ -f /proc/sys/net/ipv6/conf/all/disable_ipv6 ]; then
        local disabled=$(cat /proc/sys/net/ipv6/conf/all/disable_ipv6 2>/dev/null)
        [ "$disabled" = "0" ] && return 0
    fi
    return 1
}

generate_realm_config() {
    local config_tmp=$(mktemp)
    local use_ipv6="no"
    if ipv6_available; then
        use_ipv6="yes"
    fi

    cat > "$config_tmp" << 'EOF'
[log]
level = "warn"
output = "realm.log"

[network]
no_tcp = false
use_udp = true

EOF

    if [ -f "$RULES_FILE" ]; then
        grep -v '^#' "$RULES_FILE" | grep -v '^$' | while IFS=':' read local_port remote_addr remote_port; do
            if [ -n "$local_port" ] && [ -n "$remote_addr" ] && [ -n "$remote_port" ]; then
                if [ "$use_ipv6" = "yes" ]; then
                    cat >> "$config_tmp" << INNEREOF
[[endpoints]]
listen = "[::]:${local_port}"
remote = "${remote_addr}:${remote_port}"

INNEREOF
                else
                    cat >> "$config_tmp" << INNEREOF
[[endpoints]]
listen = "0.0.0.0:${local_port}"
remote = "${remote_addr}:${remote_port}"

INNEREOF
                fi
            fi
        done
    fi
    
    mv "$config_tmp" "$REALM_CONFIG"
}

restart_service_force() {
    generate_realm_config
    systemctl restart "$SERVICE_NAME"
    sleep 1
    if systemctl is-active --quiet "$SERVICE_NAME"; then
        echo -e "${GREEN}服务已重启，新规则生效${NC}"
        return 0
    else
        echo -e "${RED}服务重启失败，请检查日志: journalctl -u $SERVICE_NAME${NC}"
        return 1
    fi
}

show_menu() {
    echo -e "${BLUE}请选择操作:${NC}"
    echo -e "  ${GREEN}1${NC} - 添加端口转发"
    echo -e "  ${GREEN}2${NC} - 查看转发列表"
    echo -e "  ${GREEN}3${NC} - 修改转发规则"
    echo -e "  ${GREEN}4${NC} - 查看服务状态"
    echo -e "  ${GREEN}5${NC} - 重启转发服务"
    echo -e "  ${GREEN}6${NC} - 停止转发服务"
    echo -e "  ${GREEN}7${NC} - 卸载转发服务"
    echo -e "  ${GREEN}8${NC} - 重新加载规则"
    echo -e "  ${GREEN}0${NC} - 退出"
    echo ""
    echo -n "请输入选择 [0-8]: "
}

add_forward() {
    show_header
    echo -e "${YELLOW}添加端口转发规则（代理模式）${NC}"
    echo -e "${YELLOW}系统将通过 IPv6 双栈套接字同时接受 IPv4/IPv6 连接，转发 TCP+UDP${NC}\n"
    
    while true; do
        read -p "本地端口 (1-65535): " local_port
        [[ "$local_port" =~ ^[0-9]+$ ]] && [ "$local_port" -ge 1 ] && [ "$local_port" -le 65535 ] || { echo -e "${RED}无效端口${NC}"; continue; }
        grep -v '^#' "$RULES_FILE" | grep -q "^$local_port:" && { echo -e "${RED}端口 $local_port 已占用${NC}"; continue; }
        break
    done
    
    while true; do
        read -p "远程地址 (IP 或 域名): " remote_addr
        [ -n "$remote_addr" ] && break || echo -e "${RED}远程地址不能为空${NC}"
    done
    
    while true; do
        read -p "远程端口 (1-65535): " remote_port
        [[ "$remote_port" =~ ^[0-9]+$ ]] && [ "$remote_port" -ge 1 ] && [ "$remote_port" -le 65535 ] && break || echo -e "${RED}无效端口${NC}"
    done
    
    echo ""
    echo -e "确认: ${GREEN}$local_port -> $remote_addr:$remote_port (TCP+UDP)${NC}"
    read -p "添加? (y/n): " confirm
    [[ "$confirm" =~ ^[Yy]$ ]] || { echo -e "${YELLOW}已取消${NC}"; read -p "回车返回..."; return; }
    
    echo "$local_port:$remote_addr:$remote_port" >> "$RULES_FILE"
    echo -e "${GREEN}规则已添加${NC}"
    restart_service_force
    read -p "按回车返回..."
}

list_forwards() {
    show_header
    echo -e "${YELLOW}当前转发规则${NC}\n"
    if [ ! -f "$RULES_FILE" ] || ! grep -v '^#' "$RULES_FILE" | grep -q .; then
        echo -e "${RED}无规则${NC}\n"; read -p "回车返回..."; return
    fi
    echo -e "${CYAN}序号 | 本地端口 | 远程地址                | 协议${NC}"
    echo -e "${CYAN}-----|----------|-------------------------|------${NC}"
    local index=1
    while IFS=':' read lp raddr rp; do
        printf "%-5s | %-8s | %-24s | %-s\n" "$index" "$lp" "$raddr:$rp" "TCP+UDP"
        ((index++))
    done < <(grep -v '^#' "$RULES_FILE" | grep -v '^$')
    echo ""; read -p "回车返回..."
}

modify_forward() {
    show_header
    echo -e "${YELLOW}修改规则${NC}\n"
    if [ ! -f "$RULES_FILE" ] || ! grep -v '^#' "$RULES_FILE" | grep -q .; then
        echo -e "${RED}无规则${NC}\n"; read -p "回车返回..."; return
    fi
    
    local index=1
    declare -a rules
    while IFS=':' read lp raddr rp; do
        rules[$index]="$lp:$raddr:$rp"
        echo -e " ${GREEN}$index${NC}) 本地:$lp -> 远程:$raddr:$rp"
        ((index++))
    done < <(grep -v '^#' "$RULES_FILE" | grep -v '^$')
    
    echo ""
    read -p "选择序号 (0取消): " num
    if [[ ! "$num" =~ ^[0-9]+$ ]] || [ "$num" -lt 0 ] || [ "$num" -ge $index ]; then
        echo -e "${RED}无效${NC}"; read -p "回车返回..."; return
    fi
    [ "$num" -eq 0 ] && return
    
    echo -e "\n1) 改本地端口  2) 改远程地址/端口  3) 删除  0) 取消"
    read -p "操作: " act
    case $act in
        1)
            while true; do
                read -p "新本地端口: " lp
                [[ "$lp" =~ ^[0-9]+$ ]] && [ "$lp" -ge 1 ] && [ "$lp" -le 65535 ] || { echo -e "${RED}无效${NC}"; continue; }
                grep -v '^#' "$RULES_FILE" | grep -v "^${rules[$num]}$" | grep -q "^$lp:" && { echo -e "${RED}端口占用${NC}"; continue; }
                break
            done
            IFS=':' read old_lp raddr rp <<< "${rules[$num]}"
            sed -i "s/^${rules[$num]}$/$lp:$raddr:$rp/" "$RULES_FILE"
            echo -e "${GREEN}已修改${NC}"
            ;;
        2)
            while true; do
                read -p "新远程地址 (IP 或 域名): " raddr
                [ -n "$raddr" ] && break || echo -e "${RED}不能为空${NC}"
            done
            while true; do
                read -p "新远程端口: " rp
                [[ "$rp" =~ ^[0-9]+$ ]] && break || echo -e "${RED}无效端口${NC}"
            done
            IFS=':' read lp old_raddr old_rp <<< "${rules[$num]}"
            sed -i "s/^${rules[$num]}$/$lp:$raddr:$rp/" "$RULES_FILE"
            echo -e "${GREEN}已修改${NC}"
            ;;
        3)
            read -p "确认删除? (y/n): " cf
            [[ "$cf" =~ ^[Yy]$ ]] && { sed -i "/^${rules[$num]}$/d" "$RULES_FILE"; echo -e "${GREEN}已删除${NC}"; } || echo "取消"
            ;;
        *) echo "取消";;
    esac
    restart_service_force
    read -p "回车返回..."
}

show_status() {
    show_header
    echo -e "${YELLOW}服务状态${NC}\n"
    if systemctl is-active --quiet "$SERVICE_NAME"; then
        echo -e "Realm: ${GREEN}运行中${NC}"
    else
        echo -e "Realm: ${RED}未运行${NC}"
    fi
    echo -e "\n${CYAN}规则:${NC}"
    grep -v '^#' "$RULES_FILE" 2>/dev/null | grep -v '^$' | while IFS=':' read lp raddr rp; do
        echo -e "  ${GREEN}$lp${NC} -> $raddr:$rp (TCP+UDP)"
    done
    echo ""; read -p "回车返回..."
}

restart_service() {
    show_header
    restart_service_force
    read -p "回车返回..."
}

stop_service() {
    show_header
    systemctl stop "$SERVICE_NAME"
    echo -e "${GREEN}已停止${NC}"
    read -p "回车返回..."
}

reload_rules() {
    show_header
    restart_service_force
    read -p "回车返回..."
}

uninstall_service() {
    show_header
    echo -e "${RED}卸载服务${NC}\n"
    read -p "确认卸载? (y/n): " cf
    [[ "$cf" =~ ^[Yy]$ ]] || { echo "取消"; read -p "回车退出..."; exit 0; }
    systemctl stop "$SERVICE_NAME" 2>/dev/null
    systemctl disable "$SERVICE_NAME" 2>/dev/null
    rm -f "/etc/systemd/system/$SERVICE_NAME"
    systemctl daemon-reload
    read -p "删除规则文件? (y/n): " dr
    [[ "$dr" =~ ^[Yy]$ ]] && rm -f "$RULES_FILE"
    rm -f "$REALM_CONFIG"
    rm -f "/usr/local/bin/crm"
    read -p "删除 realm 程序? (y/n): " db
    [[ "$db" =~ ^[Yy]$ ]] && rm -f "/usr/local/bin/realm"
    echo -e "${GREEN}卸载完成${NC}"
    read -p "回车退出..."
    exit 0
}

main() {
    [ "$EUID" -ne 0 ] && { echo -e "${RED}需要root权限${NC}"; exit 1; }
    while true; do
        show_header
        show_menu
        read choice
        case $choice in
            1) add_forward ;;
            2) list_forwards ;;
            3) modify_forward ;;
            4) show_status ;;
            5) restart_service ;;
            6) stop_service ;;
            7) uninstall_service ;;
            8) reload_rules ;;
            0) echo -e "${GREEN}再见${NC}"; exit 0 ;;
            *) echo -e "${RED}无效${NC}"; sleep 1 ;;
        esac
    done
}

case "$1" in
    reload|start) restart_service_force ;;
    stop) systemctl stop "$SERVICE_NAME" ;;
    status) show_status; exit 0 ;;
    list) list_forwards; exit 0 ;;
    *) main ;;
esac
CRM_EOF

    chmod +x "$CRM_SCRIPT"
    echo -e "${GREEN}管理脚本已创建: $CRM_SCRIPT${NC}"
}

start_services() {
    echo -e "${BLUE}[5/5] 启动服务...${NC}"
    generate_realm_config
    systemctl enable realm-forward.service
    systemctl restart realm-forward.service
    if systemctl is-active --quiet realm-forward.service; then
        echo -e "${GREEN}服务启动成功${NC}"
    else
        echo -e "${RED}服务启动失败，请检查日志: journalctl -u realm-forward.service${NC}"
    fi
}

complete_installation() {
    show_header
    echo -e "${GREEN}========================================${NC}"
    echo -e "${GREEN}           安装完成！                ${NC}"
    echo -e "${GREEN}========================================${NC}"
    echo ""
    echo -e "✓ realm 已安装"
    echo -e "✓ 规则文件: $RULES_FILE"
    echo -e "✓ 管理命令: crm"
    echo ""
    echo -e "用法: sudo crm"
    echo -e "快速命令: crm reload/status/list/start/stop"
    echo ""
    if ipv6_available; then
        echo -e "检测到系统支持 IPv6，将通过 IPv6 双栈套接字同时接受 IPv4/IPv6 连接"
    else
        echo -e "未检测到 IPv6，将仅监听 IPv4"
    fi
    echo -e "${GREEN}现在可以使用 'sudo crm' 配置端口转发！${NC}"
}

main_install() {
    check_root
    show_header
    install_realm
    create_rules_file
    create_systemd_service
    create_crm_script
    start_services
    complete_installation
}

main_install