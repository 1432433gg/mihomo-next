#!/usr/bin/env bash
#
# Mihomo + Reality + Caddy + Reader 一键安装脚本
# https://github.com/1432433gg/mihomo-next
#
# 用法：
#   wget -N https://raw.githubusercontent.com/1432433gg/mihomo-next/main/install.sh && chmod +x install.sh && ./install.sh
#

SCRIPT_VERSION="1.0.2"

# ─── 路径 ───
STATE_DIR=/etc/mihomo-next
INFO_FILE=$STATE_DIR/info.conf
COMPOSE_FILE=$STATE_DIR/docker-compose.yaml
READER_ENV=$STATE_DIR/reader.env
COMPOSE_PROJECT=reader-next

MIHOMO_REPO=MetaCubeX/mihomo
MIHOMO_BIN_DIR=/usr/local/bin/mihomo
MIHOMO_BIN=$MIHOMO_BIN_DIR/mihomo
MIHOMO_CONF_DIR=/etc/mihomo
MIHOMO_CONF=$MIHOMO_CONF_DIR/config.yaml
MIHOMO_SERVICE=/etc/systemd/system/mihomo.service

CADDY_REPO=caddyserver/caddy
CADDY_BIN=/usr/bin/caddy
CADDY_CONF_DIR=/etc/caddy
CADDY_CONF=$CADDY_CONF_DIR/caddy.json
CADDY_SERVICE=/etc/systemd/system/caddy.service
# Caddy 的证书等数据放在 $XDG_DATA_HOME/caddy
CADDY_XDG=/var/lib
CADDY_DATA=$CADDY_XDG/caddy

READER_IMAGE=ghcr.io/1432433gg/reader-next
BBR_SCRIPT_URL=https://raw.githubusercontent.com/ylx2016/Linux-NetSpeed/master/tcp.sh
OS_RELEASE_FILE=/etc/os-release
APT_SOURCES_LIST=/etc/apt/sources.list
APT_SOURCES_DIR=/etc/apt/sources.list.d
APT_CONF_DIR=/etc/apt/apt.conf.d
# 已停止维护、软件源移到 archive.debian.org 的 Debian 版本
EOL_CODENAMES="buster bullseye"

# Caddy 只在本机监听，供 Reality 回落；Reader 只在本机监听，供 Caddy 反代（和模板里写的一致）
CADDY_TLS_PORT=8443
READER_PORT=8080
# Shadowsocks 2022 默认用这个范围里的随机端口：避开 10000 以下常见服务的端口，
# 也避开 Linux 出站连接用的临时端口（默认从 32768 开始），免得重启时端口被占
SS_PORT_MIN=10000
SS_PORT_MAX=32767
# 加密方式和模板里写的一致
SS_CIPHER=2022-blake3-aes-128-gcm

# 配置文件模板放在仓库的各个目录里；只下载了 install.sh 时，运行时从 GitHub 下载
REPO_RAW=https://raw.githubusercontent.com/1432433gg/mihomo-next/main
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)
TEMPLATES="mihomo/vless-reality.yaml mihomo/shadowsocks-2022.yaml caddy/caddy.json reader/reader.env docker/docker-compose.yaml systemd/mihomo.service systemd/caddy.service chrony/google.conf apt/archive.list"
TEMPLATE_DIR=""

# ─── 输出 ───
Green="\033[32m"
Red="\033[31m"
Yellow="\033[33m"
Blue="\033[36m"
Font="\033[0m"
OK="${Green}[OK]${Font}"
ERROR="${Red}[错误]${Font}"
WARN="${Yellow}[注意]${Font}"

print_ok() { echo -e "${OK} ${Blue}$1${Font}"; }
print_error() { echo -e "${ERROR} ${Red}$1${Font}"; }
print_warn() { echo -e "${WARN} ${Yellow}$1${Font}"; }
print_info() { echo -e "${Green}==>${Font} $1"; }

# 检查上一条命令的结果，失败就退出
judge() {
  if [[ $? -eq 0 ]]; then
    print_ok "$1 完成"
    sleep 1
  else
    print_error "$1 失败"
    exit 1
  fi
}

# ─── 配置模板 ───
local_templates() {
  local f
  [[ -n $SCRIPT_DIR ]] || return 1
  for f in $TEMPLATES; do
    [[ -f $SCRIPT_DIR/$f ]] || return 1
  done
}

# 在仓库目录里运行就用本地模板，否则下载到临时目录
prepare_templates() {
  local f tmp
  [[ -n $TEMPLATE_DIR ]] && return 0
  if local_templates; then
    TEMPLATE_DIR=$SCRIPT_DIR
    return 0
  fi
  tmp=$(mktemp -d)
  for f in $TEMPLATES; do
    mkdir -p "$tmp/${f%/*}"
    if ! wget -q --timeout=15 --tries=2 -O "$tmp/$f" "$REPO_RAW/$f"; then
      rm -rf "$tmp"
      print_error "下载配置模板失败：$REPO_RAW/$f"
      return 1
    fi
  done
  TEMPLATE_DIR=$tmp
  TEMPLATE_TMP=$tmp
  trap 'rm -rf "$TEMPLATE_TMP"' EXIT
}

# 用模板生成文件，把 {{名字}} 换成对应的值
# 用法：render_template 模板 目标文件 名字=值 ...
render_template() {
  local name=$1 dest=$2 content pair key
  prepare_templates || return 1
  content=$(<"$TEMPLATE_DIR/$name") || return 1
  shift 2
  for pair in "$@"; do
    key="{{${pair%%=*}}}"
    content=${content//"$key"/"${pair#*=}"}
  done
  if [[ $content == *"{{"*"}}"* ]]; then
    print_error "模板 $name 里还有没填的内容"
    return 1
  fi
  mkdir -p "$(dirname "$dest")"
  printf '%s\n' "$content" >"$dest"
}

# ─── 系统检查 ───
is_root() {
  if [[ $EUID -ne 0 ]]; then
    print_error "请用 root 运行"
    exit 1
  fi
}

detect_system() {
  if [[ ! -f $OS_RELEASE_FILE ]]; then
    print_error "无法识别系统"
    exit 1
  fi
  # shellcheck disable=SC1090
  OS_ID=$(. "$OS_RELEASE_FILE" && echo "$ID")
  # shellcheck disable=SC1090
  OS_VERSION=$(. "$OS_RELEASE_FILE" && echo "${VERSION_ID:-0}")
  # shellcheck disable=SC1090
  OS_CODENAME=$(. "$OS_RELEASE_FILE" && echo "${VERSION_CODENAME:-}")
  case "$OS_ID" in
    debian)
      if [[ ${OS_VERSION%%.*} -lt 10 ]]; then
        print_error "仅支持 Debian 10 及以上"
        exit 1
      fi
      ;;
    ubuntu)
      if [[ ${OS_VERSION%%.*} -lt 20 ]]; then
        print_error "仅支持 Ubuntu 20.04 及以上"
        exit 1
      fi
      ;;
    *)
      print_error "仅支持 Debian / Ubuntu"
      exit 1
      ;;
  esac

  case "$(uname -m)" in
    x86_64 | amd64)
      ARCH=amd64
      MIHOMO_ARCH=amd64-compatible
      ;;
    aarch64 | arm64)
      ARCH=arm64
      MIHOMO_ARCH=arm64
      ;;
    *)
      print_error "不支持的架构：$(uname -m)"
      exit 1
      ;;
  esac
}

