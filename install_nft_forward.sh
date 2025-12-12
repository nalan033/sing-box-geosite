#!/bin/bash

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# 配置文件
RULES_FILE="/etc/nftables.conf"
CONFIG_FILE="/etc/nft-forward.conf"
SERVICE_FILE="/etc/systemd/system/nft-forward.service"
NB_SCRIPT="/usr/local/bin/nb"

# 显示标题
show_header() {
    clear
    echo -e "${GREEN}========================================${NC}"
    echo -e "${GREEN}   NFTables 端口转发管理工具安装程序   ${NC}"
    echo -e "${GREEN}========================================${NC}"
    echo ""
}

# 检查root权限
check_root() {
    if [[ $EUID -ne 0 ]]; then
        echo -e "${RED}错误: 此脚本必须以root权限运行${NC}"
        exit 1
    fi
}

# 安装nftables
install_nftables() {
    echo -e "${BLUE}[1/6] 检查并安装nftables...${NC}"
    
    if command -v nft &> /dev/null; then
        echo -e "${GREEN}nftables 已安装${NC}"
    else
        echo -e "${YELLOW}正在安装nftables...${NC}"
        
        # 检测系统类型
        if [ -f /etc/debian_version ]; then
            apt-get update
            apt-get install -y nftables
        elif [ -f /etc/redhat-release ]; then
            yum install -y nftables
        elif [ -f /etc/arch-release ]; then
            pacman -Sy nftables --noconfirm
        elif [ -f /etc/alpine-release ]; then
            apk add nftables
        else
            echo -e "${YELLOW}无法自动识别系统，请手动安装nftables:${NC}"
            echo -e "Debian/Ubuntu: apt install nftables"
            echo -e "CentOS/RHEL: yum install nftables"
            echo -e "Arch: pacman -S nftables"
            exit 1
        fi
        
        if command -v nft &> /dev/null; then
            echo -e "${GREEN}nftables 安装成功${NC}"
        else
            echo -e "${RED}nftables 安装失败，请手动安装${NC}"
            exit 1
        fi
    fi
}

# 创建初始nftables配置
create_nftables_config() {
    echo -e "${BLUE}[2/6] 创建nftables配置...${NC}"
    
    # 备份原有配置
    if [ -f "$RULES_FILE" ]; then
        backup_file="${RULES_FILE}.backup.$(date +%Y%m%d%H%M%S)"
        cp "$RULES_FILE" "$backup_file"
        echo -e "${YELLOW}已备份原有配置: $backup_file${NC}"
    fi
    
    # 创建新的nftables配置，只保留nat表
    cat > "$RULES_FILE" << 'EOF'
#!/usr/sbin/nft -f

flush ruleset

table ip nat {
    # 目标IP集合（用于SNAT）
    set dst-ip {
        type ipv4_addr
        flags interval
    }
    
    # 端口转发链（DNAT）
    chain port-dnat {
        type nat hook prerouting priority dstnat; policy accept;
        # 转发规则将在这里动态添加
    }
    
    # 源地址转换链（SNAT）
    chain port-snat {
        type nat hook postrouting priority srcnat; policy accept;
        ip daddr @dst-ip masquerade
    }
}
EOF
    
    echo -e "${GREEN}nftables配置已创建: $RULES_FILE${NC}"
}

# 创建配置文件
create_config_file() {
    echo -e "${BLUE}[3/6] 创建转发配置文件...${NC}"
    
    # 检查配置文件是否已存在
    if [ -f "$CONFIG_FILE" ]; then
        backup_file="${CONFIG_FILE}.backup.$(date +%Y%m%d%H%M%S)"
        cp "$CONFIG_FILE" "$backup_file"
        echo -e "${YELLOW}配置文件已存在，已备份: $backup_file${NC}"
    else
        cat > "$CONFIG_FILE" << 'EOF'
# NFTables端口转发配置
# 格式: 本地端口:远程IP:远程端口
# 注意: 同时转发TCP和UDP
# 例如: 
# 8080:192.168.1.100:80
# 9000:10.0.0.5:3389

EOF
        chmod 644 "$CONFIG_FILE"
        echo -e "${GREEN}配置文件已创建: $CONFIG_FILE${NC}"
    fi
}

