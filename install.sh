#!/usr/bin/env bash
#
# Mihomo + Reality + Caddy + Reader 一键安装脚本
# https://github.com/1432433gg/mihomo-next
#
# 用法：
#   wget -N https://raw.githubusercontent.com/1432433gg/mihomo-next/main/install.sh && chmod +x install.sh && ./install.sh
#

SCRIPT_VERSION="1.1.0"

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
WEBVIEW_REPO=1432433gg/webview-next
WEBVIEW_IMAGE=ghcr.io/1432433gg/webview-next
WEBVIEW_VERSION=1.0.0
BBR_SCRIPT_URL=https://raw.githubusercontent.com/ylx2016/Linux-NetSpeed/master/tcp.sh
# Docker 官方源（download.docker.com）
DOCKER_REPO=https://download.docker.com/linux
DOCKER_KEYRING=/usr/share/keyrings/docker-archive-keyring.gpg
DOCKER_APT_LIST=/etc/apt/sources.list.d/docker.list
# Docker 签名密钥的指纹（见 https://docs.docker.com/engine/install/debian/），下载的密钥必须是这个
DOCKER_KEY_FINGERPRINT=9DC858229FC7DD38854AE2D88D81803C0EBFCD88
# Docker 官方源已经不再给这些系统出新版本（Debian 10 停在 26.1.4，Ubuntu 20.04 停在 28.1.1）
DOCKER_FROZEN_CODENAMES="buster focal"
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
TEMPLATES="mihomo/vless-reality.yaml mihomo/shadowsocks-2022.yaml caddy/caddy.json reader/reader.env docker/docker-compose.yaml docker/docker-compose.webview.yaml docker/webview-seccomp.json systemd/mihomo.service systemd/caddy.service chrony/google.conf apt/archive.list"
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
  apt_install wget curl lsof tar gzip ca-certificates openssl dnsutils chrony
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
    echo -e "${Green}已同步${Font}"
  else
    echo -e "${Red}未同步${Font}"
  fi
}

# ─── 安装信息 ───
save_info() {
  local info_tmp
  mkdir -p "$STATE_DIR" && chmod 700 "$STATE_DIR" || return 1
  info_tmp=$(mktemp "$STATE_DIR/.info.XXXXXX") || return 1
  cat >"$info_tmp" <<EOF
MODE="$MODE"
DOMAIN="$DOMAIN"
PORT="$PORT"
UUID="$UUID"
PRIVATE_KEY="$PRIVATE_KEY"
PUBLIC_KEY="$PUBLIC_KEY"
SS_PASSWORD="$SS_PASSWORD"
READER_VERSION="$READER_VERSION"
EOF
  if [[ $? -ne 0 ]] || ! mv -f "$info_tmp" "$INFO_FILE"; then
    rm -f "$info_tmp"
    return 1
  fi
}

load_info() {
  if [[ ! -f $INFO_FILE ]]; then
    echo "未找到安装信息，请先安装（菜单 1 或 2）"
    return 1
  fi
  # shellcheck disable=SC1090
  . "$INFO_FILE"
  MODE=${MODE:-reality}
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
    echo "这台服务器已经装了 Mihomo + Shadowsocks 2022，两种安装方式只能选一种"
  else
    echo "这台服务器已经装了 Mihomo + Reality + Caddy + Reader，两种安装方式只能选一种"
  fi
  echo "要换成另一种，请重装系统后再安装"
  return 1
}