apt_install() {
  DEBIAN_FRONTEND=noninteractive apt-get -o DPkg::Lock::Timeout=300 -y -qq install "$@" >/dev/null
}

# 新开的机器上系统可能正在自动更新，占着 apt，等它结束
wait_for_apt() {
  local i
  for i in $(seq 1 60); do
    pgrep -x 'apt|apt-get|dpkg|unattended-upgr' >/dev/null 2>&1 || return 0
    [[ $i -eq 1 ]] && print_info "系统正在自动更新，等待完成（最多 5 分钟）"
    sleep 5
  done
  print_warn "等待超时，继续执行"
}

is_eol_debian() {
  [[ $OS_ID == debian && " $EOL_CODENAMES " == *" $OS_CODENAME "* ]]
}

# Debian 10 / 11 已停止维护，软件源已从 deb.debian.org 移到 archive.debian.org
use_archive_sources() {
  local security f
  is_eol_debian || return 0
  if grep -qs "archive.debian.org" "$APT_SOURCES_LIST"; then
    return 0
  fi
  if [[ $OS_CODENAME == buster ]]; then
    security="buster/updates"
  else
    security="${OS_CODENAME}-security"
  fi
  if [[ -f $APT_SOURCES_LIST && ! -f $APT_SOURCES_LIST.mihomo-next.bak ]]; then
    cp "$APT_SOURCES_LIST" "$APT_SOURCES_LIST.mihomo-next.bak"
  fi
  render_template apt/archive.list "$APT_SOURCES_LIST" CODENAME="$OS_CODENAME" SECURITY="$security" || return 1
  # 其他源文件里还指向旧地址的，先停用（改名加 .disabled）
  for f in "$APT_SOURCES_DIR"/*.list "$APT_SOURCES_DIR"/*.sources; do
    [[ -f $f ]] || continue
    if grep -qE "(deb|security|ftp)[.]debian[.]org" "$f"; then
      mv "$f" "$f.disabled"
    fi
  done
  # 归档源的签名有效期已过，不检查
  mkdir -p "$APT_CONF_DIR"
  echo 'Acquire::Check-Valid-Until "false";' >"$APT_CONF_DIR/99mihomo-next-archive"
  print_warn "Debian $OS_CODENAME 已停止维护，软件源已切换到 archive.debian.org"
}

apt_update() {
  wait_for_apt
  use_archive_sources || return 1
  if ! apt-get -qq update; then
    print_error "apt update 失败，请检查软件源"
    return 1
  fi
}

install_deps() {
  print_info "安装依赖"
  apt_update || exit 1
  apt_install wget curl lsof tar gzip ca-certificates dnsutils chrony
  judge "安装依赖"
}

disable_firewall() {
  local svc
  for svc in nftables ufw; do
    systemctl stop "$svc" >/dev/null 2>&1
    systemctl disable "$svc" >/dev/null 2>&1
  done
  print_ok "已关闭防火墙（nftables / ufw）"
}

# 端口被占用：显示占用信息；Caddy / Mihomo 先正常停止，其他进程 5 秒后 kill -9
port_exist_check() {
  local port=$1 svc
  if ! lsof -nP -iTCP:"$port" -sTCP:LISTEN >/dev/null 2>&1; then
    print_ok "端口 $port 未被占用"
    return 0
  fi
  print_error "检测到端口 $port 被占用，以下为占用信息"
  lsof -nP -iTCP:"$port" -sTCP:LISTEN
  for svc in caddy mihomo; do
    if lsof -nP -iTCP:"$port" -sTCP:LISTEN | awk 'NR > 1 {print $1}' | grep -qx "$svc"; then
      systemctl stop "$svc" >/dev/null 2>&1
      print_ok "已停止占用端口 $port 的 $svc 服务"
      sleep 1
    fi
  done
  if lsof -nP -iTCP:"$port" -sTCP:LISTEN >/dev/null 2>&1; then
    print_warn "5 秒后将尝试自动结束占用进程"
    sleep 5
    lsof -nP -t -iTCP:"$port" -sTCP:LISTEN | xargs -r kill -9
    print_ok "已结束占用进程"
    sleep 1
  fi
}

# ─── 输入 ───
read_domain() {
  local input
  while true; do
    read -rp "请输入域名：" input
    input=$(echo "$input" | tr -d '[:space:]' | tr '[:upper:]' '[:lower:]')
    if [[ -z $input ]]; then
      print_error "域名不能为空"
    elif [[ ! $input =~ ^([a-z0-9]([a-z0-9-]*[a-z0-9])?\.)+[a-z]{2,}$ ]]; then
      print_error "域名格式不正确"
    else
      DOMAIN=$input
      return 0
    fi
  done
}

read_port() {
  local default=${1:-443} input
  while true; do
    read -rp "端口 [$default]：" input
    input=${input:-$default}
    if [[ ! $input =~ ^[0-9]+$ ]]; then
      print_error "请输入 1-65535 之间的数字"
      continue
    fi
    input=$((10#$input))
    if ((input < 1 || input > 65535)); then
      print_error "请输入 1-65535 之间的数字"
    elif ((input == 80 || input == CADDY_TLS_PORT || input == READER_PORT)); then
      print_error "端口 $input 已留给 Caddy / Reader 使用，请换一个"
    else
      PORT=$input
      return 0
    fi
  done
}

# ─── 域名解析检查 ───
get_public_ip() {
  local family=$1 url ip
  for url in https://api64.ipify.org https://ip.sb; do
    ip=$(curl -"$family" -fsS --max-time 8 "$url" 2>/dev/null | tr -d '[:space:]')
    if [[ -n $ip ]]; then
      echo "$ip"
      return 0
    fi
  done
  return 1
}

resolve_domain() {
  local type=$1 domain=$2
  if command -v dig >/dev/null 2>&1; then
    dig +short "$type" "$domain" 2>/dev/null | grep -E '^[0-9a-fA-F:.]+$'
  elif [[ $type == A ]]; then
    getent ahostsv4 "$domain" 2>/dev/null | awk '{print $1}' | sort -u
  else
    getent ahostsv6 "$domain" 2>/dev/null | awk '{print $1}' | sort -u
  fi
}

domain_check() {
  local ip4 ip6 a4 a6 yn
  print_info "检查域名解析"
  ip4=$(get_public_ip 4)
  ip6=$(get_public_ip 6)
  a4=$(resolve_domain A "$DOMAIN")
  a6=$(resolve_domain AAAA "$DOMAIN")
  echo "域名解析：IPv4 ${a4:-无}  IPv6 ${a6:-无}" | tr '\n' ' '
  echo
  echo "本机公网：IPv4 ${ip4:-无}  IPv6 ${ip6:-无}"
  if [[ -n $ip4 ]] && grep -qxF "$ip4" <<<"$a4"; then
    print_ok "域名已解析到本机"
    return 0
  fi
  if [[ -n $ip6 ]] && grep -qxF "$ip6" <<<"$a6"; then
    print_ok "域名已解析到本机"
    return 0
  fi
  print_warn "域名没有解析到本机，Caddy 将无法申请证书"
  read -rp "是否继续？[y/N]：" yn
  [[ $yn == [Yy] ]] || exit 2
}

# ─── 时间同步 ───
# 注释掉原有的时间服务器，只用谷歌的；重复运行只保留一份
configure_chrony_file() {
  local conf=$1
  prepare_templates || return 1
  sed -i '/^# BEGIN mihomo-next$/,/^# END mihomo-next$/d' "$conf"
  sed -i -E 's/^((pool|server|sourcedir)[[:space:]].*)$/# \1/' "$conf"
  if [[ -s $conf && -n $(tail -c1 "$conf") ]]; then
    echo >>"$conf"
  fi
  printf '%s\n' "# BEGIN mihomo-next" "$(<"$TEMPLATE_DIR/chrony/google.conf")" "# END mihomo-next" >>"$conf"
}

configure_chrony() {
  local conf=/etc/chrony/chrony.conf
  [[ -f $conf ]] || conf=/etc/chrony.conf
  if [[ ! -f $conf ]]; then
    print_error "找不到 chrony 配置文件"
    return 1
  fi
  configure_chrony_file "$conf" || return 1
  timedatectl set-timezone Asia/Shanghai >/dev/null 2>&1
  systemctl enable chrony >/dev/null 2>&1
  systemctl restart chrony
  timedatectl set-ntp true >/dev/null 2>&1
  print_ok "时间同步已设置（谷歌时间服务器，时区 Asia/Shanghai）"
  wait_time_sync
}

now_time() {
  date '+%Y-%m-%d %H:%M:%S %Z'
}

# 等 chrony 连上时间服务器，立即校准一次，再显示同步后的时间
wait_time_sync() {
  local server
  print_info "等待时间同步（最多 30 秒）"
  if ! chronyc waitsync 15 0 0 2 >/dev/null 2>&1; then
    print_warn "30 秒内没有同步上，当前时间 $(now_time)，chrony 会在后台继续同步"
    return 0
  fi
  chronyc makestep >/dev/null 2>&1
  server=$(chronyc tracking 2>/dev/null | awk -F'[()]' '/^Reference ID/ {print $2; exit}')
  print_ok "时间已同步：$(now_time)（时间服务器 ${server:-未知}）"
}

time_sync_state() {
  if chronyc tracking 2>/dev/null | grep -qE '^Leap status +: Normal'; then
    echo -e "${Green}已同步${Font}  $(now_time)"
  else
    echo -e "${Red}未同步${Font}  $(now_time)"
  fi
}

# ─── 安装信息 ───
save_info() {
  mkdir -p "$STATE_DIR"
  chmod 700 "$STATE_DIR"
  cat >"$INFO_FILE" <<EOF
MODE="$MODE"
DOMAIN="$DOMAIN"
PORT="$PORT"
UUID="$UUID"
PRIVATE_KEY="$PRIVATE_KEY"
PUBLIC_KEY="$PUBLIC_KEY"
SS_PASSWORD="$SS_PASSWORD"
READER_VERSION="$READER_VERSION"
EOF
  chmod 600 "$INFO_FILE"
}

load_info() {
  if [[ ! -f $INFO_FILE ]]; then
    print_error "未找到安装信息，请先安装（菜单 1 或 2）"
    return 1
  fi
  # shellcheck disable=SC1090
  . "$INFO_FILE"
  READER_VERSION=${READER_VERSION:-latest}
}

mode_name() {
  if [[ $MODE == ss ]]; then
    echo "Shadowsocks 2022"
  else
    echo "VLESS + Reality"
  fi
}

# 已经装的是哪一种：reality / ss；没装过时返回失败。旧版安装信息没有 MODE，都是 Reality
installed_mode() {
  local mode
  [[ -f $INFO_FILE ]] || return 1
  mode=$(sed -n 's/^MODE="\([^"]*\)"$/\1/p' "$INFO_FILE")
  echo "${mode:-reality}"
}

# 两种安装方式只能选一种：已经装了另一种就不继续
check_install_mode() {
  local want=$1 current
  current=$(installed_mode) || return 0
  [[ $current == "$want" ]] && return 0
  if [[ $current == ss ]]; then
    print_error "这台服务器已经装了 Mihomo + Shadowsocks 2022，两种安装方式只能选一种"
  else
    print_error "这台服务器已经装了 Mihomo + Reality + Caddy + Reader，两种安装方式只能选一种"
  fi
  print_warn "要换成另一种，请重装系统后再安装"
  return 1
}

# 只装了 Shadowsocks 时没有域名、Caddy 和 Reader
require_reality() {
  if [[ $MODE == ss ]]; then
    print_error "当前装的是 Mihomo + Shadowsocks 2022，没有这一项"
    return 1
  fi
}

show_info() {
  local ip
  load_info || return 1
  echo
  echo -e "${Green}—————— 连接信息 ——————${Font}"
  if [[ $MODE == ss ]]; then
    ip=$(get_public_ip 4 || get_public_ip 6)
    echo -e "地址（IP）：${Blue}${ip:-获取失败，请填服务器的 IP}${Font}"
    echo -e "端口：${Blue}${PORT}${Font}"
    echo -e "加密：${Blue}${SS_CIPHER}${Font}"
    echo -e "密码：${Blue}${SS_PASSWORD}${Font}"
    echo -e "UDP：${Blue}开启${Font}"
  else
    echo -e "地址（域名）：${Blue}${DOMAIN}${Font}"
    echo -e "端口：${Blue}${PORT}${Font}"
    echo -e "UUID：${Blue}${UUID}${Font}"
    echo -e "流控：${Blue}xtls-rprx-vision${Font}"
    echo -e "SNI：${Blue}${DOMAIN}${Font}"
    echo -e "公钥（public-key）：${Blue}${PUBLIC_KEY}${Font}"
    echo -e "short-id：${Blue}（空）${Font}"
  fi
  echo
}

new_uuid() {
  cat /proc/sys/kernel/random/uuid
}

# 2022-blake3-aes-128-gcm 的密码是 16 字节随机数的 base64
new_ss_password() {
  head -c 16 /dev/urandom | base64
}

# 端口的 TCP 或 UDP 有没有被占用。第一次安装时选端口还在装依赖之前，系统可能还没有 lsof，
# 就用系统自带的 ss
port_in_use() {
  local port=$1
  if command -v lsof >/dev/null 2>&1; then
    lsof -nP -iTCP:"$port" -sTCP:LISTEN >/dev/null 2>&1 || lsof -nP -iUDP:"$port" >/dev/null 2>&1
  elif command -v ss >/dev/null 2>&1; then
    ss -Hlntu "sport = :$port" 2>/dev/null | grep -q .
  else
    return 1
  fi
}

# TCP 和 UDP 都没被占用的随机端口
random_ss_port() {
  local port
  while true; do
    port=$(shuf -i "$SS_PORT_MIN-$SS_PORT_MAX" -n 1)
    if ! port_in_use "$port"; then
      echo "$port"
      return 0
    fi
  done
}

generate_keys() {
  local out
  out=$("$MIHOMO_BIN" generate reality-keypair 2>/dev/null) || return 1
  PRIVATE_KEY=$(awk -F': *' '/^PrivateKey/ {print $2}' <<<"$out")
  PUBLIC_KEY=$(awk -F': *' '/^PublicKey/ {print $2}' <<<"$out")
  [[ -n $PRIVATE_KEY && -n $PUBLIC_KEY ]]
}

# ─── GitHub 版本 ───
github_latest_tag() {
  local api
  api=$(wget -qO- --timeout=15 --tries=2 "https://api.github.com/repos/$1/releases/latest") || return 1
  if [[ $api =~ \"tag_name\":[[:space:]]*\"([^\"]+)\" ]]; then
    echo "${BASH_REMATCH[1]}"
  else
    return 1
  fi
}

# ─── Mihomo ───
mihomo_current_version() {
  [[ -x $MIHOMO_BIN ]] || return 0
  "$MIHOMO_BIN" -v 2>/dev/null | grep -oE 'v[0-9]+\.[0-9]+\.[0-9]+' | head -n1
}

# 安装或更新到指定版本（不传就是最新版）；有变化时 CHANGED=1
install_mihomo() {
  local version=${1:-} current tmp file
  CHANGED=0
  if [[ -z $version ]]; then
    print_info "获取 Mihomo 最新版本"
    version=$(github_latest_tag "$MIHOMO_REPO") || {
      print_error "无法访问 GitHub API，可以手动指定版本号"
      return 1
    }
  fi
  version="v${version#v}"
  current=$(mihomo_current_version)
  if [[ $current == "$version" ]]; then
    print_ok "Mihomo 已是 $version"
    return 0
  fi
  print_info "安装 Mihomo ${version}（当前：${current:-未安装}）"

  tmp=$(mktemp -d)
  file="mihomo-linux-${MIHOMO_ARCH}-${version}.gz"
  if ! wget -q --show-progress --timeout=30 --tries=2 -O "$tmp/mihomo.gz" \
    "https://github.com/${MIHOMO_REPO}/releases/download/${version}/${file}"; then
    rm -rf "$tmp"
    print_error "下载失败：${file}，请检查版本号或网络"
    return 1
  fi
  if ! gzip -d "$tmp/mihomo.gz" || ! chmod +x "$tmp/mihomo" || ! "$tmp/mihomo" -v >/dev/null 2>&1; then
    rm -rf "$tmp"
    print_error "下载的文件无法运行"
    return 1
  fi

  # 别的安装方式可能把 /usr/local/bin/mihomo 装成了文件
  if [[ -f $MIHOMO_BIN_DIR ]]; then
    mv "$MIHOMO_BIN_DIR" "${MIHOMO_BIN_DIR}.bak"
    print_warn "已把原来的 $MIHOMO_BIN_DIR 改名为 ${MIHOMO_BIN_DIR}.bak"
  fi
  mkdir -p "$MIHOMO_BIN_DIR"
  install -m 755 -o root -g root "$tmp/mihomo" "$MIHOMO_BIN"
  rm -rf "$tmp"
  CHANGED=1
  print_ok "Mihomo $version 安装完成"
}

write_mihomo_service() {
  render_template systemd/mihomo.service "$MIHOMO_SERVICE" || return 1
  systemctl daemon-reload
}

write_mihomo_config() {
  if [[ $MODE == ss ]]; then
    render_template mihomo/shadowsocks-2022.yaml "$MIHOMO_CONF" PORT="$PORT" SS_PASSWORD="$SS_PASSWORD" || return 1
  else
    render_template mihomo/vless-reality.yaml "$MIHOMO_CONF" \
      DOMAIN="$DOMAIN" PORT="$PORT" UUID="$UUID" PRIVATE_KEY="$PRIVATE_KEY" || return 1
  fi
  chmod 600 "$MIHOMO_CONF"
}

check_mihomo_config() {
  local out
  if ! out=$("$MIHOMO_BIN" -t -d "$MIHOMO_CONF_DIR" 2>&1); then
    echo "$out" | tail -n 5
    print_error "Mihomo 配置检查未通过"
    return 1
  fi
}

restart_mihomo() {
  check_mihomo_config || return 1
  systemctl enable mihomo >/dev/null 2>&1
  systemctl restart mihomo
  sleep 2
  if systemctl is-active --quiet mihomo; then
    print_ok "Mihomo 运行中"
  else
    print_error "Mihomo 启动失败，可以运行 $MIHOMO_BIN -d $MIHOMO_CONF_DIR 查看原因"
    return 1
  fi
}

# ─── Caddy ───
caddy_current_version() {
  [[ -x $CADDY_BIN ]] || return 0
  "$CADDY_BIN" version 2>/dev/null | grep -oE '^v[0-9]+\.[0-9]+\.[0-9]+'
}

# 安装或更新到指定版本（不传就是最新版），下载后校验 SHA-512；有变化时 CHANGED=1
install_caddy() {
  local version=${1:-} current tmp num file sums base expected actual
  CHANGED=0
  if [[ -z $version ]]; then
    print_info "获取 Caddy 最新版本"
    version=$(github_latest_tag "$CADDY_REPO") || {
      print_error "无法访问 GitHub API，可以手动指定版本号"
      return 1
    }
  fi
  version="v${version#v}"
  current=$(caddy_current_version)
  if [[ $current == "$version" ]]; then
    print_ok "Caddy 已是 $version"
    return 0
  fi
  print_info "安装 Caddy ${version}（当前：${current:-未安装}）"

  num=${version#v}
  file="caddy_${num}_linux_${ARCH}.tar.gz"
  sums="caddy_${num}_checksums.txt"
  base="https://github.com/${CADDY_REPO}/releases/download/${version}"
  tmp=$(mktemp -d)
  if ! wget -q --show-progress --timeout=30 --tries=2 -O "$tmp/$file" "$base/$file" ||
    ! wget -q --timeout=30 --tries=2 -O "$tmp/$sums" "$base/$sums"; then
    rm -rf "$tmp"
    print_error "下载失败：${file}，请检查版本号或网络"
    return 1
  fi
  expected=$(awk -v f="$file" '$2 == f {print $1}' "$tmp/$sums")
  actual=$(sha512sum "$tmp/$file" | awk '{print $1}')
  if [[ -z $expected || $expected != "$actual" ]]; then
    rm -rf "$tmp"
    print_error "Caddy 文件校验失败"
    return 1
  fi
  if ! tar -xzf "$tmp/$file" -C "$tmp" caddy || ! "$tmp/caddy" version >/dev/null 2>&1; then
    rm -rf "$tmp"
    print_error "下载的文件无法运行"
    return 1
  fi

  # 之前用 apt 装过 Caddy 的话先卸掉，免得以后 apt 升级把这里的版本覆盖
  if dpkg -s caddy >/dev/null 2>&1; then
    systemctl stop caddy >/dev/null 2>&1
    DEBIAN_FRONTEND=noninteractive apt-get -y -qq remove caddy >/dev/null 2>&1
    print_warn "已卸载 apt 安装的 Caddy"
  fi
  install -m 755 -o root -g root "$tmp/caddy" "$CADDY_BIN"
  rm -rf "$tmp"
  CHANGED=1
  print_ok "Caddy $version 安装完成"
}

write_caddy_service() {
  render_template systemd/caddy.service "$CADDY_SERVICE" || return 1
  systemctl daemon-reload
}

# 80 端口跳转到 https://域名，Reality 端口不是 443 时带上端口。
# Caddy 自带的跳转在模板里关掉了：它会跳到本机的 8443，外面打不开
write_caddy_config() {
  local suffix=""
  [[ $PORT == 443 ]] || suffix=":$PORT"
  render_template caddy/caddy.json "$CADDY_CONF" DOMAIN="$DOMAIN" PORT_SUFFIX="$suffix"
}

check_caddy_config() {
  local out
  if ! out=$(XDG_DATA_HOME=$CADDY_XDG XDG_CONFIG_HOME=$CADDY_XDG "$CADDY_BIN" validate --config "$CADDY_CONF" 2>&1); then
    echo "$out" | tail -n 5
    print_error "Caddy 配置检查未通过"
    return 1
  fi
}

restart_caddy() {
  check_caddy_config || return 1
  systemctl enable caddy >/dev/null 2>&1
  systemctl restart caddy
  sleep 2
  if systemctl is-active --quiet caddy; then
    print_ok "Caddy 运行中"
  else
    print_error "Caddy 启动失败，可以运行 $CADDY_BIN run --config $CADDY_CONF 查看原因"
    return 1
  fi
}

cert_exists() {
  compgen -G "$CADDY_DATA/certificates/*/$DOMAIN/$DOMAIN.crt" >/dev/null
}