# 启用IP转发
enable_ip_forward() {
    echo -e "${BLUE}[4/6] 启用IP转发...${NC}"
    
    # 确保IPv4转发已启用
    echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf
    
    # 应用配置
    sysctl -p >/dev/null 2>&1 || true
    
    # 立即启用
    echo 1 > /proc/sys/net/ipv4/ip_forward
    
    # 检查是否启用成功
    if [ $(cat /proc/sys/net/ipv4/ip_forward) -eq 1 ]; then
        echo -e "${GREEN}IP转发已启用${NC}"
    else
        echo -e "${RED}IP转发启用失败${NC}"
    fi
}

# 创建systemd服务
create_systemd_service() {
    echo -e "${BLUE}[5/6] 创建系统服务...${NC}"
    
    # 备份原有服务文件
    if [ -f "$SERVICE_FILE" ]; then
        backup_file="${SERVICE_FILE}.backup.$(date +%Y%m%d%H%M%S)"
        cp "$SERVICE_FILE" "$backup_file"
        echo -e "${YELLOW}服务文件已存在，已备份: $backup_file${NC}"
    fi
    
    cat > "$SERVICE_FILE" << 'EOF'
[Unit]
Description=NFTables Port Forwarding Service
After=network.target
Wants=network.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/bin/nb reload
ExecStop=/usr/local/bin/nb stop
ExecReload=/usr/local/bin/nb reload

[Install]
WantedBy=multi-user.target
EOF
    
    # 重新加载systemd配置
    systemctl daemon-reload
    
    echo -e "${GREEN}系统服务已创建${NC}"
}

# 重新生成nftables配置函数
regenerate_nft_config() {
    # 读取配置文件
    if [ ! -f "$CONFIG_FILE" ]; then
        echo -e "${RED}配置文件不存在: $CONFIG_FILE${NC}"
        return 1
    fi
    
    # 创建临时文件
    TEMP_FILE=$(mktemp)
    
    # 构建新的nftables配置
    cat > "$TEMP_FILE" << 'EOF'
#!/usr/sbin/nft -f

flush ruleset

table ip nat {
    # 目标IP集合（用于SNAT）
    set dst-ip {
        type ipv4_addr
        flags interval
        elements = {
EOF
    
    # 提取所有远程IP（去重）
    grep -v '^#' "$CONFIG_FILE" | grep -v '^$' | cut -d':' -f2 | sort -u | while read ip; do
        if [ -n "$ip" ]; then
            echo "            $ip," >> "$TEMP_FILE"
        fi
    done
    
    cat >> "$TEMP_FILE" << 'EOF'
        }
    }
    
    # 端口转发链（DNAT）- 同时转发TCP和UDP
    chain port-dnat {
        type nat hook prerouting priority dstnat; policy accept;
EOF
    
    # 添加转发规则 - 同时转发TCP和UDP
    grep -v '^#' "$CONFIG_FILE" | grep -v '^$' | while IFS=':' read local_port remote_ip remote_port; do
        if [ -n "$local_port" ] && [ -n "$remote_ip" ] && [ -n "$remote_port" ]; then
            echo "        ip protocol { tcp, udp } th dport $local_port counter dnat to $remote_ip:$remote_port" >> "$TEMP_FILE"
        fi
    done
    
    cat >> "$TEMP_FILE" << 'EOF'
    }
    
    # 源地址转换链（SNAT）
    chain port-snat {
        type nat hook postrouting priority srcnat; policy accept;
        ip daddr @dst-ip masquerade
    }
}
EOF
    
    # 替换原配置文件
    mv "$TEMP_FILE" "$RULES_FILE"
    
    # 应用规则
    if nft -f "$RULES_FILE" 2>/dev/null; then
        echo -e "${GREEN}规则应用成功${NC}"
        return 0
    else
        echo -e "${RED}规则应用失败，检查配置${NC}"
        return 1
    fi
}

