#!/bin/bash
# setip - 快速设置服务器 IPv4 地址/网关/DNS 的工具
# 支持 Ubuntu 18.04+ (netplan/NetworkManager) 和 CentOS 7.5+ (NetworkManager/network-scripts)
# 用法：
#   bash setip.sh <IP>                # 仅设置 IP，沿用当前掩码/网关/DNS
#   bash setip.sh <IP> <MASK>         # 设置 IP+掩码，沿用当前网关/DNS；如果第一个参数是 DNS 则仅设置 DNS
#   bash setip.sh <IP> <MASK> <GW>    # 设置 IP+掩码+网关，沿用当前 DNS
#   bash setip.sh <IP> <MASK> <GW> <DNS> # 设置 IP+掩码+网关+DNS
# 参数必须按照固定格式填写，IP/GW/DNS 使用 IPv4，掩码可为前缀或点分掩码

set -euo pipefail

error() { echo -e "\033[31m$1\033[0m" >&2; }
success() { echo -e "\033[32m$1\033[0m"; }
info() { echo "[INFO] $1"; }

require_root() {
  if [ "$EUID" -ne 0 ]; then
    error "请使用 root 权限运行本工具（sudo 或 root 用户）。"
    exit 1
  fi
}

usage() {
  cat <<'USAGE'
用法：
  bash setip.sh <IP>
  bash setip.sh <IP> <MASK>
  bash setip.sh DNS <DNS>
  bash setip.sh <IP> <MASK> <GATEWAY>
  bash setip.sh <IP> <MASK> <GATEWAY> <DNS>

说明：
  * 仅支持上述固定顺序的参数组合。
  * IP/GATEWAY/DNS 需为合法 IPv4；MASK 支持 1-32 前缀或点分掩码（如 255.255.255.0）。
  * 单参：只改 IP，掩码/网关/DNS 使用当前配置。
  * 双参：若首参为 DNS，则仅改 DNS；否则视为 IP+掩码，网关/DNS 使用当前配置。
  * 三参：IP+掩码+网关。
  * 四参：IP+掩码+网关+DNS。
USAGE
}

is_valid_ip() {
  local ip="$1"
  if [[ $ip =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
    IFS='.' read -r -a octets <<<"$ip"
    for o in "${octets[@]}"; do
      if ((o < 0 || o > 255)); then
        return 1
      fi
    done
    return 0
  fi
  return 1
}

is_valid_prefix() { [[ $1 =~ ^([1-9]|[12][0-9]|3[0-2])$ ]]; }

mask_to_prefix() {
  local mask="$1"
  if is_valid_prefix "$mask"; then
    echo "$mask"
    return 0
  fi
  if ! is_valid_ip "$mask"; then
    return 1
  fi
  local IFS='.'; local -a octets=($mask); local bits=0
  for o in "${octets[@]}"; do
    case $o in
      255) bits=$((bits+8));;
      254) bits=$((bits+7));;
      252) bits=$((bits+6));;
      248) bits=$((bits+5));;
      240) bits=$((bits+4));;
      224) bits=$((bits+3));;
      192) bits=$((bits+2));;
      128) bits=$((bits+1));;
      0) :;;
      *) return 1;;
    esac
  done
  echo "$bits"
}

prefix_to_mask() {
  local p="$1"
  if ! is_valid_prefix "$p"; then return 1; fi
  local mask=""; local i
  for ((i=0;i<4;i++)); do
    local n=$(( p>=8 ? 8 : p ))
    mask+=$((256 - 2**(8-n)))
    p=$((p-n))
    if ((i<3)); then mask+='.'; fi
  done
  echo "$mask"
}

detect_os() {
  if [ ! -f /etc/os-release ]; then
    error "无法识别系统：缺少 /etc/os-release。"
    exit 1
  fi
  . /etc/os-release
  OS_ID=${ID:-unknown}
  OS_VER=${VERSION_ID:-0}
  case "$OS_ID" in
    ubuntu)
      if awk -v v="$OS_VER" 'BEGIN{split(v,a,"."); if ((a[1]*100+a[2])<1804) exit 1}' ; then :; else
        error "仅支持 Ubuntu 18.04 及以上版本。当前：$OS_VER"
        exit 1
      fi
      PKG_MGR=apt
      ;;
    centos|rhel)
      if awk -v v="$OS_VER" 'BEGIN{split(v,a,"."); if ((a[1]<7)|| (a[1]==7 && a[2]<5)) exit 1}' ; then :; else
        error "仅支持 CentOS/RHEL 7.5 及以上版本。当前：$OS_VER"
        exit 1
      fi
      PKG_MGR=yum
      ;;
    *)
      error "当前系统($OS_ID $OS_VER)不在支持范围，仅支持 Ubuntu 18.04+ 或 CentOS 7.5+。"
      exit 1
      ;;
  esac
}