wait_for_cert() {
  print_info "等待 Caddy 申请证书（最多 90 秒）"
  for _ in $(seq 1 45); do
    if cert_exists; then
      print_ok "证书已就绪"
      return 0
    fi
    sleep 2
  done
  print_warn "暂时还没拿到证书。请确认域名已解析到本机、80 端口能从外网访问，Caddy 会自动重试"
  return 1
}

# ─── Reader（Docker） ───
compose() {
  if docker compose version >/dev/null 2>&1; then
    docker compose -p "$COMPOSE_PROJECT" -f "$COMPOSE_FILE" "$@"
  else
    docker-compose -p "$COMPOSE_PROJECT" -f "$COMPOSE_FILE" "$@"
  fi
}

install_docker() {
  if ! command -v docker >/dev/null 2>&1; then
    print_info "安装 Docker"
    apt_install docker.io || {
      print_error "Docker 安装失败"
      return 1
    }
  fi
  systemctl enable --now docker >/dev/null 2>&1
  if ! docker compose version >/dev/null 2>&1 && ! command -v docker-compose >/dev/null 2>&1; then
    apt_install docker-compose-v2 2>/dev/null || apt_install docker-compose || {
      print_error "docker compose 安装失败"
      return 1
    }
  fi
  print_ok "Docker 就绪"
}