# 创建nb管理脚本
create_nb_script() {
    echo -e "${BLUE}[6/6] 创建管理脚本...${NC}"
    
    # 创建nb脚本
    cat > "$NB_SCRIPT" << 'EOF'
#!/bin/bash

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# 配置文件
RULES_FILE="/etc/nftables.conf"
CONFIG_FILE="/etc/nft-forward.conf"
SERVICE_FILE="/etc/systemd/system/nft-forward.service"

# 显示标题
show_header() {
    clear
    echo -e "${CYAN}========================================${NC}"
    echo -e "${CYAN}   NFTables 端口转发管理工具 v1.0     ${NC}"
    echo -e "${CYAN}========================================${NC}"
    echo ""
}

# 重新生成nftables配置
regenerate_nft_config() {
    # 读取配置文件
    if [ ! -f "$CONFIG_FILE" ]; then
        echo -e "${RED}配置文件不存在: $CONFIG_FILE${NC}"
        return 1
    fi
    
    # 创建临时文件
    TEMP_FILE=$(mktemp)
    
    # 构建新的nftables配置
    cat > "$TEMP_FILE" << 'EOF2'
#!/usr/sbin/nft -f

flush ruleset

table ip nat {
    # 目标IP集合（用于SNAT）
    set dst-ip {
        type ipv4_addr
        flags interval
        elements = {
EOF2
    
    # 提取所有远程IP（去重）
    grep -v '^#' "$CONFIG_FILE" | grep -v '^$' | cut -d':' -f2 | sort -u | while read ip; do
        if [ -n "$ip" ]; then
            echo "            $ip," >> "$TEMP_FILE"
        fi
    done
    
    cat >> "$TEMP_FILE" << 'EOF2'
        }
    }
    
    # 端口转发链（DNAT）- 同时转发TCP和UDP
    chain port-dnat {
        type nat hook prerouting priority dstnat; policy accept;
EOF2
    
    # 添加转发规则 - 同时转发TCP和UDP
    grep -v '^#' "$CONFIG_FILE" | grep -v '^$' | while IFS=':' read local_port remote_ip remote_port; do
        if [ -n "$local_port" ] && [ -n "$remote_ip" ] && [ -n "$remote_port" ]; then
            echo "        ip protocol { tcp, udp } th dport $local_port counter dnat to $remote_ip:$remote_port" >> "$TEMP_FILE"
        fi
    done
    
    cat >> "$TEMP_FILE" << 'EOF2'
    }
    
    # 源地址转换链（SNAT）
    chain port-snat {
        type nat hook postrouting priority srcnat; policy accept;
        ip daddr @dst-ip masquerade
    }
}
EOF2
    
    # 替换原配置文件
    mv "$TEMP_FILE" "$RULES_FILE"
    
    # 应用规则
    if nft -f "$RULES_FILE" 2>/dev/null; then
        echo -e "${GREEN}规则应用成功${NC}"
        return 0
    else
        echo -e "${RED}规则应用失败，检查配置${NC}"
        return 1
    fi
}

# 显示菜单
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

# 添加转发规则
add_forward() {
    show_header
    echo -e "${YELLOW}添加端口转发规则${NC}"
    echo ""
    echo -e "${YELLOW}注意: 将同时转发TCP和UDP${NC}"
    echo ""
    
    # 输入本地端口
    while true; do
        read -p "请输入本地端口 (1-65535): " local_port
        if [[ "$local_port" =~ ^[0-9]+$ ]] && [ "$local_port" -ge 1 ] && [ "$local_port" -le 65535 ]; then
            # 检查端口是否已被使用
            if grep -v '^#' "$CONFIG_FILE" | grep -q "^$local_port:"; then
                echo -e "${RED}错误: 本地端口 $local_port 已被使用${NC}"
            else
                break
            fi
        else
            echo -e "${RED}错误: 请输入有效的端口号${NC}"
        fi
    done
    
    # 输入远程IP
    while true; do
        read -p "请输入远程IP地址: " remote_ip
        if [[ "$remote_ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
            break
        else
            echo -e "${RED}错误: 请输入有效的IP地址${NC}"
        fi
    done
    
    # 输入远程端口
    while true; do
        read -p "请输入远程端口 (1-65535): " remote_port
        if [[ "$remote_port" =~ ^[0-9]+$ ]] && [ "$remote_port" -ge 1 ] && [ "$remote_port" -le 65535 ]; then
            break
        else
            echo -e "${RED}错误: 请输入有效的端口号${NC}"
        fi
    done
    
    # 确认添加
    echo ""
    echo -e "${YELLOW}请确认转发规则:${NC}"
    echo -e "  本地端口: ${GREEN}$local_port${NC}"
    echo -e "  远程地址: ${GREEN}$remote_ip:$remote_port${NC}"
    echo -e "  协议: ${GREEN}TCP和UDP${NC}"
    echo ""
    
    read -p "是否添加此规则? (y/n): " confirm
    if [[ "$confirm" =~ ^[Yy]$ ]]; then
        # 添加到配置文件
        echo "$local_port:$remote_ip:$remote_port" >> "$CONFIG_FILE"
        echo -e "${GREEN}规则已添加到配置文件${NC}"
        
        # 重新生成并应用配置
        regenerate_nft_config
        echo -e "${GREEN}转发规则已生效${NC}"
    else
        echo -e "${YELLOW}已取消添加${NC}"
    fi
    
    echo ""
    read -p "按回车键返回主菜单..."
}

# 查看转发列表
list_forwards() {
    show_header
    echo -e "${YELLOW}当前转发规则列表${NC}"
    echo ""
    
    if [ ! -f "$CONFIG_FILE" ] || ! grep -v '^#' "$CONFIG_FILE" | grep -q -v '^$'; then
        echo -e "${RED}没有找到转发规则${NC}"
        echo ""
        read -p "按回车键返回主菜单..."
        return
    fi
    
    echo -e "${CYAN}序号 | 本地端口 | 远程地址        | 协议 | 状态${NC}"
    echo -e "${CYAN}-----|----------|-----------------|------|------${NC}"
    
    index=1
    while IFS=':' read local_port remote_ip remote_port; do
        if [ -n "$local_port" ]; then
            # 检查规则是否生效
            if nft list chain ip nat port-dnat 2>/dev/null | grep -q "dport $local_port "; then
                status="${GREEN}生效${NC}"
            else
                status="${RED}未生效${NC}"
            fi
            
            printf "%-5s | %-8s | %-15s | %-4s | %-10s\n" \
                   "$index" "$local_port" "$remote_ip:$remote_port" "TCP/UDP" "$status"
            ((index++))
        fi
    done < <(grep -v '^#' "$CONFIG_FILE" | grep -v '^$')
    
    echo ""
    read -p "按回车键返回主菜单..."
}

# 修改转发规则
modify_forward() {
    show_header
    echo -e "${YELLOW}修改转发规则${NC}"
    echo ""
    
    # 检查是否有规则
    if [ ! -f "$CONFIG_FILE" ] || ! grep -v '^#' "$CONFIG_FILE" | grep -q -v '^$'; then
        echo -e "${RED}没有找到转发规则${NC}"
        echo ""
        read -p "按回车键返回主菜单..."
        return
    fi
    
    # 显示规则列表
    echo -e "${CYAN}可修改的规则:${NC}"
    echo ""
    
    index=1
    declare -a rules
    while IFS=':' read local_port remote_ip remote_port; do
        if [ -n "$local_port" ]; then
            rules[$index]="$local_port:$remote_ip:$remote_port"
            echo -e "  ${GREEN}$index${NC}) 本地:$local_port -> 远程:$remote_ip:$remote_port (TCP/UDP)"
            ((index++))
        fi
    done < <(grep -v '^#' "$CONFIG_FILE" | grep -v '^$')
    
    echo ""
    read -p "请选择要修改的规则序号 (输入0取消): " rule_num
    
    if [[ ! "$rule_num" =~ ^[0-9]+$ ]] || [ "$rule_num" -lt 0 ] || [ "$rule_num" -ge $index ]; then
        echo -e "${RED}无效的序号${NC}"
        read -p "按回车键返回主菜单..."
        return
    fi
    
    if [ "$rule_num" -eq 0 ]; then
        echo -e "${YELLOW}已取消修改${NC}"
        return
    fi
    
    # 显示修改菜单
    echo ""
    echo -e "${BLUE}请选择操作:${NC}"
    echo -e "  1) 修改本地端口"
    echo -e "  2) 修改远程IP和端口"
    echo -e "  3) 删除此规则"
    echo -e "  0) 取消"
    echo ""
    
    read -p "请选择 [0-3]: " action
    
    case $action in
        1)
            # 修改本地端口
            while true; do
                read -p "请输入新的本地端口 (1-65535): " new_local_port
                if [[ "$new_local_port" =~ ^[0-9]+$ ]] && [ "$new_local_port" -ge 1 ] && [ "$new_local_port" -le 65535 ]; then
                    # 检查端口是否已被使用（排除当前规则）
                    if grep -v '^#' "$CONFIG_FILE" | grep -v "^${rules[$rule_num]}$" | grep -q "^$new_local_port:"; then
                        echo -e "${RED}错误: 本地端口 $new_local_port 已被使用${NC}"
                    else
                        break
                    fi
                else
                    echo -e "${RED}错误: 请输入有效的端口号${NC}"
                fi
            done
            
            # 更新规则
            IFS=':' read old_local old_ip old_port <<< "${rules[$rule_num]}"
            new_rule="$new_local_port:$old_ip:$old_port"
            sed -i "s/^${rules[$rule_num]}$/$new_rule/" "$CONFIG_FILE"
            echo -e "${GREEN}本地端口已修改${NC}"
            ;;
            
        2)
            # 修改远程IP和端口
            while true; do
                read -p "请输入新的远程IP地址: " new_remote_ip
                if [[ "$new_remote_ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
                    break
                else
                    echo -e "${RED}错误: 请输入有效的IP地址${NC}"
                fi
            done
            
            while true; do
                read -p "请输入新的远程端口 (1-65535): " new_remote_port
                if [[ "$new_remote_port" =~ ^[0-9]+$ ]] && [ "$new_remote_port" -ge 1 ] && [ "$new_remote_port" -le 65535 ]; then
                    break
                else
                    echo -e "${RED}错误: 请输入有效的端口号${NC}"
                fi
            done
            
            # 更新规则
            IFS=':' read old_local old_ip old_port <<< "${rules[$rule_num]}"
            new_rule="$old_local:$new_remote_ip:$new_remote_port"
            sed -i "s/^${rules[$rule_num]}$/$new_rule/" "$CONFIG_FILE"
            echo -e "${GREEN}远程地址已修改${NC}"
            ;;
            
        3)
            # 删除规则
            read -p "确认删除此规则? (y/n): " confirm
            if [[ "$confirm" =~ ^[Yy]$ ]]; then
                sed -i "/^${rules[$rule_num]}$/d" "$CONFIG_FILE"
                echo -e "${GREEN}规则已删除${NC}"
            else
                echo -e "${YELLOW}已取消删除${NC}"
            fi
            ;;
            
        0)
            echo -e "${YELLOW}已取消修改${NC}"
            return
            ;;
            
        *)
            echo -e "${RED}无效选择${NC}"
            read -p "按回车键返回主菜单..."
            return
            ;;
    esac
    
    # 重新生成并应用配置
    regenerate_nft_config
    echo -e "${GREEN}配置已更新并生效${NC}"
    
    read -p "按回车键返回主菜单..."
}

