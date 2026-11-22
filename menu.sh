#!/usr/bin/env bash
# wg-v4-exit — 给纯 IPv6 服务器借一台双栈 VPS 做 IPv4 出口
# 交互面板：选择本机角色（出口机 / 应用机）→ 逐级填写 → 汇总确认 → 生成配置并输出连接信息
# 出口机：双栈 VPS，WireGuard 服务端 + NAT 转发
# 应用机：纯 IPv6 服务器，WireGuard 客户端，只把 IPv4 默认路由走隧道，IPv6 原生直出
# 私钥在本机生成、只留在本机，两台机器之间只交换公钥。

VERSION="1.0.1"
IFACE_NAME="v4exit"
WG_DIR="/etc/wireguard"
CONF="$WG_DIR/$IFACE_NAME.conf"
KEY_FILE="$WG_DIR/v4exit.key"
PUB_FILE="$WG_DIR/v4exit.pub"
STATE_FILE="$WG_DIR/v4exit.state"
DRY_RUN="${DRY_RUN:-0}"
SHORTCUT="/usr/local/bin/v4exit"
RAW_URL="https://raw.githubusercontent.com/emmaforge/wg-v4-exit/main/menu.sh"
[ "${1:-}" = "--dry-run" ] && DRY_RUN=1

if [ -t 1 ]; then
C_OK='\033[0;32m'; C_WARN='\033[0;33m'; C_ERR='\033[0;31m'; C_TTL='\033[0;36m'; C_OFF='\033[0m'
else
C_OK=''; C_WARN=''; C_ERR=''; C_TTL=''; C_OFF=''
fi

say() { printf '%b\n' "$*";}
ok() { say "${C_OK}✔ $*${C_OFF}";}
warn() { say "${C_WARN}⚠ $*${C_OFF}";}
die() { say "${C_ERR}✘ $*${C_OFF}"; exit 1;}

# ask "问题" "默认值" 变量名 —— 带默认值的逐级填写，直接回车用默认值
ask() {
local prompt="$1" def="${2:-}" var="$3" val=""
if [ -n "$def" ]; then
read -r -p "$prompt [$def]: " val || true
val="${val:-$def}"
else
read -r -p "$prompt: " val || true
fi
printf -v "$var" '%s' "$val"
}

# ask_req "问题" 变量名 —— 必填，空了重问
ask_req() {
local prompt="$1" var="$2" val=""
while [ -z "$val" ]; do
read -r -p "$prompt（必填）: " val || true
[ -z "$val" ] && warn "这一项不能为空"
done
printf -v "$var" '%s' "$val"
}

confirm() {
local ans=""
read -r -p "$1 [y/N]: " ans || true
case "$ans" in y|Y|yes|YES) return 0;; *) return 1;; esac
}

box() {
say ""
say "================================================================"
say "$1"
say "================================================================"
shift
for line in "$@"; do say "$line"; done
say "================================================================"
say ""
}


# install_shortcut —— 把脚本注册成系统指令 v4exit，之后终端输 v4exit 就能呼出面板
install_shortcut() {
[ "$DRY_RUN" = "1" ] && return 0
[ "$(id -u)" = "0" ] || return 0
if [ -f "$0" ] && [ "$0" != "$SHORTCUT" ]; then
cp -f "$0" "$SHORTCUT" 2>/dev/null || true
elif [ ! -f "$SHORTCUT" ]; then
curl -sSL "$RAW_URL" -o "$SHORTCUT" 2>/dev/null || wget -qO "$SHORTCUT" "$RAW_URL" 2>/dev/null || true
fi
[ -f "$SHORTCUT" ] && chmod +x "$SHORTCUT" && ok "快捷指令已注册：以后终端输入 v4exit 即可呼出面板"
return 0
}

check_root_os() {
[ "$DRY_RUN" = "1" ] && return 0
[ "$(id -u)" = "0" ] || die "请用 root 运行（sudo -i 后再执行）"
[ -f /etc/os-release ] || die "无法识别系统"
. /etc/os-release
case "$ID" in
debian|ubuntu);;
*) die "目前只支持 Debian / Ubuntu（检测到 $ID），其他系统请按 README 手动配置";;
esac
}