write_compose() {
  # reader.env 可能被改过（比如用户数），已经有了就不覆盖
  if [[ ! -f $READER_ENV ]]; then
    render_template reader/reader.env "$READER_ENV" || return 1
  fi
  render_template docker/docker-compose.yaml "$COMPOSE_FILE" READER_VERSION="${READER_VERSION:-latest}" || return 1
  # 旧版 docker-compose（Debian 10 / 11、Ubuntu 20.04 自带的 1.21 / 1.25）要求写 version
  if ! docker compose version >/dev/null 2>&1; then
    sed -i '1i version: "3.3"' "$COMPOSE_FILE"
  fi
}

start_reader() {
  local out image
  print_info "下载 Reader 镜像"
  if ! compose pull; then
    print_error "拉取镜像失败：版本不存在，或镜像不是公开的（$READER_IMAGE）"
    return 1
  fi
  if ! out=$(compose up -d --remove-orphans 2>&1); then
    echo "$out" | tail -n 3
    if grep -q "already in use" <<<"$out"; then
      print_error "服务器上已经有一个叫 reader-next 的容器，不是本脚本创建的（可能是以前手动部署的）"
      print_warn "确认不要了就删掉它再试：docker rm -f reader-next（数据卷不会被删）"
    else
      print_error "Reader 启动失败"
    fi
    return 1
  fi
  sleep 2
  # 确认跑起来的是本脚本指定的镜像，而不是别的同名容器
  image=$(docker inspect -f '{{.Config.Image}}' reader-next 2>/dev/null)
  if [[ $image != "$READER_IMAGE:${READER_VERSION:-latest}" ]]; then
    print_error "正在运行的 reader-next 用的镜像是 ${image:-未知}，不是 $READER_IMAGE:${READER_VERSION:-latest}"
    return 1
  fi
  if [[ $(docker inspect -f '{{.State.Running}}' reader-next 2>/dev/null) == true ]]; then
    print_ok "Reader 运行中"
  else
    print_error "Reader 启动失败"
    return 1
  fi
}