# 查看服务状态
show_status() {
    show_header
    echo -e "${YELLOW}服务状态${NC}"
    echo ""
    
    # 检查IP转发状态
    echo -e "${CYAN}IP转发状态:${NC}"
    ip_forward=$(cat /proc/sys/net/ipv4/ip_forward 2>/dev/null || echo "0")
    if [ "$ip_forward" = "1" ]; then
        echo -e "  IPv4转发: ${GREEN}已启用${NC}"
    else
        echo -e "  IPv4转发: ${RED}已禁用${NC}"
        echo -e "${YELLOW}正在尝试启用IP转发...${NC}"
        echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf
        echo 1 > /proc/sys/net/ipv4/ip_forward
        sysctl -p >/dev/null 2>&1
        if [ $(cat /proc/sys/net/ipv4/ip_forward 2>/dev/null) -eq 1 ]; then
            echo -e "  IPv4转发: ${GREEN}已启用${NC}"
        else
            echo -e "  IPv4转发: ${RED}启用失败${NC}"
        fi
    fi
    echo ""
    
    # 检查nftables服务
    echo -e "${CYAN}NFTables 状态:${NC}"
    if command -v nft &> /dev/null; then
        echo -e "  nftables: ${GREEN}已安装${NC}"
        
        # 检查规则是否已加载
        if nft list ruleset 2>/dev/null | grep -q "port-dnat"; then
            echo -e "  规则状态: ${GREEN}已加载${NC}"
        else
            echo -e "  规则状态: ${RED}未加载${NC}"
            echo -e "${YELLOW}正在尝试加载规则...${NC}"
            regenerate_nft_config
        fi
    else
        echo -e "  nftables: ${RED}未安装${NC}"
    fi
    echo ""
    
    # 检查系统服务状态
    echo -e "${CYAN}系统服务状态:${NC}"
    if [ -f "$SERVICE_FILE" ]; then
        if systemctl is-active nft-forward.service >/dev/null 2>&1; then
            echo -e "  nft-forward: ${GREEN}运行中${NC}"
        else
            echo -e "  nft-forward: ${RED}未运行${NC}"
        fi
        if systemctl is-enabled nft-forward.service >/dev/null 2>&1; then
            echo -e "  开机自启: ${GREEN}已启用${NC}"
        else
            echo -e "  开机自启: ${RED}未启用${NC}"
        fi
    else
        echo -e "  nft-forward: ${RED}服务文件不存在${NC}"
    fi
    echo ""
    
    # 显示当前nftables规则
    echo -e "${CYAN}当前NFTables规则:${NC}"
    echo ""
    nft list ruleset 2>/dev/null || echo -e "${RED}未找到规则或nftables未运行${NC}"
    echo ""
    
    read -p "按回车键返回主菜单..."
}

