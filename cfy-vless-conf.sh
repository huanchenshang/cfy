#!/bin/bash

# --- 脚本配置 & 工具检查 ---
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

# 配置文件路径
REALITY_CONF="/etc/sing-box/conf/11_xtls-reality_inbounds.json"
WS_TLS_CONF="/etc/sing-box/conf/18_vless-ws-tls_inbounds.json"
# 尝试从 Reality 文件头读取公钥（通常以注释形式存在）
PUBLIC_KEY_COMMENT_LINE=$(head -n 1 "$REALITY_CONF" 2>/dev/null)
# 设置目标生成数量
TARGET_COUNT=6

check_deps() {
    for cmd in jq curl grep sed mktemp shuf head; do
        if ! command -v "$cmd" &> /dev/null; then
            echo -e "${RED}错误: 命令 '$cmd' 未找到. 请先安装它.${NC}"
            exit 1
        fi
    done
}

# --- IP 获取函数 ---
get_all_optimized_ips() {
    local url_v4="https://www.wetest.vip/page/cloudflare/address_v4.html"
    local url_v6="https://www.wetest.vip/page/cloudfront/address_v6.html"
    
    echo -e "${YELLOW}正在合并获取所有优选 IP (IPv4 & IPv6)...${NC}"
    
    local paired_data_file
    paired_data_file=$(mktemp)
    trap 'rm -f "$paired_data_file"' EXIT

    parse_url() {
        local url="$1"; local type_desc="$2"
        echo -e "  -> 正在获取 ${type_desc} 列表..."
        local html_content=$(curl -s "$url")
        if [ -z "$html_content" ]; then echo -e "${RED}  -> 获取 ${type_desc} 列表失败!${NC}"; return; fi
        local table_rows=$(echo "$html_content" | tr -d '\n\r' | sed 's/<tr>/\n&/g' | grep '^<tr>')
        local ips=$(echo "$table_rows" | sed -n 's/.*data-label="优选地址">\([^<]*\)<.*/\1/p')
        local isps=$(echo "$table_rows" | sed -n 's/.*data-label="线路名称">\([^<]*\)<.*/\1/p')
        paste -d' ' <(echo "$ips") <(echo "$isps") >> "$paired_data_file"
    }

    parse_url "$url_v4" "IPv4"; parse_url "$url_v6" "IPv6"

    if ! [ -s "$paired_data_file" ]; then echo -e "${RED}无法从任何来源解析出优选 IP 地址.${NC}"; return 1; fi

    declare -g -a ip_list isp_list; local shuffled_pairs
    mapfile -t shuffled_pairs < <(shuf "$paired_data_file")
    for pair in "${shuffled_pairs[@]}"; do
        ip_list+=("$(echo "$pair" | cut -d' ' -f1)")
        isp_list+=("$(echo "$pair" | cut -d' ' -f2-)")
    done
    if [ ${#ip_list[@]} -eq 0 ]; then echo -e "${RED}解析成功, 但未找到任何有效的 IP 地址.${NC}"; return 1; fi
    echo -e "${GREEN}成功合并获取 ${#ip_list[@]} 个优选 IP 地址, 列表已随机打乱.${NC}"; return 0
}

# --- VLESS REALITY 解析并生成函数 ---
generate_reality_nodes() {
    local conf_path="$1"; local conf_tag="$2"; local num_to_generate="$3"
    
    echo -e "\n${YELLOW}--- 正在解析 VLESS Reality 配置: $conf_tag ---${NC}"

    # 从JSON中提取配置
    local uuid=$(jq -r '.inbounds[0].users[0].uuid' "$conf_path")
    local port=$(jq -r '.inbounds[0].listen_port' "$conf_path")
    local sni=$(jq -r '.inbounds[0].tls.server_name' "$conf_path")
    # 默认 flow 为 xtls-rprx-vision
    local flow=$(jq -r '.inbounds[0].users[0].flow' "$conf_path" | grep -v '^null$' || echo "xtls-rprx-vision") 

    # 从文件头注释中提取 Public Key
    local public_key=""
    if [[ "$PUBLIC_KEY_COMMENT_LINE" =~ \"public_key\":\"([^"]*)\" ]]; then
        public_key="${BASH_REMATCH[1]}"
    fi
    
    if [ -z "$uuid" ] || [ -z "$port" ] || [ -z "$sni" ] || [ -z "$public_key" ]; then
        echo -e "${RED}❌ 无法从 $conf_tag 提取完整的 VLESS Reality 配置 (UUID/Port/SNI/Public Key).${NC}"
        echo -e "${RED}   请检查 $conf_path 文件头是否包含公钥注释：// \"public_key\":\"...\"${NC}"
        return 1
    fi

    echo -e "  ✅ 基础参数提取成功: UUID=$uuid, Port=$port, SNI=$sni"
    echo -e "  ✅ Public Key: $public_key"

    echo "---"; echo -e "${YELLOW}开始生成 ${num_to_generate} 个 ${conf_tag} 优选链接:${NC}"

    # 循环次数被 num_to_generate 限制
    for ((i=0; i<$num_to_generate; i++)); do
        local current_ip=${ip_list[$i]}
        local isp_name=${isp_list[$i]}
        
        local new_remark="${conf_tag}-${isp_name}"
        
        # 构造 VLESS Reality URI
        local new_url="vless://${uuid}@${current_ip}:${port}?security=reality&sni=${sni}&fp=chrome&pbk=${public_key}"
        
        if [ -n "$flow" ]; then
            new_url="${new_url}&flow=${flow}"
        fi
        
        new_url="${new_url}#${new_remark}"
        
        echo "$new_url"
    done
    return 0
}


# --- VLESS WS-TLS 解析并生成函数 ---
generate_ws_tls_nodes() {
    local conf_path="$1"; local conf_tag="$2"; local num_to_generate="$3"
    
    echo -e "\n${YELLOW}--- 正在解析 VLESS WS-TLS 配置: $conf_tag ---${NC}"

    # 从JSON中提取配置
    local uuid=$(jq -r '.inbounds[0].users[0].uuid' "$conf_path")
    local port=$(jq -r '.inbounds[0].listen_port' "$conf_path")
    local host=$(jq -r '.inbounds[0].tls.server_name' "$conf_path")
    local path=$(jq -r '.inbounds[0].transport.path' "$conf_path")
    
    if [ -z "$uuid" ] || [ -z "$port" ] || [ -z "$host" ] || [ -z "$path" ]; then
        echo -e "${RED}❌ 无法从 $conf_tag 提取完整的 VLESS WS-TLS 配置 (UUID/Port/Host/Path).${NC}"
        return 1
    fi

    # 清理路径 (确保 URL-safe)
    path=$(echo "$path" | sed 's/^\///') # 移除开头的 /

    echo -e "  ✅ 基础参数提取成功: UUID=$uuid, Port=$port, Host=$host, Path=/$path"

    echo "---"; echo -e "${YELLOW}开始生成 ${num_to_generate} 个 ${conf_tag} 优选链接:${NC}"

    # 循环次数被 num_to_generate 限制
    for ((i=0; i<$num_to_generate; i++)); do
        local current_ip=${ip_list[$i]}
        local isp_name=${isp_list[$i]}
        
        local new_remark="${conf_tag}-${isp_name}"
        
        # 构造 VLESS WS-TLS URI
        local new_url="vless://${uuid}@${current_ip}:${port}?security=tls&type=ws&host=${host}&path=/${path}#${new_remark}"
        
        echo "$new_url"
    done
    return 0
}


# --- 主程序 ---
main() {
    echo -e "${GREEN}=================================================="
    echo -e " VLESS 配置优选生成器"
    echo -e " (目标生成数量: ${TARGET_COUNT} 个节点)"
    echo -e "==================================================${NC}"
    echo ""
    
    # 1. 检查依赖
    check_deps
    
    # 2. 获取优选 IP 列表
    declare -a ip_list isp_list
    get_all_optimized_ips || exit 1
    
    # 3. 确定实际生成的数量
    local total_ips=${#ip_list[@]}
    local num_to_generate=$(( total_ips < TARGET_COUNT ? total_ips : TARGET_COUNT ))

    echo -e "${YELLOW}已获取 ${total_ips} 个优选 IP，将生成前 ${num_to_generate} 个链接.${NC}"
    
    # 4. 选择要生成的模式
    echo -e "\n${YELLOW}请选择要生成的节点类型:${NC}"
    echo "  1) VLESS Reality (${REALITY_CONF})"
    echo "  2) VLESS WS-TLS (${WS_TLS_CONF})"
    echo "  3) 两种都生成"
    
    local choice
    while true; do
        read -p "请输入选项编号 (1-3): " choice
        if [[ "$choice" =~ ^[1-3]$ ]]; then break;
        else echo -e "${RED}无效的输入, 请重试.${NC}"; fi
    done

    # 5. 根据选择生成节点
    if [[ "$choice" == "1" || "$choice" == "3" ]]; then
        if [ -f "$REALITY_CONF" ]; then
            generate_reality_nodes "$REALITY_CONF" "Reality" "$num_to_generate"
        else
            echo -e "${RED}⚠️ 警告: 配置文件 $REALITY_CONF 不存在.${NC}"
        fi
    fi

    if [[ "$choice" == "2" || "$choice" == "3" ]]; then
        if [ -f "$WS_TLS_CONF" ]; then
            generate_ws_tls_nodes "$WS_TLS_CONF" "WS-TLS" "$num_to_generate"
        else
            echo -e "${RED}⚠️ 警告: 配置文件 $WS_TLS_CONF 不存在.${NC}"
        fi
    fi
    
    echo -e "\n${GREEN}=================================================="
    echo -e "所有优选链接已生成完毕 (共 ${num_to_generate} 个)."
    echo -e "==================================================${NC}"
}

main