# 只装了 Shadowsocks 时没有域名、Caddy 和 Reader
require_reality() {
  if [[ $MODE == ss ]]; then
    echo "当前装的是 Mihomo + Shadowsocks 2022，没有这一项"
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

# 由 Reality 私钥算出公钥（X25519），格式和 mihomo generate reality-keypair 一样；算不出时输出为空
reality_public_key() {
  local b64 pub
  b64=$(printf '%s' "$1" | tr '_-' '/+')
  case $((${#b64} % 4)) in
    2) b64+="==" ;;
    3) b64+="=" ;;
  esac
  pub=$({
    printf '\x30\x2e\x02\x01\x00\x30\x05\x06\x03\x2b\x65\x6e\x04\x22\x04\x20'
    printf '%s' "$b64" | base64 -d 2>/dev/null
  } | openssl pkey -inform DER -pubout -outform DER 2>/dev/null | tail -c 32 | base64 | tr '+/' '-_' | tr -d '=\n')
  [[ ${#pub} -eq 43 ]] && echo "$pub"
}

# Mihomo 配置文件 listeners 里某一项的值（第一处），去掉引号
config_value() {
  sed -n '/^listeners:/,$p' "$MIHOMO_CONF" |
    sed -nE "s/^[[:space:]]*(-[[:space:]]+)?$1:[[:space:]]*\"?([^\"#[:space:]]+)\"?.*$/\2/p" | head -n1
}

# 手动改过 /etc/mihomo/config.yaml 时，把端口、UUID、Reality 密钥、Shadowsocks 密码
# 同步回安装信息，「查看连接信息」就是新的。有变化时 SYNCED=1，端口变了时 PORT_SYNCED=1
sync_info_from_config() {
  local quiet=${1:-} port uuid priv pub pass list
  local -a changed=()
  SYNCED=0
  PORT_SYNCED=0
  [[ -f $MIHOMO_CONF ]] || return 0
  load_info >/dev/null 2>&1 || return 0
  port=$(config_value port)
  if [[ $port =~ ^[0-9]+$ && $port != "$PORT" ]]; then
    changed+=("端口 $PORT → $port")
    PORT=$port
    PORT_SYNCED=1
  fi
  if [[ $MODE == ss ]]; then
    pass=$(config_value password)
    if [[ -n $pass && $pass != "$SS_PASSWORD" ]]; then
      changed+=("密码")
      SS_PASSWORD=$pass
    fi
  else
    uuid=$(config_value uuid)
    if [[ -n $uuid && $uuid != "$UUID" ]]; then
      changed+=("UUID")
      UUID=$uuid
    fi
    priv=$(config_value private-key)
    if [[ -n $priv && $priv != "$PRIVATE_KEY" ]]; then
      pub=$(reality_public_key "$priv")
      if [[ -n $pub ]]; then
        changed+=("Reality 密钥")
        PRIVATE_KEY=$priv
        PUBLIC_KEY=$pub
      else
        print_warn "配置文件里的 private-key 算不出公钥（格式不对，或者系统没有 openssl），密钥没有同步"
      fi
    fi
  fi
  if [[ ${#changed[@]} -eq 0 ]]; then
    [[ $quiet == quiet ]] || print_ok "配置文件和连接信息一致，不用同步"
    return 0
  fi
  save_info
  list=$(printf '%s、' "${changed[@]}")
  print_ok "已从配置文件同步到连接信息：${list%、}"
  SYNCED=1
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
  if ! install -m 755 -o root -g root "$tmp/mihomo" "$MIHOMO_BIN"; then
    rm -rf "$tmp"
    print_error "Mihomo 二进制文件安装失败"
    return 1
  fi
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

# 配置文件是不是按脚本模板原样生成的（没加分流之类的改动）
config_is_default() {
  local saved=$MIHOMO_CONF tmp rc=1
  tmp=$(mktemp) || return 1
  MIHOMO_CONF=$tmp
  write_mihomo_config >/dev/null 2>&1 && cmp -s "$tmp" "$saved" && rc=0
  MIHOMO_CONF=$saved
  rm -f "$tmp"
  return $rc
}

# 只替换 listeners 里第一处 key 的值，引号和行尾注释保留，其他内容不动
replace_config_value() {
  local key=$1 value=$2 tmp
  tmp=$(mktemp) || return 1
  if ! awk -v key="$key" -v val="$value" '
    /^listeners:/ { inl = 1 }
    inl && !done && match($0, "^[ \t]*(-[ \t]+)?" key ":[ \t]*") {
      prefix = substr($0, 1, RLENGTH)
      rest = substr($0, RLENGTH + 1)
      q = ""
      if (substr(rest, 1, 1) == "\"") {
        q = "\""
        n = index(substr(rest, 2), "\"")
        tail = (n > 0) ? substr(rest, n + 2) : ""
      } else if (match(rest, /^[^ \t#]+/)) {
        tail = substr(rest, RLENGTH + 1)
      } else {
        tail = rest
      }
      print prefix q val q tail
      done = 1
      next
    }
    { print }
    END { exit done ? 0 : 1 }
  ' "$MIHOMO_CONF" >"$tmp"; then
    rm -f "$tmp"
    return 1
  fi
  cat "$tmp" >"$MIHOMO_CONF"
  rm -f "$tmp"
}

# 改配置（菜单 4、5）前先看配置文件的情况，结果放在 CONFIG_STATE：
#   missing：文件不在（删掉就是想恢复默认），按模板生成
#   default：跟模板生成的一样，按模板重新生成
#   custom： 改过（比如加了分流），只替换要改的那一项
# 文件在的话先检查，再把手动改过的值同步到连接信息
inspect_config() {
  if [[ ! -f $MIHOMO_CONF ]]; then
    CONFIG_STATE=missing
    print_warn "没有找到 $MIHOMO_CONF，会按默认模板重新生成"
    return 0
  fi
  if ! check_mihomo_config; then
    print_warn "$MIHOMO_CONF 有错误：请先改好，或者删掉它恢复默认配置"
    return 1
  fi
  sync_info_from_config quiet
  if config_is_default; then
    CONFIG_STATE=default
  else
    CONFIG_STATE=custom
    print_info "配置文件改过（比如加了分流），只改这一项，其他内容保留"
  fi
}

# 把新值写进配置文件：改过的只替换这一项（检查不通过就恢复原样），否则按模板生成
apply_config_change() {
  local key=$1 value=$2 orig
  if [[ $CONFIG_STATE != custom ]]; then
    write_mihomo_config
    return
  fi
  orig=$(mktemp) || return 1
  cat "$MIHOMO_CONF" >"$orig"
  if ! replace_config_value "$key" "$value"; then
    cat "$orig" >"$MIHOMO_CONF"
    rm -f "$orig"
    print_error "$MIHOMO_CONF 的 listeners 里没找到 $key，没有修改"
    return 1
  fi
  if ! check_mihomo_config >/dev/null 2>&1; then
    cat "$orig" >"$MIHOMO_CONF"
    rm -f "$orig"
    print_error "改完 $key 后配置检查没通过，$MIHOMO_CONF 已恢复原样"
    return 1
  fi
  rm -f "$orig"
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

# Docker 版本号，比如 26.1.5（去掉 Debian 包的 +dfsg1 这类后缀）
docker_current_version() {
  command -v docker >/dev/null 2>&1 || return 0
  docker --version 2>/dev/null | sed -nE 's/^Docker version ([0-9]+(\.[0-9]+)*).*/\1/p'
}

docker_package() {
  local package
  for package in docker-ce docker.io; do
    if [[ $(dpkg-query -W -f='${db:Status-Status}' "$package" 2>/dev/null) == installed ]]; then
      echo "$package"
      return 0
    fi
  done
  return 1
}

docker_system_name() {
  if [[ $OS_ID == ubuntu ]]; then
    echo Ubuntu
  else
    echo Debian
  fi
}

# 安装或更新到指定版本（不传就是最新版），下载后校验 SHA-512；有变化时 CHANGED=1
install_caddy() {
  local version=${1:-} package_mode=${2:-} current tmp num file sums base expected actual
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
  if [[ $package_mode != preserve-package ]] && dpkg -s caddy >/dev/null 2>&1; then
    systemctl stop caddy >/dev/null 2>&1
    DEBIAN_FRONTEND=noninteractive apt-get -y -qq remove caddy >/dev/null 2>&1
    print_warn "已卸载 apt 安装的 Caddy"
  fi
  if ! install -m 755 -o root -g root "$tmp/caddy" "$CADDY_BIN"; then
    rm -rf "$tmp"
    print_error "Caddy 二进制文件安装失败"
    return 1
  fi
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
  compose_file "$COMPOSE_FILE" "$@"
}

compose_file() {
  local file=$1
  shift
  if docker compose version >/dev/null 2>&1; then
    docker compose -p "$COMPOSE_PROJECT" -f "$file" "$@"
  else
    # Compose 1.x reads relative seccomp paths from its working directory.
    (cd "$(dirname "$file")" && docker-compose -p "$COMPOSE_PROJECT" -f "$(basename "$file")" "$@")
  fi
}

webview_container() {
  local rows id
  [[ -f $COMPOSE_FILE ]] || return 1
  rows=$(docker ps -a \
    --filter "label=com.docker.compose.project=$COMPOSE_PROJECT" \
    --filter 'label=com.docker.compose.service=webview' \
    --format '{{.ID}} {{.Label "com.docker.compose.oneoff"}}' 2>/dev/null) || return 1
  id=$(awk 'NF && tolower($2) != "true" { print $1 }' <<<"$rows")
  [[ -n $id && $id != *$'\n'* ]] || return 1
  echo "$id"
}

valid_image_tag() {
  [[ $1 =~ ^[a-zA-Z0-9_][a-zA-Z0-9_.-]{0,127}$ ]]
}

# 添加 Docker 官方源：下载签名密钥并核对指纹
add_docker_source() {
  local tmp fps
  print_info "添加 Docker 官方源"
  apt_install gnupg || return 1
  tmp=$(mktemp)
  if ! curl -fsSL --max-time 30 -o "$tmp" "$DOCKER_REPO/$OS_ID/gpg"; then
    rm -f "$tmp"
    print_warn "下载 Docker 签名密钥失败：$DOCKER_REPO/$OS_ID/gpg"
    return 1
  fi
  if ! gpg --batch --yes --dearmor -o "$DOCKER_KEYRING" "$tmp" 2>/dev/null; then
    rm -f "$tmp" "$DOCKER_KEYRING"
    print_warn "Docker 签名密钥格式不对"
    return 1
  fi
  rm -f "$tmp"
  fps=$(gpg --dry-run --quiet --no-keyring --import --import-options import-show "$DOCKER_KEYRING" 2>/dev/null | grep -oE '[0-9A-F]{40}')
  if ! grep -qx "$DOCKER_KEY_FINGERPRINT" <<<"$fps"; then
    rm -f "$DOCKER_KEYRING"
    print_warn "Docker 签名密钥的指纹对不上，已删掉，没有添加软件源（下载到的指纹：${fps:-无}）"
    return 1
  fi
  echo "deb [arch=$(dpkg --print-architecture) signed-by=$DOCKER_KEYRING] $DOCKER_REPO/$OS_ID $OS_CODENAME stable" >"$DOCKER_APT_LIST"
  if ! apt_update; then
    rm -f "$DOCKER_APT_LIST"
    apt_update
    return 1
  fi
  print_ok "已添加 Docker 官方源（$OS_ID $OS_CODENAME）"
}

# 第一次安装用 Docker 官方源（docker-ce）；官方源加不上或装不上时，退回系统软件源里的 docker.io
# 已经装了 Docker 的不动
install_docker() {
  if ! command -v docker >/dev/null 2>&1; then
    if add_docker_source; then
      print_info "安装 Docker（官方源）"
      if apt_install docker-ce docker-ce-cli containerd.io docker-compose-plugin; then
        if [[ " $DOCKER_FROZEN_CODENAMES " == *" $OS_CODENAME "* ]]; then
          print_warn "Docker 官方已不再给 $OS_ID $OS_CODENAME 出新版本：装的是它的最后一个版本，以后不会再有更新；Reader 照常能用"
        fi
      else
        print_warn "从官方源安装 Docker 失败，改用系统软件源里的 docker.io"
        rm -f "$DOCKER_APT_LIST"
        apt_update || return 1
      fi
    else
      print_warn "改用系统软件源里的 docker.io"
    fi
    if ! command -v docker >/dev/null 2>&1; then
      print_info "安装 Docker（系统软件源）"
      apt_install docker.io || {
        print_error "Docker 安装失败"
        return 1
      }
    fi
  fi
  systemctl enable --now docker >/dev/null 2>&1
  if ! docker compose version >/dev/null 2>&1 && ! command -v docker-compose >/dev/null 2>&1; then
    apt_install docker-compose-v2 2>/dev/null || apt_install docker-compose || {
      print_error "docker compose 安装失败"
      return 1
    }
  fi
  print_ok "Docker 就绪：$(docker_current_version)"
}

reader_owned() {
  [[ $(docker inspect -f '{{index .Config.Labels "com.docker.compose.project"}}' reader-next 2>/dev/null) == "$COMPOSE_PROJECT" ]]
}

reader_service_ready() {
  local name=$1 image=$2 expected_id=$3 status id
  id=$(compose ps -q "$name") || return 1
  [[ -n $id ]] || return 1
  if [[ $(docker inspect -f '{{.Config.Image}} {{.Image}}' "$id" 2>/dev/null) != "$image $expected_id" ]]; then
    return 1
  fi
  local attempt
  for ((attempt=0; attempt<45; attempt++)); do
    status=$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' "$id" 2>/dev/null)
    case "$status" in
      healthy) return 0 ;;
      running) [[ $name != webview ]] && return 0; return 1 ;;
      starting|created|restarting) sleep 2 ;;
      *) return 1 ;;
    esac
  done
  return 1
}

# Stage next to the live file so Compose resolves reader.env and the sandbox profile consistently.
deploy_reader() (
  local target=$1 completion=${2:-} reader_ref bundle image_id webview_id next previous="" profile_tmp=""
  local old_ref old_id old_web_id old_web_ref old_web had_reader=0
  local WEBVIEW_VERSION=$WEBVIEW_VERSION
  valid_image_tag "$target" || { print_error "Reader 版本无效：$target"; return 1; }
  reader_ref="$READER_IMAGE:$target"
  mkdir -p "$STATE_DIR" || return 1
  exec 9>"$STATE_DIR/.reader-deploy.lock" || return 1
  flock -x 9 || return 1
  if docker inspect reader-next >/dev/null 2>&1; then
    if ! reader_owned || [[ ! -f $COMPOSE_FILE ]]; then
      print_error "已有同名 Reader 容器，且无法使用本脚本的配置恢复。请检查后再试。"
      return 1
    fi
    had_reader=1
    old_ref=$(docker inspect -f '{{.Config.Image}}' reader-next) || return 1
    old_id=$(docker inspect -f '{{.Image}}' reader-next) || return 1
    old_web=$(webview_container) || :
    if [[ -n $old_web ]]; then
      old_web_ref=$(docker inspect -f '{{.Config.Image}}' "$old_web") || return 1
      old_web_id=$(docker inspect -f '{{.Image}}' "$old_web") || return 1
    fi
  fi
  print_info "下载 Reader 镜像 $reader_ref"
  if ! docker pull "$reader_ref"; then
    print_error "Reader 镜像拉取失败：$reader_ref"
    return 1
  fi
  image_id=$(docker image inspect -f '{{.Id}}' "$reader_ref") || return 1
  bundle=$(docker image inspect -f '{{index .Config.Labels "io.reader-next.bundled-webview"}}' "$reader_ref") || return 1
  if [[ $target == 1.2.1 && $bundle != 1 ]]; then
    print_error "Reader 1.2.1 镜像缺少 WebView 能力标签：$reader_ref"
    return 1
  fi
  local template=docker/docker-compose.yaml schema=3.3
  if [[ $bundle == 1 ]]; then
    template=docker/docker-compose.webview.yaml
    schema=2.3
    if [[ -f $STATE_DIR/webview-version ]]; then
      if ! IFS= read -r WEBVIEW_VERSION < "$STATE_DIR/webview-version" || ! valid_image_tag "$WEBVIEW_VERSION"; then
        print_error "已保存的 WebView 版本无效：$STATE_DIR/webview-version"
        return 1
      fi
    fi
    if ! docker info --format '{{json .SecurityOptions}}' | grep -q 'name=seccomp'; then
      print_error "当前 Docker 缺少 Chromium 所需的 seccomp 支持"
      return 1
    fi
    print_info "下载 WebView 镜像 $WEBVIEW_IMAGE:$WEBVIEW_VERSION"
    if ! docker pull "$WEBVIEW_IMAGE:$WEBVIEW_VERSION"; then
      print_error "WebView 镜像拉取失败：$WEBVIEW_IMAGE:$WEBVIEW_VERSION"
      return 1
    fi
    webview_id=$(docker image inspect -f '{{.Id}}' "$WEBVIEW_IMAGE:$WEBVIEW_VERSION") || return 1
  fi

  # Template preparation owns its own EXIT trap when called from the menu.
  next=$(mktemp "$STATE_DIR/.reader-compose.XXXXXX") || return 1
  trap 'rm -f "$next" ${profile_tmp:+"$profile_tmp"} ${previous:+"$previous"}' EXIT
  if [[ ! -f $READER_ENV ]]; then
    render_template reader/reader.env "$READER_ENV" || return 1
  fi
  if [[ $bundle == 1 ]] && ! cmp -s "$TEMPLATE_DIR/docker/webview-seccomp.json" "$STATE_DIR/webview-seccomp.json"; then
    profile_tmp=$(mktemp "$STATE_DIR/.webview-seccomp.XXXXXX") || return 1
    cp "$TEMPLATE_DIR/docker/webview-seccomp.json" "$profile_tmp" || return 1
    mv -f "$profile_tmp" "$STATE_DIR/webview-seccomp.json" || return 1
  fi
  render_template "$template" "$next" READER_VERSION="$target" WEBVIEW_VERSION="$WEBVIEW_VERSION" || return 1
  if ! docker compose version >/dev/null 2>&1; then
    sed -i "1i version: \"$schema\"" "$next" || return 1
  fi
  if ! compose_file "$next" config -q; then
    print_error "Docker Compose 配置校验失败，请检查 Compose 版本和模板"
    return 1
  fi

  if [[ -f $COMPOSE_FILE ]]; then
    previous=$(mktemp "$STATE_DIR/.reader-previous.XXXXXX") || return 1
    cp -p "$COMPOSE_FILE" "$previous" || return 1
  fi
  mv -f "$next" "$COMPOSE_FILE" || return 1

  local out failure=""
  if ! out=$(compose up -d --remove-orphans 2>&1); then
    printf '%s\n' "$out" | tail -n 8 >&2
    failure="Docker Compose 启动失败"
  elif [[ $bundle == 1 ]] && ! reader_service_ready webview "$WEBVIEW_IMAGE:$WEBVIEW_VERSION" "$webview_id"; then
    failure="WebView $WEBVIEW_VERSION 未通过健康检查"
  elif ! reader_service_ready reader "$reader_ref" "$image_id"; then
    failure="Reader $target 未通过健康检查"
  elif [[ $completion == save-info ]] && ! save_info; then
    failure="安装目录的版本记录保存失败"
  elif [[ $completion == reinstall ]] && ! finish_reality_reinstall; then
    failure="入口重新配置失败，正在恢复原 Reader 部署"
  fi
  if [[ -n $failure ]]; then
    print_error "$failure"
    # A failed pull or validation leaves the current deployment running. If up
    # changed the containers, restore the preceding local image and Compose file.
    if [[ $had_reader == 0 ]]; then
      if ! compose down --remove-orphans; then
        print_error "请检查失败部署的容器，数据卷已保留"
      fi
    fi
    if [[ -n $previous ]]; then
      if ! mv -f "$previous" "$COMPOSE_FILE"; then
        print_error "无法恢复 Compose 文件，原配置保存在 $previous"
        previous=""
        return 1
      fi
    else
      rm -f "$COMPOSE_FILE"
    fi
    if [[ $had_reader == 1 ]]; then
      if docker image tag "$old_id" "$old_ref" &&
         { [[ -z $old_web_id ]] || docker image tag "$old_web_id" "$old_web_ref"; } &&
         compose up -d --remove-orphans &&
         { [[ -z $old_web_id ]] || reader_service_ready webview "$old_web_ref" "$old_web_id"; } &&
         reader_service_ready reader "$old_ref" "$old_id"; then
        print_ok "已恢复原 Reader 部署和数据卷"
      else
        print_error "原配置和数据卷已保留，自动恢复未通过。请检查 Docker 日志后重试。"
      fi
    fi
    return 1
  fi
  print_ok "Reader $target 运行中"
  if [[ $bundle == 1 ]]; then
    print_ok "WebView $WEBVIEW_VERSION 运行中"
  fi
)

prepare_reality_ports() {
  systemctl stop mihomo >/dev/null 2>&1 || :
  systemctl stop caddy >/dev/null 2>&1 || :
  port_exist_check 80 || return 1
  port_exist_check "$PORT" || return 1
  port_exist_check "$CADDY_TLS_PORT" || return 1
  if ! reader_owned || [[ $(docker inspect -f '{{.State.Running}}' reader-next 2>/dev/null) != true ]]; then
    port_exist_check "$READER_PORT" || return 1
  fi
}

configure_reality_ingress() {
  # Mihomo 先占住 Reality 端口，Caddy 再申请证书。
  install_mihomo || return 1
  write_mihomo_service || return 1
  if [[ ${1:-} != preserve-package || -z ${UUID:-} || -z ${PRIVATE_KEY:-} || -z ${PUBLIC_KEY:-} ]]; then
    UUID=$(new_uuid) || return 1
    generate_keys || { print_error "生成 Reality 密钥失败"; return 1; }
  fi
  MODE=reality
  write_mihomo_config || return 1
  restart_mihomo || return 1

  install_caddy "" "${1:-}" || return 1
  write_caddy_service || return 1
  write_caddy_config || return 1
  restart_caddy
}

# deploy_reader keeps its image and Compose backup until this step returns.
finish_reality_reinstall() (
  local snapshot file service i restored=1
  local -a files=("$MIHOMO_BIN" "$MIHOMO_CONF" "$MIHOMO_SERVICE" "$CADDY_BIN" "$CADDY_CONF" "$CADDY_SERVICE")
  local -A active enabled
  snapshot=$(mktemp -d "$STATE_DIR/.ingress-previous.XXXXXX") || return 1
  trap '[[ -z $snapshot ]] || rm -rf "$snapshot"' EXIT
  for i in "${!files[@]}"; do
    file=${files[$i]}
    if [[ -e $file || -L $file ]]; then
      cp -a "$file" "$snapshot/$i" || return 1
    fi
  done
  for service in mihomo caddy; do
    if systemctl is-active --quiet "$service"; then active[$service]=1; fi
    enabled[$service]=$(systemctl is-enabled "$service" 2>/dev/null) || :
  done

  if prepare_reality_ports && configure_reality_ingress preserve-package && save_info; then
    return 0
  fi

  # Stop partially configured services before restoring their units, binaries and config.
  for service in caddy mihomo; do
    systemctl stop "$service" >/dev/null 2>&1 || :
  done
  for i in "${!files[@]}"; do
    file=${files[$i]}
    if [[ -e $snapshot/$i || -L $snapshot/$i ]]; then
      cp -a --remove-destination "$snapshot/$i" "$file" || restored=0
    else
      rm -f "$file" || restored=0
    fi
  done
  systemctl daemon-reload || restored=0
  for service in mihomo caddy; do
    case "${enabled[$service]}" in
      enabled) systemctl enable "$service" >/dev/null 2>&1 || restored=0 ;;
      enabled-runtime)
        systemctl disable "$service" >/dev/null 2>&1 &&
          systemctl enable --runtime "$service" >/dev/null 2>&1 || restored=0 ;;
      disabled|not-found|'') systemctl disable "$service" >/dev/null 2>&1 || : ;;
    esac
    if [[ ${active[$service]:-0} == 1 ]]; then
      systemctl start "$service" && systemctl is-active --quiet "$service" || restored=0
    elif systemctl is-active --quiet "$service"; then
      restored=0
    fi
  done
  if [[ $restored == 1 ]]; then
    print_ok "已恢复原 Mihomo 和 Caddy 配置与运行状态"
  else
    print_error "入口自动恢复失败，原文件备份保存在 $snapshot"
    snapshot=""
  fi
  return 1
)

# ─── 1. 安装 ───
install_all() {
  local reinstall=0 requested_reader_version=${READER_INSTALL_VERSION:-}
  check_install_mode reality || return 1
  prepare_templates || exit 1
  read_domain
  read_port

  install_deps
  domain_check

  # 重新安装时沿用原来的 UUID 和密钥，客户端不用改
  if [[ -f $INFO_FILE ]]; then
    local new_domain=$DOMAIN new_port=$PORT
    load_info || exit 1
    DOMAIN=$new_domain
    PORT=$new_port
    reinstall=1
  fi

  READER_VERSION=${requested_reader_version:-${READER_VERSION:-latest}}
  READER_VERSION=${READER_VERSION#v}

  if [[ $reinstall -eq 1 ]]; then
    # 先完成时间同步，失败时不切换 Reader，也不停止原入口。
    configure_chrony || exit 1
    install_docker || exit 1
    deploy_reader "$READER_VERSION" reinstall || exit 1
  else
    prepare_reality_ports || exit 1
    disable_firewall
    configure_chrony || exit 1
    install_docker || exit 1
    # 关闭防火墙后重启 Docker，让它重新生成自己的 nftables 规则。
    systemctl restart docker >/dev/null 2>&1
    deploy_reader "$READER_VERSION" || exit 1
    configure_reality_ingress || exit 1
    save_info || exit 1
  fi

  wait_for_cert || :
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
  write_mihomo_config || exit 1
  restart_mihomo || exit 1
  save_info || exit 1

  print_ok "安装完成"
  show_info
}

# ─── 4-5. 修改配置 ───
# Reality 改 UUID；Shadowsocks 2022 没有 UUID，改密码
modify_uuid() {
  local input
  load_info || return 1
  prepare_templates || return 1
  inspect_config || return 1
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
  if [[ $MODE == ss ]]; then
    apply_config_change password "$SS_PASSWORD" || return 1
  else
    apply_config_change uuid "$UUID" || return 1
  fi
  save_info
  restart_mihomo && show_info
}

modify_port() {
  local old_port
  load_info || return 1
  prepare_templates || return 1
  inspect_config || return 1
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
  apply_config_change port "$PORT" || return 1
  save_info
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

# 优先显示镜像版本标签，其次显示容器镜像引用里的标签。
container_image_version() {
  local image version
  image=$(docker inspect -f '{{.Config.Image}}' "$1" 2>/dev/null) || return 0
  version=$(docker inspect -f '{{index .Config.Labels "org.opencontainers.image.version"}}' "$1" 2>/dev/null)
  [[ $version == "<no value>" ]] && version=""
  echo "${version:-${image##*:}}"
}

reader_image_version() {
  container_image_version reader-next
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

# 当前的 TCP 拥塞控制算法，并说明 BBR 有没有开
congestion_state() {
  local cc
  cc=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)
  case "$cc" in
    "") echo -e "${Yellow}未知${Font}" ;;
    bbr*) echo -e "${cc}  ${Green}已开启${Font}" ;;
    *) echo -e "${cc}  ${Yellow}未开启${Font}" ;;
  esac
}

show_status() {
  local mode webview docker_version docker_type
  mode=$(installed_mode) || mode=""
  case "$mode" in
    reality) echo -e "Deployment：${Green}Reality + Caddy + Reader${Font}" ;;
    ss) echo -e "Deployment：${Green}Shadowsocks 2022${Font}" ;;
    *) echo "Deployment：未找到安装记录" ;;
  esac
  echo -e "Mihomo：$(service_state mihomo) $(mihomo_current_version)"
  if [[ $mode == reality ]]; then
    echo -e "Caddy：$(service_state caddy) $(caddy_current_version)"
    docker_version=$(docker_current_version)
    if command -v docker >/dev/null 2>&1; then
      case "$(docker_package)" in
        docker-ce) docker_type="Docker 官方版" ;;
        docker.io) docker_type="$(docker_system_name) 系统版" ;;
        *) docker_type="安装来源未知" ;;
      esac
    fi
    echo -e "Docker：$(service_state docker) $docker_version${docker_type:+（$docker_type）}"
    echo -e "Reader：$(container_state reader-next) $(reader_version)"
    if webview=$(webview_container); then
      echo -e "WebView：$(container_state "$webview") $(container_image_version "$webview")"
    fi
  fi
  echo -e "时间同步：$(service_state chrony) $(time_sync_state)"
  echo -e "当前时间：$(now_time)"
  if [[ $mode == reality ]] && load_info >/dev/null 2>&1; then
    if cert_exists; then
      echo -e "SSL 证书：${Green}已申请${Font} $DOMAIN"
    else
      echo -e "SSL 证书：${Red}未申请${Font} $DOMAIN"
    fi
  fi
  echo -e "Linux 内核：$(uname -r)"
  echo -e "拥塞控制：$(congestion_state)"
  echo
}