# 重启服务
restart_service() {
    show_header
    echo -e "${YELLOW}重启转发服务${NC}"
    echo ""
    
    # 重新生成并应用配置
    regenerate_nft_config
    
    # 重启服务
    if [ -f "$SERVICE_FILE" ]; then
        systemctl restart nft-forward.service 2>/dev/null
        if systemctl is-active nft-forward.service >/dev/null 2>&1; then
            echo -e "${GREEN}服务重启成功${NC}"
        else
            echo -e "${YELLOW}尝试启动服务...${NC}"
            systemctl start nft-forward.service 2>/dev/null
            if systemctl is-active nft-forward.service >/dev/null 2>&1; then
                echo -e "${GREEN}服务启动成功${NC}"
            else
                echo -e "${RED}服务启动失败${NC}"
            fi
        fi
    else
        echo -e "${YELLOW}服务文件不存在，仅重新加载规则${NC}"
    fi
    
    echo ""
    read -p "按回车键返回主菜单..."
}

# 停止服务
stop_service() {
    show_header
    echo -e "${YELLOW}停止转发服务${NC}"
    echo ""
    
    # 停止服务
    if [ -f "$SERVICE_FILE" ]; then
        systemctl stop nft-forward.service 2>/dev/null
    fi
    
    # 清空nftables规则
    nft flush ruleset 2>/dev/null || true
    
    echo -e "${GREEN}服务已停止，规则已清除${NC}"
    
    echo ""
    read -p "按回车键返回主菜单..."
}