install_deps() {
if command -v wg >/dev/null 2>&1; then ok "wireguard 已安装"; return 0; fi
say "正在安装 wireguard / iptables..."
if [ "$DRY_RUN" = "1" ]; then say "[dry-run] 跳过 apt 安装"; return 0; fi
apt-get update -qq && apt-get install -y -qq wireguard iptables >/dev/null || die "依赖安装失败"
ok "依赖安装完成"
}

# gen_keys —— 已有密钥就复用（重装不换钥，另一端不用改），没有才生成
gen_keys() {
if [ "$DRY_RUN" = "1" ]; then
PRIV_KEY="DRYRUN-PRIVATE-KEY-NOT-REAL"
PUB_KEY="DRYRUNPUBKEY0000000000000000000000000000000="
say "[dry-run] 使用假密钥演示"
return 0
fi
umask 077
mkdir -p "$WG_DIR"
if [ -s "$KEY_FILE" ]; then
ok "复用已有密钥（公钥不变，另一端无需修改）"
else
wg genkey > "$KEY_FILE"
wg pubkey < "$KEY_FILE" > "$PUB_FILE"
ok "已生成新密钥（私钥只保存在本机 $KEY_FILE）"
fi
PRIV_KEY="$(cat "$KEY_FILE")"
PUB_KEY="$(cat "$PUB_FILE")"
}

public_ip() { # $1 = -4 / -6
curl "$1" -s -m 6 https://ip.sb 2>/dev/null || echo "获取失败"
}

save_state() { # key=value...
[ "$DRY_RUN" = "1" ] && return 0
: > "$STATE_FILE"
for kv in "$@"; do echo "$kv" >> "$STATE_FILE"; done
}