# ─── 1. 安装 ───
install_all() {
  local reinstall=0
  check_install_mode reality || return 1
  prepare_templates || exit 1
  read_domain
  read_port

  install_deps
  domain_check

  # 重新安装时沿用原来的 UUID 和密钥，客户端不用改
  if [[ -f $INFO_FILE ]]; then
    local new_domain=$DOMAIN new_port=$PORT
    load_info
    DOMAIN=$new_domain
    PORT=$new_port
    reinstall=1
  fi

  # 先停掉自己的服务，再检查端口
  systemctl stop mihomo >/dev/null 2>&1
  systemctl stop caddy >/dev/null 2>&1
  if [[ -f $COMPOSE_FILE ]] && command -v docker >/dev/null 2>&1; then
    compose down >/dev/null 2>&1
  fi
  port_exist_check 80
  port_exist_check "$PORT"
  port_exist_check "$CADDY_TLS_PORT"
  port_exist_check "$READER_PORT"

  disable_firewall
  configure_chrony || exit 1

  # Reader
  install_docker || exit 1
  # 关防火墙会清空 nftables 规则，重启 Docker 让它重新生成自己的规则
  systemctl restart docker >/dev/null 2>&1
  READER_VERSION=${READER_VERSION:-latest}
  write_compose || exit 1
  start_reader || exit 1

  # Mihomo 先启动占住 Reality 端口，Caddy 申请证书时就不会去抢 443，
  # 验证请求经 Reality 回落交给 Caddy
  install_mihomo || exit 1
  write_mihomo_service || exit 1
  if [[ $reinstall -eq 0 || -z ${UUID:-} || -z ${PRIVATE_KEY:-} || -z ${PUBLIC_KEY:-} ]]; then
    UUID=$(new_uuid)
    generate_keys || {
      print_error "生成 Reality 密钥失败"
      exit 1
    }
  fi
  MODE=reality
  save_info
  write_mihomo_config || exit 1
  restart_mihomo || exit 1

  # Caddy
  install_caddy || exit 1
  write_caddy_service || exit 1
  write_caddy_config || exit 1
  restart_caddy || exit 1

  wait_for_cert
  print_ok "安装完成"
  show_info
  if [[ $PORT -eq 443 ]]; then
    echo -e "Reader：${Blue}https://${DOMAIN}${Font}"
  else
    echo -e "Reader：${Blue}https://${DOMAIN}:${PORT}${Font}"
  fi
  echo "第一次打开点「注册」创建账号，第一个注册的账号就是管理员"
  echo
}