# 重新加载规则
reload_rules() {
    show_header
    echo -e "${YELLOW}重新加载转发规则${NC}"
    echo ""
    
    # 重新生成并应用配置
    regenerate_nft_config
    
    echo ""
    read -p "按回车键返回主菜单..."
}

# 卸载服务
uninstall_service() {
    show_header
    echo -e "${RED}⚠️ 卸载转发服务 ⚠️${NC}"
    echo ""
    echo -e "${YELLOW}此操作将:${NC}"
    echo -e "  1. 停止nft-forward服务"
    echo -e "  2. 删除配置文件"
    echo -e "  3. 删除管理脚本"
    echo -e "  4. 清空nftables规则"
    echo -e "  5. 禁用系统服务"
    echo ""
    
    read -p "确认要卸载吗? (输入'y'确认): " confirm
    
    if [[ "$confirm" =~ ^[Yy]$ ]]; then
        # 停止服务
        systemctl stop nft-forward.service 2>/dev/null
        systemctl disable nft-forward.service 2>/dev/null
        
        # 删除服务文件
        rm -f "$SERVICE_FILE"
        systemctl daemon-reload
        
        # 删除配置文件
        rm -f "$CONFIG_FILE"
        
        # 删除管理脚本
        rm -f "$NB_SCRIPT"
        
        # 清空nftables规则
        nft flush ruleset 2>/dev/null || true
        
        echo -e "${GREEN}卸载完成${NC}"
        echo ""
        echo -e "${YELLOW}注意: /etc/nftables.conf 文件未被删除${NC}"
        echo -e "${YELLOW}如果需要，请手动删除或恢复${NC}"
    else
        echo -e "${YELLOW}卸载已取消${NC}"
    fi
    
    echo ""
    read -p "按回车键退出..."
    exit 0
}