# ---------------- 出口机（双栈 VPS，服务端 + NAT） ----------------
install_server() {
box "安装向导 · 出口机（双栈 VPS）" "本机将作为 IPv4 出口：开 WireGuard 服务端 + NAT 转发" "应用机的全部 IPv4 流量会从本机的 IPv4 地址出去"
local def_iface port srv_addr cli_ip cli_pub mtu
def_iface="$(ip -4 route show default 2>/dev/null | awk '{print $5; exit}')"
[ -z "$def_iface" ] && def_iface="eth0"

say "${C_TTL}第 1/5 步：出口网卡${C_OFF}"
ask "本机访问外网的 IPv4 网卡名" "$def_iface" def_iface
say "${C_TTL}第 2/5 步：监听端口${C_OFF}"
ask "WireGuard UDP 监听端口" "51820" port
say "${C_TTL}第 3/5 步：隧道内网地址${C_OFF}"
ask "本机隧道地址（带掩码）" "10.66.66.1/24" srv_addr
ask "应用机隧道地址（不带掩码）" "10.66.66.2" cli_ip
cli_ip="${cli_ip%%/*}"
say "${C_TTL}第 4/5 步：应用机公钥${C_OFF}"
say "如果应用机还没装，可以先留空，装完后在本机菜单选 4 补填"
ask "应用机公钥（可留空）" "" cli_pub
if [ -n "$cli_pub" ] && [ "${#cli_pub}" != "44" ]; then
die "公钥长度不对（应为 44 个字符），请检查有没有复制漏字"
fi
say "${C_TTL}第 5/5 步：MTU${C_OFF}"
ask "隧道 MTU" "1380" mtu

box "请确认出口机配置" \
"角色: 出口机（服务端）" \
"出口网卡: $def_iface" \
"监听端口: $port/udp" \
"本机隧道地址: $srv_addr" \
"应用机隧道地址: $cli_ip/32" \
"应用机公钥: ${cli_pub:-（暂未填，之后用菜单 4 补）}" \
"MTU: $mtu"
confirm "确认无误，开始安装？" || { say "已取消，没有改动任何配置"; exit 0;}

local srv_net="$(echo "${srv_addr%/*}" | awk -F. '{print $1"."$2"."$3".0"}')/${srv_addr#*/}"
install_deps
gen_keys
local peer_block=""
if [ -n "$cli_pub" ]; then
peer_block="[Peer]
PublicKey = $cli_pub
AllowedIPs = $cli_ip/32"
fi

if [ "$DRY_RUN" = "1" ]; then
mkdir -p ./dryrun-output
cat >./dryrun-output/server-v4exit.conf <<EOF
[Interface]
Address = $srv_addr
ListenPort = $port
PrivateKey = $PRIV_KEY
MTU = $mtu
PostUp = iptables -t nat -A POSTROUTING -s $srv_net -o $def_iface -j MASQUERADE; iptables -A FORWARD -i %i -j ACCEPT; iptables -A FORWARD -o %i -j ACCEPT
PostDown = iptables -t nat -D POSTROUTING -s $srv_net -o $def_iface -j MASQUERADE; iptables -D FORWARD -i %i -j ACCEPT; iptables -D FORWARD -o %i -j ACCEPT
$peer_block
EOF
ok "[dry-run] 配置已写到 ./dryrun-output/server-v4exit.conf"
else
echo "net.ipv4.ip_forward=1" > /etc/sysctl.d/99-v4exit.conf
sysctl -p /etc/sysctl.d/99-v4exit.conf >/dev/null
cat > "$CONF" <<EOF
[Interface]
Address = $srv_addr
ListenPort = $port
PrivateKey = $PRIV_KEY
MTU = $mtu
PostUp = iptables -t nat -A POSTROUTING -s $srv_net -o $def_iface -j MASQUERADE; iptables -A FORWARD -i %i -j ACCEPT; iptables -A FORWARD -o %i -j ACCEPT
PostDown = iptables -t nat -D POSTROUTING -s $srv_net -o $def_iface -j MASQUERADE; iptables -D FORWARD -i %i -j ACCEPT; iptables -D FORWARD -o %i -j ACCEPT
$peer_block
EOF
chmod 600 "$CONF"
if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q "Status: active"; then
ufw allow "$port/udp" >/dev/null && ok "ufw 已放行 $port/udp"
fi
systemctl enable --now "wg-quick@$IFACE_NAME" || die "服务启动失败，用 systemctl status wg-quick@$IFACE_NAME 看原因"
save_state "ROLE=server" "PORT=$port" "TUNNEL_ADDR=$srv_addr" "PEER_IP=$cli_ip"
ok "出口机服务已启动"
fi

box "出口机安装完成 · 把下面信息填到应用机上" \
"本机公网 IPv6: $(public_ip -6)" \
"本机公网 IPv4（最终出口）: $(public_ip -4)" \
"本机公钥: $PUB_KEY" \
"监听端口: $port" \
"隧道地址: $srv_addr" \
"" \
"下一步: 在应用机运行本脚本选 2，把上面的 IPv6 / 公钥 / 端口填进去" \
    "快捷指令: 本机终端输入 v4exit 随时呼出面板（补公钥选菜单 4）" \
"提醒: 商家面板/安全组要放行 ${port}/udp 的 IPv6 入站" \
"$( [ -z "$cli_pub" ] && echo '注意: 你还没填应用机公钥，应用机装完后在本机菜单选 4 补填，否则隧道握不上手')"
}