install_pkg() {
  local pkg="$1"
  if [ "$PKG_MGR" = "apt" ]; then
    apt-get update -y >/dev/null 2>&1 || true
    apt-get install -y "$pkg"
  else
    yum install -y "$pkg"
  fi
}

ensure_cmd() {
  local cmd="$1" pkg="$2"
  if ! command -v "$cmd" >/dev/null 2>&1; then
    info "缺少命令 $cmd，正在安装依赖 $pkg ..."
    install_pkg "$pkg"
  fi
}

detect_network_manager() {
  NET_MANAGER=""
  if command -v nmcli >/dev/null 2>&1 && systemctl list-unit-files | grep -q '^NetworkManager\.service'; then
    local status
    status=$(systemctl is-active NetworkManager 2>/dev/null || true)
    if [ "$status" != "inactive" ] && [ "$status" != "failed" ]; then
      NET_MANAGER="networkmanager"
      return
    fi
  fi
  if [ "$OS_ID" = "ubuntu" ] && ls /etc/netplan/*.yaml >/dev/null 2>&1; then
    NET_MANAGER="netplan"
    return
  fi
  if [ "$OS_ID" != "ubuntu" ] && [ -d /etc/sysconfig/network-scripts ]; then
    NET_MANAGER="network-scripts"
    return
  fi
  error "未能识别可用的网络管理方式，无法自动配置。"
  exit 1
}

list_interfaces() {
  ip -o link show | awk -F': ' '$2!="lo"{print $2}'
}

show_interfaces_with_ip() {
  local idx=1
  while read -r iface; do
    local ips
    ips=$(ip -o -f inet addr show "$iface" | awk '{print $4}' | paste -sd"," -)
    echo "$idx) $iface ${ips:+[$ips]}"
    iface_list[$idx]="$iface"
    idx=$((idx+1))
  done <<<"$(list_interfaces)"
}

select_interface() {
  declare -g IFACE
  iface_list=()
  show_interfaces_with_ip
  if [ ${#iface_list[@]} -eq 0 ]; then
    error "未找到可配置的网卡。"
    exit 1
  fi
  while true; do
    read -rp "请选择要配置的网卡序号: " choice
    if [[ $choice =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le ${#iface_list[@]} ]; then
      IFACE=${iface_list[$choice]}
      break
    fi
    error "输入无效，请输入列表中的序号。"
  done
}

parse_params() {
  MODE=""
  NEW_IP=""; NEW_PREFIX=""; NEW_GW=""; NEW_DNS=""
  if [ $# -eq 1 ]; then
    NEW_IP=$1; MODE="ip_only"
  elif [ $# -eq 2 ]; then
    if [[ "$1" =~ ^[Dd][Nn][Ss]$ ]]; then
      NEW_DNS=$2; MODE="dns_only"
    else
      NEW_IP=$1; NEW_PREFIX=$2; MODE="ip_mask"
    fi
  elif [ $# -eq 3 ]; then
    NEW_IP=$1; NEW_PREFIX=$2; NEW_GW=$3; MODE="ip_mask_gw"
  elif [ $# -eq 4 ]; then
    NEW_IP=$1; NEW_PREFIX=$2; NEW_GW=$3; NEW_DNS=$4; MODE="ip_mask_gw_dns"
  else
    usage; exit 1
  fi

  if [ -n "$NEW_IP" ] && ! is_valid_ip "$NEW_IP"; then
    error "IP 地址无效：$NEW_IP"; exit 1; fi
  if [ -n "$NEW_PREFIX" ]; then
    local tmp; tmp=$(mask_to_prefix "$NEW_PREFIX") || { error "掩码无效：$NEW_PREFIX"; exit 1; }
    NEW_PREFIX=$tmp
  fi
  if [ -n "$NEW_GW" ] && ! is_valid_ip "$NEW_GW"; then error "网关无效：$NEW_GW"; exit 1; fi
  if [ -n "$NEW_DNS" ] && ! is_valid_ip "$NEW_DNS"; then error "DNS 无效：$NEW_DNS"; exit 1; fi
}

get_current_prefix() {
  local iface="$1"
  ip -o -f inet addr show "$iface" | awk 'NR==1 {split($4,a,"/"); print a[2]}'
}

get_current_gateway() {
  local iface="$1"
  ip route show default dev "$iface" | awk 'NR==1{print $3}'
}

get_current_dns() {
  awk '/^nameserver/ {print $2}' /etc/resolv.conf | head -n1
}

update_nmcli() {
  local iface="$1" ip="$2" prefix="$3" gw="$4" dns="$5"
  ensure_cmd nmcli NetworkManager
  local conn
  conn=$(nmcli -t -f NAME,DEVICE connection show | awk -F: -v d="$iface" '$2==d{print $1; exit}')
  if [ -z "$conn" ]; then
    info "未找到 $iface 的连接，正在创建 setip-$iface ..."
    nmcli connection add type ethernet con-name "setip-$iface" ifname "$iface" autoconnect yes
    conn="setip-$iface"
  fi

  local current_prefix current_addr
  current_addr=$(nmcli -g ipv4.addresses connection show "$conn" | head -n1)
  if [ -z "$prefix" ] && [ -n "$current_addr" ]; then
    current_prefix=${current_addr#*/}
  else
    current_prefix=$prefix
  fi
  if [ -z "$current_prefix" ] && [ -n "$ip" ]; then
    error "无法获取当前掩码，请在命令中提供掩码。"
    exit 1
  fi

  nmcli connection modify "$conn" ipv4.method auto
  if [ -n "$ip" ]; then
    nmcli connection modify "$conn" ipv4.addresses "$ip/$current_prefix" ipv4.method manual
  fi
  if [ -n "$gw" ]; then
    nmcli connection modify "$conn" ipv4.gateway "$gw" ipv4.method manual
  fi
  if [ -n "$dns" ]; then
    nmcli connection modify "$conn" ipv4.dns "$dns" ipv4.ignore-auto-dns yes
  fi
  if [ "$MODE" = "dns_only" ]; then
    nmcli connection modify "$conn" ipv4.ignore-auto-dns yes
  fi

  nmcli connection down "$conn" >/dev/null 2>&1 || true
  nmcli connection up "$conn"

  if [ -n "$ip" ]; then
    sleep 1
    if ! ip -4 addr show "$iface" | grep -q "$ip/$current_prefix"; then
      error "IP 配置未生效，请检查网络管理器或配置。"
      exit 1
    fi
  fi
}