# 主程序
main() {
    # 检查root权限
    if [[ $EUID -ne 0 ]]; then
        echo -e "${RED}错误: 此脚本必须以root权限运行${NC}"
        exit 1
    fi
    
    # 主循环
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
            0)
                echo -e "${GREEN}再见!${NC}"
                exit 0
                ;;
            *)
                echo -e "${RED}无效选择，请重新输入${NC}"
                sleep 2
                ;;
        esac
    done
}

# 处理命令行参数
case "$1" in
    "reload")
        regenerate_nft_config
        ;;
    "stop")
        nft flush ruleset 2>/dev/null || true
        ;;
    "status")
        show_status
        exit 0
        ;;
    "list")
        list_forwards
        exit 0
        ;;
    "start")
        regenerate_nft_config
        ;;
    *)
        # 如果没有参数，进入主菜单
        main
        ;;
esac
EOF
    
    # 设置可执行权限
    chmod +x "$NB_SCRIPT"
    
    echo -e "${GREEN}管理脚本已创建: $NB_SCRIPT${NC}"
    echo -e "${YELLOW}现在可以使用 'nb' 命令管理端口转发${NC}"
}

# 启动服务
start_services() {
    echo -e "${BLUE}启动服务...${NC}"
    
    # 重新生成并应用配置
    regenerate_nft_config
    
    # 确保nftables规则生效
    nft -f "$RULES_FILE" 2>/dev/null || true
    
    # 启动转发服务
    systemctl enable nft-forward.service
    systemctl start nft-forward.service
    
    if systemctl is-active nft-forward.service >/dev/null 2>&1; then
        echo -e "${GREEN}服务启动成功${NC}"
    else
        echo -e "${YELLOW}服务启动失败，但配置已应用${NC}"
    fi
    
    # 确保IP转发已启用
    echo 1 > /proc/sys/net/ipv4/ip_forward
}

# 完成安装
complete_installation() {
    show_header
    echo -e "${GREEN}========================================${NC}"
    echo -e "${GREEN}        安装完成！                   ${NC}"
    echo -e "${GREEN}========================================${NC}"
    echo ""
    echo -e "${YELLOW}已安装组件:${NC}"
    echo -e "  ✓ nftables"
    echo -e "  ✓ nftables配置文件: $RULES_FILE"
    echo -e "  ✓ 转发配置文件: $CONFIG_FILE"
    echo -e "  ✓ 系统服务: nft-forward.service"
    echo -e "  ✓ 管理命令: nb"
    echo ""
    echo -e "${YELLOW}使用方法:${NC}"
    echo -e "  1. 运行 'nb' 命令进入管理菜单"
    echo -e "  2. 选择 '1' 添加端口转发"
    echo -e "  3. 选择 '2' 查看转发列表"
    echo -e "  4. 选择 '4' 查看服务状态"
    echo ""
    echo -e "${YELLOW}快速命令:${NC}"
    echo -e "  nb             # 进入管理菜单"
    echo -e "  nb reload      # 重新加载规则"
    echo -e "  nb status      # 查看状态"
    echo -e "  nb list        # 查看规则列表"
    echo -e "  nb start       # 启动转发"
    echo -e "  nb stop        # 停止转发"
    echo ""
    echo -e "${GREEN}现在可以开始使用端口转发功能了！${NC}"
    echo ""
    echo -e "${YELLOW}添加示例转发规则:${NC}"
    echo -e "  sudo nb"
    echo -e "  选择 1"
    echo -e "  输入本地端口: 8080"
    echo -e "  输入远程IP: 192.168.1.100"
    echo -e "  输入远程端口: 80"
    echo ""
    echo -e "${YELLOW}注意: 所有转发将同时启用TCP和UDP${NC}"
}

# 主安装函数
main_install() {
    check_root
    show_header
    install_nftables
    create_nftables_config
    create_config_file
    enable_ip_forward
    create_systemd_service
    create_nb_script
    start_services
    complete_installation
}

# 运行安装
main_install