# ─── 2. 安装 Mihomo + Shadowsocks 2022 ───
install_ss() {
  check_install_mode ss || return 1
  prepare_templates || exit 1
  # 重新安装时默认沿用原来的端口，密码也沿用，客户端不用改；第一次安装默认随机端口
  if [[ -f $INFO_FILE ]]; then
    load_info
  fi
  if [[ $MODE == ss && -n $PORT ]]; then
    read_port "$PORT"
  else
    read_port "$(random_ss_port)"
  fi

  install_deps

  [[ -n ${SS_PASSWORD:-} ]] || SS_PASSWORD=$(new_ss_password)
  MODE=ss

  systemctl stop mihomo >/dev/null 2>&1
  port_exist_check "$PORT"

  disable_firewall
  # Shadowsocks 2022 会校验时间，服务器时间要准
  configure_chrony || exit 1

  install_mihomo || exit 1
  write_mihomo_service || exit 1
  save_info
  write_mihomo_config || exit 1
  restart_mihomo || exit 1

  print_ok "安装完成"
  show_info
}

# ─── 4-5. 修改配置 ───
# Reality 改 UUID；Shadowsocks 2022 没有 UUID，改密码
modify_uuid() {
  local input
  load_info || return 1
  prepare_templates || return 1
  print_info "当前是 $(mode_name)"
  if [[ $MODE == ss ]]; then
    read -rp "请输入密码 [回车=随机生成]：" input
    input=$(echo "$input" | tr -d '[:space:]')
    if [[ -z $input ]]; then
      SS_PASSWORD=$(new_ss_password)
    elif [[ $input =~ ^[A-Za-z0-9+/]{22}==$ ]]; then
      SS_PASSWORD=$input
    else
      print_error "密码格式不正确：要 16 字节的 base64（24 个字符，以 == 结尾），可以用 openssl rand -base64 16 生成"
      return 1
    fi
  else
    read -rp "请输入 UUID [回车=随机生成]：" input
    input=$(echo "$input" | tr -d '[:space:]')
    if [[ -z $input ]]; then
      UUID=$(new_uuid)
    elif [[ $input =~ ^[0-9a-fA-F]{8}-([0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}$ ]]; then
      UUID=$(echo "$input" | tr '[:upper:]' '[:lower:]')
    else
      print_error "UUID 格式不正确"
      return 1
    fi
  fi
  save_info
  write_mihomo_config || return 1
  restart_mihomo && show_info
}

modify_port() {
  local old_port
  load_info || return 1
  prepare_templates || return 1
  old_port=$PORT
  print_info "当前是 $(mode_name)，端口 $PORT"
  if [[ $MODE == ss ]]; then
    read_port "$(random_ss_port)"
  else
    read_port
  fi
  if [[ $PORT == "$old_port" ]]; then
    print_ok "端口没有变化"
    return 0
  fi
  port_exist_check "$PORT"
  save_info
  write_mihomo_config || return 1
  restart_mihomo || return 1
  # 80 端口跳转的地址里带着 Reality 端口，跟着改
  if [[ $MODE != ss ]]; then
    write_caddy_config || return 1
    restart_caddy || return 1
  fi
  show_info
}

# ─── 7. 服务状态 ───
service_state() {
  if systemctl is-active --quiet "$1"; then
    echo -e "${Green}运行中${Font}"
  elif systemctl list-unit-files "$1.service" >/dev/null 2>&1 && [[ -f /etc/systemd/system/$1.service || -f /lib/systemd/system/$1.service ]]; then
    echo -e "${Red}未运行${Font}"
  else
    echo -e "${Yellow}未安装${Font}"
  fi
}

container_state() {
  local state
  state=$(docker inspect -f '{{.State.Status}}' "$1" 2>/dev/null)
  case "$state" in
    running) echo -e "${Green}运行中${Font}" ;;
    "") echo -e "${Yellow}未安装${Font}" ;;
    *) echo -e "${Red}${state}${Font}" ;;
  esac
}

