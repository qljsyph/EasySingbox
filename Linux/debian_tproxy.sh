#!/bin/bash

#################################################
# 描述: Debian/Ubuntu/Armbian sing-box TProxy模式 配置脚本
# 版本: 1.1.0
# 作者: Youtube: 七尺宇
# 功能: 更新替换配置文件，添加tproxy防火墙规则
#################################################

# 配置参数
BACKEND_URL="http://192.168.50.10:5000"                       # 后端服务器地址
SUBSCRIPTION_URL=""   # 订阅地址 Clash.Meta(mihomo)
TEMPLATE_URL="https://raw.githubusercontent.com/qljsyph/rule/refs/heads/main/op-singbox/sing-box-beta/tproxy-dev-3.json"  # 配置模板（确保使用tproxy入站）
TPROXY_PORT=7895                                              # TProxy 端口
PROXY_FWMARK=1                                                # 防火墙标记
PROXY_ROUTE_TABLE=100                                         # 路由表编号

# 检查是否以 root 权限运行并且 sing-box 是否已安装
[ "$(id -u)" != "0" ] && { echo "错误: 此脚本需要 root 权限"; exit 1; }
command -v sing-box &> /dev/null || { echo "错误: sing-box 未安装"; exit 1; }

# 停止 sing-box 服务并重置防火墙
systemctl stop sing-box && nft flush ruleset

# 构建完整的配置文件 URL
FULL_URL="${BACKEND_URL}/config/${SUBSCRIPTION_URL}&file=${TEMPLATE_URL}"

echo -e "\033[34m==============================================================================\033[0m"
echo -e "\033[33m*生成完整订阅链接: \033[0m\033[36m$FULL_URL\033[0m"
echo -e "\033[34m==============================================================================\033[0m"

# 备份当前配置
[ -f "/etc/sing-box/config.json" ] && cp /etc/sing-box/config.json /etc/sing-box/config.json.backup

# 下载并验证配置文件
if curl -L --connect-timeout 10 --max-time 30 "$FULL_URL" -o /etc/sing-box/config.json; then
    echo "配置文件下载成功"
    if ! sing-box check -c /etc/sing-box/config.json; then
        echo -e "\033[31m*** 配置文件验证失败，请检查配置文件格式及参数，正在还原备份 ***\033[0m"
        [ -f "/etc/sing-box/config.json.backup" ] && cp /etc/sing-box/config.json.backup /etc/sing-box/config.json
        exit 1
    fi
else
    echo -e "\033[31m*** 配置文件下载失败,请复制完整订阅链接，在浏览器是否可以正常打开! ***\033[0m"
    exit 1
fi

# 获取默认网络接口（如果无法获取，使用 lo）
INTERFACE=$(ip route show default | awk '/default/ {print $5}' || echo lo)

# 应用基础防火墙配置
cat <<EOF | nft -f -
table inet filter {
    chain input { type filter hook input priority 0; policy accept; }
    chain forward { type filter hook forward priority 0; policy accept; }
    chain output { type filter hook output priority 0; policy accept; }
}
EOF

# 配置 TProxy 相关规则
cat > /etc/nftables.conf <<EOF
#!/usr/sbin/nft -f
table inet sing-box {
    chain prerouting_tproxy {
        type filter hook prerouting priority mangle; policy accept;
        meta l4proto { tcp, udp } th dport 53 tproxy to :$TPROXY_PORT accept comment "DNS透明代理"
        fib daddr type local meta l4proto { tcp, udp } th dport $TPROXY_PORT reject with icmpx type host-unreachable comment "防止回环"
        fib daddr type local accept comment "本机流量绕过"
        ip daddr { 127.0.0.0/8, 10.0.0.0/16, 192.168.0.0/16, 100.64.0.0/10, 169.254.0.0/16, 172.16.0.0/12, 224.0.0.0/4, 240.0.0.0/4, 255.255.255.255/32 } accept comment "保留地址绕过"
        meta l4proto { tcp, udp } tproxy to :$TPROXY_PORT meta mark set $PROXY_FWMARK comment "其他流量透明代理"
    }
    chain output_tproxy {
        type route hook output priority mangle; policy accept;
        oifname != "$INTERFACE" accept comment "绕过本机内部通信的流量"
        meta mark $PROXY_FWMARK accept comment "绕过已标记流量"
        meta l4proto { tcp, udp } th dport 53 meta mark set $PROXY_FWMARK accept comment "DNS流量标记"
        ip daddr { 127.0.0.0/8, 10.0.0.0/16, 192.168.0.0/16, 100.64.0.0/10, 169.254.0.0/16, 172.16.0.0/12, 224.0.0.0/4, 240.0.0.0/4, 255.255.255.255/32 } accept comment "保留地址绕过"
        meta l4proto { tcp, udp } meta mark set $PROXY_FWMARK comment "其他流量标记"
    }
}
EOF

# 设置正确的权限
chmod 640 /etc/nftables.conf

# 配置路由规则
ip rule show | grep -q "fwmark $PROXY_FWMARK lookup $PROXY_ROUTE_TABLE" || ip rule add fwmark $PROXY_FWMARK table $PROXY_ROUTE_TABLE
ip route show table $PROXY_ROUTE_TABLE | grep -q "local default dev lo" || ip route add local default dev lo table $PROXY_ROUTE_TABLE

# 重启 nftables 和 sing-box 服务
systemctl restart nftables sing-box

# 检查服务是否启动成功
if systemctl is-active --quiet sing-box && systemctl is-active --quiet nftables; then
    echo -e "\033[36m===========================================================\033[0m"
    echo -e "\033[32m******** sing-box 启动成功，运行模式: TProxy ********\033[0m"
else
    echo -e "\033[36m===========================================================\033[0m"
    echo -e "\033[31m******** 服务启动失败，请使用下方命令排查原因! ********\033[0m"
fi

# 显示常用命令
echo -e "\033[36m===========================================================\033[0m"
echo -e "\033[33m* 常用命令：\033[0m"
echo -e "\033[32m* 检查singbox: \033[0m\033[36msystemctl status sing-box.service\033[0m"
echo -e "\033[32m* 查看实时日志: \033[0m\033[36mjournalctl -u sing-box --output cat -f\033[0m"
echo -e "\033[32m* 检查配置文件: \033[0m\033[36msing-box check -c /etc/sing-box/config.json\033[0m"
echo -e "\033[32m* 运行singbox: \033[0m\033[36msing-box run -c /etc/sing-box/config.json\033[0m"
echo -e "\033[32m* 查看nf防火墙: \033[0m\033[36mnft list ruleset\033[0m"
echo -e "\033[36m===========================================================\033[0m"

# 启动失败时退出
if [ $? -ne 0 ]; then
    exit 1
fi