# ─── 8-10. 更新 ───
update_mihomo() {
  local version
  read -rp "请输入 Mihomo 版本号 [回车=最新版]：" version
  install_mihomo "$(echo "$version" | tr -d '[:space:]')" || return 1
  # 配置文件被删掉：按默认模板重新生成（想恢复默认配置时就删掉它再选 8）
  if [[ ! -f $MIHOMO_CONF ]]; then
    load_info >/dev/null 2>&1 || return 0
    print_warn "没有找到 $MIHOMO_CONF，按默认模板重新生成"
    prepare_templates || return 1
    write_mihomo_config || return 1
    restart_mihomo || return 1
    show_info
    return 0
  fi
  # 配置文件可能被手动改过：先检查能不能用，再同步到连接信息，有改动就重启让它生效
  if ! check_mihomo_config; then
    print_warn "$MIHOMO_CONF 有错误，没有同步也没有重启，改好后再选一次 8"
    return 1
  fi
  sync_info_from_config
  if [[ $CHANGED -eq 1 || $SYNCED -eq 1 ]]; then
    restart_mihomo || return 1
  fi
  # Reality 端口变了：80 端口跳转的地址也跟着改
  if [[ $PORT_SYNCED -eq 1 && $MODE != ss && -f $CADDY_CONF ]]; then
    prepare_templates || return 1
    write_caddy_config || return 1
    restart_caddy || return 1
  fi
  if [[ $SYNCED -eq 1 ]]; then
    show_info
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
  read -rp "请输入 Reader 版本号 [回车=最新版]：" version || return 1
  version=$(echo "$version" | tr -d '[:space:]')
  if [[ -z $version ]]; then
    READER_VERSION=latest
  else
    READER_VERSION=${version#v}
  fi
  # 镜像没变也照常 up -d，改过的 reader.env 才会生效；只是提示不同
  old_image=$(docker inspect -f '{{.Image}}' reader-next 2>/dev/null)
  old_version=$(reader_image_version)
  deploy_reader "$READER_VERSION" save-info || return 1
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

# ─── 11. 更新 / 指定版本 WebView ───
update_webview() (
  local webview details old_ref old_id old_running old_version target ref image_id
  local next="" previous="" version_file="" activated=0 restored="" out failure="" latest=0
  load_info || return 1
  require_reality || return 1
  exec 9>"$STATE_DIR/.reader-deploy.lock" || return 1
  flock -x 9 || return 1
  if ! webview=$(webview_container); then
    echo "未安装 WebView"
    return 1
  fi
  details=$(docker inspect -f '{{.Config.Image}} {{.Image}} {{.State.Running}}' "$webview") || return 1
  read -r old_ref old_id old_running <<<"$details"
  if [[ $old_ref != "$WEBVIEW_IMAGE:"* || -z $old_id ]]; then
    print_error "WebView 容器与本脚本的镜像不匹配"
    return 1
  fi
  old_version=$(container_image_version "$webview")

  read -rp "请输入 WebView 版本号 [回车=最新版]：" target || return 1
  target=${target//[[:space:]]/}
  if [[ -z $target ]]; then
    latest=1
    print_info "获取 WebView 最新版本"
    target=$(github_latest_tag "$WEBVIEW_REPO") || {
      print_error "无法访问 GitHub API，可以手动指定版本号"
      return 1
    }
  fi
  target=${target#v}
  valid_image_tag "$target" || { print_error "WebView 版本无效：$target"; return 1; }
  ref="$WEBVIEW_IMAGE:$target"

  # 保留其他服务和本机配置，只改现有 WebView 的镜像引用。
  trap 'rm -f -- "${next:-}" "${version_file:-}"; if [[ $activated == 0 ]]; then rm -f -- "${previous:-}"; elif [[ -f $previous ]]; then print_error "原 Compose 配置保存在 $previous"; fi' EXIT
  next=$(mktemp "$STATE_DIR/.webview-compose.XXXXXX") || return 1
  previous=$(mktemp "$STATE_DIR/.webview-previous.XXXXXX") || return 1
  version_file=$(mktemp "$STATE_DIR/.webview-version.XXXXXX") || return 1
  if ! awk -v old="$old_ref" -v new="$ref" '
    /^[^[:space:]#]/ { webview = 0 }
    /^  [^[:space:]#]/ { webview = ($0 ~ /^  webview:[[:space:]]*(#.*)?$/) }
    webview && /^    image:[[:space:]]/ {
      image = $2
      gsub(/["\047]/, "", image)
      if (image != old) exit 1
      pos = index($0, $2)
      print substr($0, 1, pos - 1) new substr($0, pos + length($2))
      changed++
      next
    }
    { print }
    END { if (changed != 1) exit 1 }
  ' "$COMPOSE_FILE" >"$next"; then
    print_error "WebView 容器与当前 Compose 配置不匹配"
    return 1
  fi
  cp -p "$COMPOSE_FILE" "$previous" && chmod --reference="$COMPOSE_FILE" "$next" &&
    printf '%s\n' "$target" >"$version_file" || return 1
  if ! compose_file "$next" config -q; then
    print_error "Docker Compose 配置校验失败"
    return 1
  fi

  print_info "下载 WebView 镜像 $ref"
  if ! docker pull "$ref"; then
    print_error "WebView 镜像拉取失败：$ref"
    return 1
  fi
  if ! image_id=$(docker image inspect -f '{{.Id}}' "$ref"); then
    [[ $ref != "$old_ref" ]] || docker image tag "$old_id" "$old_ref"
    print_error "无法读取 WebView 镜像：$ref"
    return 1
  fi
  if [[ $ref == "$old_ref" && $image_id == "$old_id" ]] && reader_service_ready webview "$ref" "$image_id"; then
    if ! mv -fT "$version_file" "$STATE_DIR/webview-version"; then
      print_error "保存 WebView 版本失败"
      return 1
    fi
    if [[ $latest -eq 1 ]]; then
      print_ok "WebView 已是最新版 $old_version"
    else
      print_ok "WebView 已是 $old_version"
    fi
    return 0
  fi

  if ! mv -fT "$next" "$COMPOSE_FILE"; then
    [[ $ref != "$old_ref" ]] || docker image tag "$old_id" "$old_ref"
    print_error "无法替换 WebView Compose 配置"
    return 1
  fi
  activated=1
  if ! out=$(compose up -d --no-deps webview 2>&1); then
    printf '%s\n' "$out" | tail -n 8 >&2
    failure="WebView 启动失败"
  elif ! reader_service_ready webview "$ref" "$image_id"; then
    failure="WebView $target 未通过健康检查"
  elif ! mv -fT "$version_file" "$STATE_DIR/webview-version"; then
    failure="保存 WebView 版本失败"
  fi
  if [[ -n $failure ]]; then
    print_error "$failure"
    if ! mv -fT "$previous" "$COMPOSE_FILE"; then
      print_error "恢复原 Compose 配置失败"
      return 1
    fi
    if docker image tag "$old_id" "$old_ref"; then
      if [[ $old_running == true ]]; then
        if compose up -d --no-deps webview && reader_service_ready webview "$old_ref" "$old_id"; then
          restored=1
        fi
      elif compose up --no-start --no-deps webview &&
           webview=$(webview_container) &&
           [[ $(docker inspect -f '{{.Config.Image}} {{.Image}} {{.State.Running}}' "$webview") == "$old_ref $old_id false" ]]; then
        restored=1
      fi
    fi
    if [[ -n $restored ]]; then
      print_ok "已恢复原 WebView $old_version"
    else
      print_error "原 Compose 配置已恢复，WebView 自动恢复未通过"
    fi
    return 1
  fi
  activated=0
  print_ok "WebView 已从 $old_version 更新到 $target"
)

# 匹配完整 APT 版本或简写的引擎版本，并保留 APT 的 epoch 和发行版后缀。
docker_package_version() {
  local package=$1 requested=$2 source unused version upstream best=""
  source=$(apt-cache madison "$package") || return 1
  while IFS='|' read -r unused version unused; do
    version=${version//[[:space:]]/}
    [[ -n $version ]] || continue
    if [[ $version == "$requested" ]]; then
      echo "$version"
      return 0
    fi
    upstream=${version#*:}
    upstream=${upstream%%[-+~]*}
    if [[ $upstream == "$requested" ]] && { [[ -z $best ]] || dpkg --compare-versions "$version" gt "$best"; }; then
      best=$version
    fi
  done <<<"$source"
  [[ -n $best ]] && echo "$best"
}

# ─── 12. 更新 / 指定版本 Docker ───
update_docker() {
  local pkgs=() apt_options=(--only-upgrade --no-remove) p old new package source requested version installed
  load_info || return 1
  require_reality || return 1
  if ! command -v docker >/dev/null 2>&1; then
    print_error "没有安装 Docker"
    return 1
  fi
  if ! package=$(docker_package); then
    print_error "Docker 不是用 apt 装的，脚本没法更新它"
    return 1
  fi
  case "$package" in
    docker-ce) source="Docker 官方源" ;;
    docker.io) source="$(docker_system_name) 软件源" ;;
  esac
  read -rp "请输入 Docker 版本号 [回车=${source}最新版]：" requested || return 1
  requested=${requested//[[:space:]]/}
  if [[ -n $requested ]]; then
    requested=${requested#v}
    if [[ ! $requested =~ ^[0-9][0-9A-Za-z.+:~-]*$ ]]; then
      print_error "Docker 版本无效：$requested"
      return 1
    fi
  fi

  apt_update || return 1
  if [[ -n $requested ]]; then
    if ! version=$(docker_package_version "$package" "$requested"); then
      print_error "${source}找不到 Docker 版本 $requested"
      return 1
    fi
    pkgs=("$package=$version")
    if [[ $package == docker-ce ]]; then
      if [[ $(dpkg-query -W -f='${db:Status-Status}' docker-ce-cli 2>/dev/null) != installed ]] ||
         [[ $(docker_package_version docker-ce-cli "$version") != "$version" ]]; then
        print_error "找不到已安装的 Docker CLI 或与 Docker $requested 匹配的软件包"
        return 1
      fi
      pkgs+=("docker-ce-cli=$version")
    fi
    # 已明确输入版本号时，允许将这组已安装的软件包切换到较旧版本。
    for p in "${pkgs[@]}"; do
      installed=$(dpkg-query -W -f='${Version}' "${p%%=*}" 2>/dev/null) || return 1
      if dpkg --compare-versions "$version" lt "$installed"; then
        apt_options+=(--allow-downgrades)
        break
      fi
    done
  else
    for p in docker.io docker-compose-v2 docker-compose docker-ce docker-ce-cli containerd.io docker-compose-plugin; do
      [[ $(dpkg-query -W -f='${db:Status-Status}' "$p" 2>/dev/null) == installed ]] && pkgs+=("$p")
    done
  fi

  old=$(docker_current_version)
  print_info "更新 Docker（${pkgs[*]}）"
  if ! DEBIAN_FRONTEND=noninteractive apt-get -o DPkg::Lock::Timeout=300 -o Dpkg::Options::=--force-confold \
    -y -qq install "${apt_options[@]}" "${pkgs[@]}" >/dev/null; then
    print_error "Docker 更新失败"
    return 1
  fi
  if [[ -n $requested ]]; then
    for p in "${pkgs[@]}"; do
      if [[ $(dpkg-query -W -f='${Version}' "${p%%=*}" 2>/dev/null) != "$version" ]]; then
        print_error "Docker 未切换到指定版本 $requested"
        return 1
      fi
    done
  fi
  if ! systemctl enable --now docker >/dev/null 2>&1; then
    print_error "Docker 服务启动失败"
    return 1
  fi
  new=$(docker_current_version)
  if [[ $old == "$new" ]]; then
    if [[ -n $requested ]]; then
      print_ok "Docker 已是 $new"
    else
      print_ok "Docker 已是${source}里的最新版 $new"
    fi
  else
    print_ok "Docker 已从 $old 更新到 $new"
  fi
  # 更新时 Docker 会重启；等一下 Reader，没起来就重新启动它
  sleep 5
  if [[ $(docker inspect -f '{{.State.Running}}' reader-next 2>/dev/null) != true && -f $COMPOSE_FILE ]]; then
    compose up -d >/dev/null 2>&1
    sleep 2
  fi
  echo -e "Reader：$(container_state reader-next)  $(reader_version)"
}

# ─── 13. 重新申请证书 ───
reissue_cert() {
  load_info || return 1
  require_reality || return 1
  systemctl stop caddy
  rm -rf "$CADDY_DATA"/certificates/*/"$DOMAIN"
  systemctl start caddy
  wait_for_cert
}

# ─── 14. 更新 Linux 内核 ───
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

# ─── 15. BBR ───
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
show_menu() {
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
  echo -e "${Green}11.${Font} 更新 / 指定版本 WebView"
  echo -e "${Green}12.${Font} 更新 / 指定版本 Docker"
  echo -e "${Green}13.${Font} 重新申请 SSL 证书"
  if [[ $OS_ID == debian ]]; then
    echo -e "${Green}14.${Font} 更新 Linux 内核"
  else
    echo -e "${Green}14.${Font} 更新 Linux 内核（仅 Debian）"
  fi
  echo -e "${Green}15.${Font} 安装 BBR 加速"
  echo -e "${Green}0.${Font}  退出"
}

menu() {
  local menu_num mode
  is_root
  detect_system
  while :; do
    show_menu
    read -rp "请输入数字：" menu_num || return 0
    case "$menu_num" in
      4|5|6|8|9|10|11|12|13)
        mode=$(installed_mode) || mode=""
        if [[ $mode != reality && $mode != ss ]]; then
          if [[ $menu_num == 6 ]]; then
            echo "未找到安装信息，请先安装（菜单 1 或 2）"
          else
            echo "请先通过菜单 1 或 2 完成安装"
          fi
          echo
          continue
        fi
        ;;
    esac
    break
  done
  case "$menu_num" in
    1) install_all ;;
    2) install_ss ;;
    3) update_script ;;
    4) modify_uuid ;;
    5) modify_port ;;
    6) show_info ;;
    7)
      echo
      show_status
      ;;
    8) update_mihomo ;;
    9) update_caddy ;;
    10) update_reader ;;
    11) update_webview ;;
    12) update_docker ;;
    13) reissue_cert ;;
    14) update_kernel ;;
    15) install_bbr ;;
    0) exit 0 ;;
    *) print_error "请输入正确的数字" ;;
  esac
}

# 被 source 时（测试用）不执行菜单
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  menu "$@"
fi