# Reader 的真实版本号：镜像构建时写在 org.opencontainers.image.version 标签里（比如 v1.0.3），
# 没有这个标签就退回显示镜像标签（比如 latest）；没有容器时输出为空
reader_image_version() {
  local image version
  image=$(docker inspect -f '{{.Config.Image}}' reader-next 2>/dev/null) || return 0
  version=$(docker inspect -f '{{index .Config.Labels "org.opencontainers.image.version"}}' reader-next 2>/dev/null)
  [[ $version == "<no value>" ]] && version=""
  echo "${version:-${image##*:}}"
}

# 不是本脚本装的镜像，把镜像名也显示出来
reader_version() {
  local image version
  image=$(docker inspect -f '{{.Config.Image}}' reader-next 2>/dev/null) || return 0
  version=$(reader_image_version)
  if [[ $image == "$READER_IMAGE:"* ]]; then
    echo "$version"
  else
    echo -e "$version  ${Yellow}（镜像是 $image，不是本脚本安装的）${Font}"
  fi
}

show_status() {
  echo
  echo -e "Mihomo：$(service_state mihomo)  $(mihomo_current_version)"
  echo -e "Caddy：$(service_state caddy)  $(caddy_current_version)"
  echo -e "Reader：$(container_state reader-next)  $(reader_version)"
  echo -e "时间同步：$(service_state chrony)  $(time_sync_state)"
  if load_info >/dev/null 2>&1 && [[ $MODE != ss ]]; then
    if cert_exists; then
      echo -e "SSL 证书：${Green}已申请${Font}（$DOMAIN）"
    else
      echo -e "SSL 证书：${Red}未申请${Font}（$DOMAIN）"
    fi
  fi
  echo -e "Linux 内核：$(uname -r)"
  echo -e "拥塞控制：$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)"
  echo
}

# ─── 8-10. 更新 ───
update_mihomo() {
  local version
  read -rp "请输入 Mihomo 版本号 [回车=最新版]：" version
  install_mihomo "$(echo "$version" | tr -d '[:space:]')" || return 1
  if [[ $CHANGED -eq 1 && -f $MIHOMO_CONF ]]; then
    restart_mihomo
  fi
}

update_caddy() {
  local version installed=0
  if load_info >/dev/null 2>&1; then
    require_reality || return 1
    installed=1
  fi
  read -rp "请输入 Caddy 版本号 [回车=最新版]：" version
  install_caddy "$(echo "$version" | tr -d '[:space:]')" || return 1
  if [[ $installed -eq 1 && -f $CADDY_CONF ]]; then
    # 配置模板可能随脚本升级改过，按现在的模板重新生成，版本没变也会重启
    prepare_templates || return 1
    [[ -f $CADDY_SERVICE ]] || write_caddy_service || return 1
    write_caddy_config || return 1
    restart_caddy
  elif [[ $CHANGED -eq 1 && -f $CADDY_CONF ]]; then
    [[ -f $CADDY_SERVICE ]] || write_caddy_service || return 1
    restart_caddy
  fi
}