# ---------------- 应用机（纯 IPv6 服务器，客户端） ----------------
install_client() {
box "安装向导 · 应用机（纯 IPv6 服务器）" "本机将获得 IPv4 出口：只有 IPv4 默认路由走隧道" "原生 IPv6 完全不动，SSH 和 v6 访问不受隧道影响"
local endpoint port srv_pub cli_addr srv_ip mtu
say "${C_TTL}第 1/5 步：出口机地址${C_OFF}"
ask_req "出口机公网 IPv6（出口机完成页里有）" endpoint
endpoint="${endpoint#[}"; endpoint="${endpoint%]}"
ask "出口机监听端口" "51820" port
say "${C_TTL}第 2/5 步：出口机公钥${C_OFF}"
ask_req "出口机公钥（出口机完成页里有）" srv_pub
[ "${#srv_pub}" = "44" ] || die "公钥长度不对（应为 44 个字符），请检查有没有复制漏字"
say "${C_TTL}第 3/5 步：隧道内网地址${C_OFF}"
ask "本机隧道地址（带掩码）" "10.66.66.2/32" cli_addr
ask "出口机隧道地址（不带掩码）" "10.66.66.1" srv_ip
srv_ip="${srv_ip%%/*}"
say "${C_TTL}第 4/5 步：MTU${C_OFF}"
ask "隧道 MTU" "1380" mtu
say "${C_TTL}第 5/5 步：冲突检查${C_OFF}"
if [ "$DRY_RUN" != "1" ] && { command -v warp >/dev/null 2>&1 || ip link show warp >/dev/null 2>&1;}; then
warn "检测到 WARP 还在，它也会抢 IPv4 默认路由，和本隧道冲突"
if confirm "现在卸载 WARP（warp u）？"; then warp u || warn "warp u 执行失败，请手动处理后再继续"; fi
else
ok "没有检测到 WARP 冲突"
fi

local ep_fmt="$endpoint:$port"
case "$endpoint" in *:*) ep_fmt="[$endpoint]:$port";; esac

box "请确认应用机配置" \
"角色: 应用机（客户端）" \
"出口机 Endpoint: $ep_fmt" \
"出口机公钥: $srv_pub" \
"本机隧道地址: $cli_addr" \
"出口机隧道地址: $srv_ip" \
"MTU: $mtu" \
"走向: IPv4 → 隧道出口 / IPv6 → 原生直出"
confirm "确认无误，开始安装？" || { say "已取消，没有改动任何配置"; exit 0;}

install_deps
gen_keys
local conf_body="[Interface]
Address = $cli_addr
PrivateKey = $PRIV_KEY
MTU = $mtu

[Peer]
PublicKey = $srv_pub
Endpoint = $ep_fmt
AllowedIPs = 0.0.0.0/0
PersistentKeepalive = 25"

if [ "$DRY_RUN" = "1" ]; then
mkdir -p ./dryrun-output
echo "$conf_body" >./dryrun-output/client-v4exit.conf
ok "[dry-run] 配置已写到 ./dryrun-output/client-v4exit.conf"
else
echo "$conf_body" > "$CONF"
chmod 600 "$CONF"
systemctl enable --now "wg-quick@$IFACE_NAME" || die "服务启动失败，用 systemctl status wg-quick@$IFACE_NAME 看原因"
save_state "ROLE=client" "ENDPOINT=$ep_fmt" "TUNNEL_ADDR=$cli_addr" "SERVER_TUNNEL_IP=$srv_ip"
ok "应用机服务已启动，正在自检..."
sleep 2
fi

local t_tunnel="（dry-run 未测）" t_v4="$t_tunnel" t_v6="$t_tunnel"
if [ "$DRY_RUN" != "1" ]; then
ping -c1 -W3 "$srv_ip" >/dev/null 2>&1 && t_tunnel="通" || t_tunnel="不通（多半是出口机还没补填本机公钥）"
t_v4="$(public_ip -4)"; t_v6="$(public_ip -6)"
fi

box "应用机安装完成 · 把本机公钥填回出口机" \
"本机公钥: $PUB_KEY" \
"（出口机运行本脚本选 4，粘贴这个公钥，隧道才能握上手）" \
"" \
"自检 隧道 ping 出口机: $t_tunnel" \
"自检 IPv4 出口: $t_v4（应是出口机的 IPv4）" \
"自检 IPv6 出口: $t_v6（应是本机原生 IPv6）" \
"常用验证: ping github.com / curl -4 ip.sb / curl -6 ip.sb" \
    "快捷指令: 本机终端输入 v4exit 随时呼出面板"
}