update_netplan() {
  local iface="$1" ip="$2" prefix="$3" gw="$4" dns="$5"
  ensure_cmd netplan netplan.io
  local final_prefix="$prefix"
  if [ -z "$final_prefix" ] && [ -n "$ip" ]; then
    final_prefix=$(get_current_prefix "$iface")
  fi
  if [ -z "$final_prefix" ] && [ -n "$ip" ]; then
    error "无法获取当前掩码，请在命令中提供掩码。"
    exit 1
  fi
  local addr_line="" gw_line="" dns_block=""
  if [ -n "$ip" ]; then addr_line="      addresses:\n        - ${ip}/${final_prefix}"; fi
  if [ -n "$gw" ]; then gw_line="\n      gateway4: $gw"; fi
  if [ -n "$dns" ]; then dns_block="\n      nameservers:\n        addresses: [$dns]"; fi

  local file="/etc/netplan/99-setip-${iface}.yaml"
  info "写入 netplan 配置：$file"
  cp /etc/netplan/*.yaml /etc/netplan/backup-setip-$(date +%s).yaml 2>/dev/null || true
  cat > "$file" <<EOF_NET
network:
  version: 2
  ethernets:
    ${iface}:
      dhcp4: false
${addr_line}${gw_line}${dns_block}
EOF_NET

  netplan apply
  sleep 1
  if [ -n "$ip" ]; then
    if ! ip -4 addr show "$iface" | grep -q "$ip/$final_prefix"; then
      error "应用 netplan 后未检测到新 IP，请检查配置。"
      exit 1
    fi
  fi
}

update_network_scripts() {
  local iface="$1" ip="$2" prefix="$3" gw="$4" dns="$5"
  local cfg="/etc/sysconfig/network-scripts/ifcfg-$iface"
  if [ ! -f "$cfg" ]; then
    info "未找到 $cfg，创建中..."
    cat > "$cfg" <<EOF_CFG
DEVICE=$iface
BOOTPROTO=none
ONBOOT=yes
EOF_CFG
  fi
  local final_prefix="$prefix"
  if [ -z "$final_prefix" ] && [ -n "$ip" ]; then
    final_prefix=$(get_current_prefix "$iface")
  fi
  if [ -z "$final_prefix" ] && [ -n "$ip" ]; then
    error "无法获取当前掩码，请在命令中提供掩码。"
    exit 1
  fi
  local netmask
  netmask=$(prefix_to_mask "$final_prefix")
  if [ -n "$ip" ]; then
    sed -i "/^IPADDR=/d" "$cfg"
    sed -i "/^NETMASK=/d" "$cfg"
    echo "IPADDR=$ip" >> "$cfg"
    echo "NETMASK=$netmask" >> "$cfg"
  fi
  if [ -n "$gw" ]; then
    sed -i "/^GATEWAY=/d" "$cfg"
    echo "GATEWAY=$gw" >> "$cfg"
  fi
  if [ -n "$dns" ]; then
    sed -i "/^DNS1=/d" "$cfg"
    echo "DNS1=$dns" >> "$cfg"
  fi
  systemctl restart network || { error "重启 network 服务失败，请手动检查。"; exit 1; }
  sleep 1
  if [ -n "$ip" ] && ! ip -4 addr show "$iface" | grep -q "$ip/$final_prefix"; then
    error "网卡 $iface IP 未生效，请检查 ifcfg 配置。"
    exit 1
  fi
}

print_result() {
  local iface="$1"
  local ip_info gw dns
  ip_info=$(ip -o -f inet addr show "$iface" | awk 'NR==1{print $4}')
  gw=$(ip route show default dev "$iface" | awk 'NR==1{print $3}')
  dns=$(awk '/^nameserver/ {print $2}' /etc/resolv.conf | paste -sd"," -)
  echo "================ 配置结果 ================"
  echo "网卡: $iface"
  echo "IP/掩码: ${ip_info:-未获取}"
  echo "默认网关: ${gw:-未获取}"
  echo "DNS: ${dns:-未获取}"
}

main() {
  require_root
  parse_params "$@"
  detect_os
  ensure_cmd ip iproute2
  ensure_cmd awk gawk
  ensure_cmd sed sed
  ensure_cmd grep grep
  detect_network_manager
  info "检测到系统: $OS_ID $OS_VER，网络管理方式: $NET_MANAGER"
  select_interface
  info "选择网卡: $IFACE"

  # 补全缺失的掩码/网关/DNS
  local cur_prefix cur_gw cur_dns
  cur_prefix=$(get_current_prefix "$IFACE")
  cur_gw=$(get_current_gateway "$IFACE")
  cur_dns=$(get_current_dns)
  if [ "$MODE" = "ip_only" ] && [ -z "$NEW_PREFIX" ]; then NEW_PREFIX="$cur_prefix"; fi
  if [ "$MODE" = "ip_mask" ] && [ -z "$NEW_GW" ]; then NEW_GW="$cur_gw"; fi
  if [ "$MODE" = "ip_only" ] && [ -z "$NEW_GW" ]; then NEW_GW="$cur_gw"; fi
  if [ -z "$NEW_DNS" ]; then NEW_DNS="$cur_dns"; fi

  case "$NET_MANAGER" in
    networkmanager)
      update_nmcli "$IFACE" "$NEW_IP" "$NEW_PREFIX" "$NEW_GW" "$NEW_DNS"
      ;;
    netplan)
      update_netplan "$IFACE" "$NEW_IP" "$NEW_PREFIX" "$NEW_GW" "$NEW_DNS"
      ;;
    network-scripts)
      update_network_scripts "$IFACE" "$NEW_IP" "$NEW_PREFIX" "$NEW_GW" "$NEW_DNS"
      ;;
  esac

  print_result "$IFACE"
  success "配置完成！"
}

main "$@"