update_reader() {
  local version old_image old_version new_version
  load_info || return 1
  require_reality || return 1
  prepare_templates || return 1
  read -rp "请输入 Reader 版本号 [回车=最新版]：" version
  version=$(echo "$version" | tr -d '[:space:]')
  if [[ -z $version ]]; then
    READER_VERSION=latest
  else
    READER_VERSION=${version#v}
  fi
  # 镜像没变也照常 up -d，改过的 reader.env 才会生效；只是提示不同
  old_image=$(docker inspect -f '{{.Image}}' reader-next 2>/dev/null)
  old_version=$(reader_image_version)
  write_compose || return 1
  start_reader || return 1
  save_info
  new_version=$(reader_image_version)
  if [[ -n $old_image && $(docker inspect -f '{{.Image}}' reader-next 2>/dev/null) == "$old_image" ]]; then
    if [[ $READER_VERSION == latest ]]; then
      print_ok "Reader 已是最新版 $new_version"
    else
      print_ok "Reader 已是 $new_version"
    fi
  elif [[ -n $old_version ]]; then
    print_ok "Reader 已从 $old_version 更新到 $new_version"
  else
    print_ok "Reader 已更新到 $new_version"
  fi
}

# ─── 11. 重新申请证书 ───
reissue_cert() {
  load_info || return 1
  require_reality || return 1
  systemctl stop caddy
  rm -rf "$CADDY_DATA"/certificates/*/"$DOMAIN"
  systemctl start caddy
  wait_for_cert
}

# ─── 12. 更新 Linux 内核 ───
# 已安装的具体版本内核包里，除了新内核和正在运行的内核，其余都删掉
kernel_packages_to_remove() {
  local new_ver=$1 running=$2 pkg ver
  dpkg-query -W -f='${binary:Package} ${db:Status-Abbrev}\n' 'linux-image-[0-9]*' 2>/dev/null |
    awk '$2 ~ /^ii/ {print $1}' |
    while read -r pkg; do
      ver=${pkg#linux-image-}
      [[ $ver == "$new_ver" || $ver == "$running" ]] && continue
      echo "$pkg"
      if dpkg-query -W -f='${db:Status-Abbrev}' "linux-headers-$ver" 2>/dev/null | grep -q '^ii'; then
        echo "linux-headers-$ver"
      fi
    done
}

backports_enabled() {
  grep -rhs -- "${OS_CODENAME}-backports" "$APT_SOURCES_LIST" "$APT_SOURCES_DIR" |
    grep -qv '^[[:space:]]*#'
}

update_kernel() {
  local choice flavor meta other_meta new_pkg new_ver running yn
  local -a remove
  if [[ $OS_ID != debian ]]; then
    print_error "更新 Linux 内核仅支持 Debian"
    return 1
  fi
  echo "1. 安装最新完整内核"
  echo "2. 安装最新云内核"
  read -rp "请选择 [1]：" choice
  case "${choice:-1}" in
    1)
      flavor=$ARCH
      other_meta=linux-image-cloud-$ARCH
      ;;
    2)
      flavor=cloud-$ARCH
      other_meta=linux-image-$ARCH
      ;;
    *)
      print_error "请输入正确的数字"
      return 1
      ;;
  esac
  meta=linux-image-$flavor

  use_archive_sources || return 1
  if ! backports_enabled; then
    echo "deb https://deb.debian.org/debian ${OS_CODENAME}-backports main" >"$APT_SOURCES_DIR/backports.list"
    print_ok "已添加 ${OS_CODENAME}-backports 源"
  fi
  print_info "安装 $meta（${OS_CODENAME}-backports）"
  apt_update || return 1
  DEBIAN_FRONTEND=noninteractive apt-get -y -t "${OS_CODENAME}-backports" install "$meta"
  judge "安装内核"

  # 先确认新内核真的装好了，才删旧内核
  new_pkg=$(dpkg-query -W -f='${Depends}' "$meta" 2>/dev/null | grep -oE 'linux-image-[0-9][^ ,|]*' | head -n1)
  new_ver=${new_pkg#linux-image-}
  if [[ -z $new_ver || ! -f /boot/vmlinuz-$new_ver || ! -f /boot/initrd.img-$new_ver ]]; then
    print_error "没有找到新内核文件，已停止，不会删除任何内核"
    return 1
  fi

  running=$(uname -r)
  mapfile -t remove < <(kernel_packages_to_remove "$new_ver" "$running")
  if dpkg-query -W -f='${db:Status-Abbrev}' "$other_meta" 2>/dev/null | grep -q '^ii'; then
    remove+=("$other_meta")
  fi
  if [[ ${#remove[@]} -gt 0 ]]; then
    print_info "卸载旧内核：${remove[*]}"
    DEBIAN_FRONTEND=noninteractive apt-get -y purge "${remove[@]}"
  fi
  if [[ ! -f /boot/vmlinuz-$new_ver ]]; then
    print_error "新内核文件不见了，千万别重启！"
    return 1
  fi
  command -v update-grub >/dev/null 2>&1 && update-grub >/dev/null 2>&1

  print_ok "新内核：$new_ver（当前运行：$running）"
  if [[ $running == "$new_ver" ]]; then
    print_ok "已经在使用最新内核"
    return 0
  fi
  print_warn "重启后才会使用新内核；重启后再运行一次「更新 Linux 内核」会清理现在这个旧内核"
  read -rp "是否现在重启？[Y/n]：" yn
  if [[ -z $yn || $yn == [Yy] ]]; then
    print_info "正在重启"
    reboot
  fi
}

# ─── 13. BBR ───
install_bbr() {
  local dir
  dir=$(mktemp -d)
  if ! wget -q --connect-timeout=5 --timeout=30 -O "$dir/tcp.sh" "$BBR_SCRIPT_URL"; then
    rm -rf "$dir"
    print_error "BBR 脚本下载失败：$BBR_SCRIPT_URL"
    return 1
  fi
  chmod +x "$dir/tcp.sh"
  (cd "$dir" && bash ./tcp.sh)
  rm -rf "$dir"
}

# ─── 3. 升级脚本 ───
# $1 比 $2 新时返回成功
version_gt() {
  [[ $1 != "$2" && $(printf '%s\n%s\n' "$1" "$2" | sort -V | tail -n1) == "$1" ]]
}

update_script() {
  local self tmp latest
  if [[ -d $SCRIPT_DIR/.git ]]; then
    print_warn "这是克隆下来的仓库，请在 $SCRIPT_DIR 里用 git pull 更新"
    return 0
  fi
  self=$SCRIPT_DIR/$(basename "${BASH_SOURCE[0]}")
  if [[ ! -f $self ]]; then
    print_error "找不到脚本文件，请重新下载：wget -N $REPO_RAW/install.sh"
    return 1
  fi
  print_info "检查最新版本"
  # 下载到同一目录再改名替换，正在运行的脚本不受影响
  tmp=$(mktemp "$SCRIPT_DIR/.install.sh.XXXXXX") || return 1
  if ! wget -q --timeout=15 --tries=2 -O "$tmp" "$REPO_RAW/install.sh"; then
    rm -f "$tmp"
    print_error "下载失败，请检查网络"
    return 1
  fi
  latest=$(sed -n 's/^SCRIPT_VERSION="\([^"]*\)".*/\1/p' "$tmp" | head -n1)
  if [[ -z $latest ]] || ! bash -n "$tmp" 2>/dev/null; then
    rm -f "$tmp"
    print_error "下载的脚本不完整，请稍后再试"
    return 1
  fi
  if ! version_gt "$latest" "$SCRIPT_VERSION"; then
    rm -f "$tmp"
    print_ok "已是最新版本 $SCRIPT_VERSION"
    return 0
  fi
  chmod 755 "$tmp"
  mv -f "$tmp" "$self"
  print_ok "已从 $SCRIPT_VERSION 升级到 $latest"
  sleep 1
  exec bash "$self"
}

# ─── 菜单 ───
menu() {
  is_root
  detect_system

  # 标题缩进 3 格
  echo -e "   Mihomo + Reality + Caddy + Reader 一键安装脚本 ${Red}[${SCRIPT_VERSION}]${Font}"
  echo -e "   https://github.com/1432433gg/mihomo-next"
  echo
  echo -e "—————— 安装 ——————"
  echo -e "${Green}1.${Font}  安装（Mihomo + Reality + Caddy + Reader）"
  echo -e "${Green}2.${Font}  安装（Mihomo + Shadowsocks 2022）"
  echo -e "${Green}3.${Font}  升级 脚本"
  echo -e "—————— 配置变更 ——————"
  echo -e "${Green}4.${Font}  修改 UUID / 密码"
  echo -e "${Green}5.${Font}  修改端口"
  echo -e "—————— 查看信息 ——————"
  echo -e "${Green}6.${Font}  查看连接信息"
  echo -e "${Green}7.${Font}  查看服务运行状态"
  echo -e "—————— 其他 ——————"
  echo -e "${Green}8.${Font}  更新 / 指定版本 Mihomo"
  echo -e "${Green}9.${Font}  更新 / 指定版本 Caddy"
  echo -e "${Green}10.${Font} 更新 / 指定版本 Reader"
  echo -e "${Green}11.${Font} 重新申请 SSL 证书"
  if [[ $OS_ID == debian ]]; then
    echo -e "${Green}12.${Font} 更新 Linux 内核"
  else
    echo -e "${Green}12.${Font} 更新 Linux 内核（仅 Debian）"
  fi
  echo -e "${Green}13.${Font} 安装 BBR 加速"
  echo -e "${Green}0.${Font}  退出"
  read -rp "请输入数字：" menu_num
  case "$menu_num" in
    1) install_all ;;
    2) install_ss ;;
    3) update_script ;;
    4) modify_uuid ;;
    5) modify_port ;;
    6) show_info ;;
    7) show_status ;;
    8) update_mihomo ;;
    9) update_caddy ;;
    10) update_reader ;;
    11) reissue_cert ;;
    12) update_kernel ;;
    13) install_bbr ;;
    0) exit 0 ;;
    *) print_error "请输入正确的数字" ;;
  esac
}

# 被 source 时（测试用）不执行菜单
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  menu "$@"
fi