# ---------------- 管理功能 ----------------
show_info() {
box "本机连接信息" \
"角色: $(grep -s '^ROLE=' "$STATE_FILE" 2>/dev/null | cut -d= -f2 || echo 未知)" \
"本机公钥: $(cat "$PUB_FILE" 2>/dev/null || echo 无)" \
"公网 IPv4: $(public_ip -4)" \
"公网 IPv6: $(public_ip -6)" \
"接口状态:"
wg show "$IFACE_NAME" 2>/dev/null || say "接口 $IFACE_NAME 未运行"
}

update_peer() {
[ "$DRY_RUN" = "1" ] || [ -f "$CONF" ] || die "本机还没有配置，先选 1 安装出口机"
local pub ip
ask_req "新的应用机公钥" pub
[ "${#pub}" = "44" ] || die "公钥长度不对（应为 44 个字符）"
ask "应用机隧道地址（不带掩码）" "10.66.66.2" ip
ip="${ip%%/*}"
if [ "$DRY_RUN" = "1" ]; then ok "[dry-run] 将把 Peer 更新为 $pub / $ip/32"; return 0; fi
if grep -q "^\[Peer\]" "$CONF"; then
sed -i "s|^PublicKey =.*|PublicKey = $pub|" "$CONF"
sed -i "s|^AllowedIPs =.*|AllowedIPs = $ip/32|" "$CONF"
else
printf '\n[Peer]\nPublicKey = %s\nAllowedIPs = %s/32\n' "$pub" "$ip" >> "$CONF"
fi
if ! wg syncconf "$IFACE_NAME" <(wg-quick strip "$IFACE_NAME") 2>/dev/null; then
systemctl restart "wg-quick@$IFACE_NAME" || die "配置已写入但服务重启失败，先修配置再试：systemctl status wg-quick@$IFACE_NAME"
fi
wg show "$IFACE_NAME" >/dev/null 2>&1 || die "配置已写入但接口未运行，检查：wg show $IFACE_NAME"
ok "Peer 已更新，应用机现在应该能握上手（在应用机 ping 本机隧道地址验证）"
}

uninstall() {
confirm "确认卸载？将停用并删除 $CONF 和密钥" || { say "已取消"; exit 0;}
if [ "$DRY_RUN" = "1" ]; then ok "[dry-run] 假装卸载完成"; return 0; fi
systemctl disable --now "wg-quick@$IFACE_NAME" 2>/dev/null || true
rm -f "$CONF" "$KEY_FILE" "$PUB_FILE" "$STATE_FILE" /etc/sysctl.d/99-v4exit.conf
ok "已卸载。提醒：sysctl 的 ip_forward 设置文件已删，重启后失效"
}

main_menu() {
check_root_os
install_shortcut
box "wg-v4-exit v$VERSION" \
"给纯 IPv6 服务器借一台双栈 VPS 做 IPv4 出口（WireGuard 点对点）" \
"" \
" 1. 本机是双栈 VPS —— 安装服务端 + NAT" \
" 2. 本机是纯 IPv6 服务器 —— 安装客户端，借 v4 出口" \
" 3. 查看本机连接信息（公钥 / 公网 IP / 接口状态）" \
" 4. 出口机补填 / 更新应用机公钥" \
" 5. 卸载" \
" 0. 退出"
local choice=""
read -r -p "请选择 [0-5]: " choice || true
case "$choice" in
1) install_server;;
2) install_client;;
3) show_info;;
4) update_peer;;
5) uninstall;;
0) say "拜拜";;
*) die "无效选择: $choice";;
esac
}

case "${1:-}" in
server) check_root_os; install_shortcut; install_server;;
client) check_root_os; install_shortcut; install_client;;
info) show_info;;
peer) update_peer;;
uninstall) uninstall;;
--dry-run) main_menu;;
"") main_menu;;
*) say "用法: v4exit [server|client|info|peer|uninstall]（或 bash menu.sh）"; exit 1;;
esac
