#!/usr/bin/env bash
# Set COMPOSE_V1 and COMPOSE_V2 to validator executable paths to run real config checks.
set -euo pipefail
repo=$(cd "$(dirname "$0")/.." && pwd)
source "$repo/install.sh"
root=$(mktemp -d)
trap 'rm -rf "$root"' EXIT
export COMPOSE_ANSI=never

fail() { printf 'FAIL [%s/%s]: %s\n' "$entry" "$name" "$*" >&2; tail -n 25 "$calls" >&2; exit 1; }
expect() { "$@" || fail "expected: $*"; }
reject() { if "$@"; then fail "unexpected: $*"; fi; }
has() { grep -Fq -- "$1" "$2"; }
clear_calls() { : >"$calls"; }
no_webview_actions() {
  reject grep -Eq 'pull .*/webview-next:|^compose (up|stop|rm).*webview' "$calls"
}

reset() {
  name=$1
  STATE_DIR="$root/$entry-$name"
  mkdir -p "$STATE_DIR"
  COMPOSE_FILE=$STATE_DIR/docker-compose.yaml
  READER_ENV=$STATE_DIR/reader.env
  INFO_FILE=$STATE_DIR/info.conf
  calls=$STATE_DIR/calls
  fixture_mode=reality
  READER_VERSION=latest
  unset READER_INSTALL_VERSION
  printf 'persistent Reader data\n' >"$STATE_DIR/reader-data"
  clear_calls
}

# Intercept system preparation, keeping the installer menu and deployment code.
is_root() { :; }
detect_system() { OS_ID=debian; }
check_install_mode() { :; }
read_domain() { DOMAIN=example.invalid; }
read_port() { PORT=443; }
install_deps() { :; }
domain_check() { :; }
configure_chrony() { :; }
install_docker() { :; }
prepare_reality_ports() { :; }
disable_firewall() { :; }
configure_reality_ingress() { :; }
finish_reality_reinstall() { :; }
wait_for_cert() { :; }
show_info() { :; }
systemctl() { :; }
flock() { [[ "$*" == '-x 9' ]]; }
sleep() { :; }
save_info() { printf '%s\n' "$READER_VERSION" >"$INFO_FILE"; }
load_info() { MODE=$fixture_mode; [[ -f $INFO_FILE ]]; }
installed_mode() { printf '%s\n' "$fixture_mode"; }
service_state() { echo running; }
mihomo_current_version() { echo fixture; }
caddy_current_version() { echo fixture; }
docker_current_version() { echo fixture; }
docker_package() { echo docker-ce; }
time_sync_state() { echo fixture; }
now_time() { echo fixture; }
cert_exists() { return 1; }
congestion_state() { echo fixture; }
github_latest_tag() { echo "latest $1" >>"$calls"; echo v1.1.0; }

image_id() {
  if [[ -f $STATE_DIR/${1##*/}.tag ]]; then
    cat "$STATE_DIR/${1##*/}.tag"
  else
    printf 'sha256:%s-%s\n' "${1##*/}" default
  fi
}

docker() {
  case "$1" in
    compose) shift; [[ $entry == plugin ]] && mock_compose "$@" ;;
    pull)
      echo "pull $2" >>"$calls"
      [[ $2 != *:missing ]] && echo "sha256:${2##*/}-default" >"$STATE_DIR/${2##*/}.tag"
      ;;
    image)
      if [[ $2 == tag ]]; then
        echo "$3" >"$STATE_DIR/${4##*/}.tag"
      elif [[ $4 == '{{.Id}}' ]]; then
        image_id "$5"
      else
        echo "label $5" >>"$calls"
        case "$5" in
          *reader-next:latest-*|*reader-next:1.2.1-*) echo 1 ;;
          *) echo '<no value>' ;;
        esac
      fi
      ;;
    info) echo '["name=seccomp,profile=builtin"]' ;;
    ps)
      if [[ -f $STATE_DIR/webview.container ]]; then echo 'webview-id False'; fi
      ;;
    inspect)
      local format="" service ref id running health generation
      if [[ $2 == -f ]]; then format=$3; shift 2; fi
      case "$2" in
        reader-next|reader-id) service=reader ;;
        webview-id) service=webview ;;
        *) return 1 ;;
      esac
      [[ -f $STATE_DIR/$service.container ]] || return 1
      read -r ref id running health generation <"$STATE_DIR/$service.container"
      case "$format" in
        *com.docker.compose.project*) echo reader-next ;;
        *State.Health*) echo "$health" ;;
        *Image*State.Running*) echo "$ref $id $running" ;;
        '{{.Config.Image}} {{.Image}}') echo "$ref $id" ;;
        '{{.Config.Image}}') echo "$ref" ;;
        '{{.Image}}') echo "$id" ;;
        '{{.State.Running}}') echo "$running" ;;
        '{{.State.Status}}') echo "$health" ;;
        '') : ;;
        *) return 1 ;;
      esac
      ;;
    *) return 1 ;;
  esac
}

docker-compose() { mock_compose "$@"; }
mock_compose() {
  if [[ $1 == version ]]; then return 0; fi
  [[ $1 == -p && $2 == reader-next && $3 == -f ]] || return 1
  local file=$4 service ref id old_running health running generation=0 cli_path=$4
  shift 4
  service=${!#}
  case "$1" in
    config)
      if [[ -n $validator ]]; then
        if command -v cygpath >/dev/null; then cli_path=$(cygpath -aw "$file"); fi
        "$validator" -p reader-next -f "$cli_path" "$@" 2>>"$calls"
      else
        has '  reader:' "$file"
      fi
      ;;
    up)
      echo "compose $*" >>"$calls"
      [[ $* == "up -d --no-deps $service" || $* == "up --no-start --no-deps $service" ]] || return 1
      [[ $service == reader || $service == webview ]] || return 1
      ref=$(awk -v service="$service" '
        /^  [^ ]/ { selected = ($1 == service ":") }
        selected && /^    image:/ { print $2; exit }
      ' "$file")
      [[ -n $ref ]] || return 1
      id=$(image_id "$ref")
      running=true
      if [[ -f $STATE_DIR/$service.container ]]; then
        read -r _ _ old_running _ generation <"$STATE_DIR/$service.container"
        if [[ $* == *--no-start* ]]; then running=$old_running; fi
      elif [[ $* == *--no-start* ]]; then
        running=false
      fi
      health=running
      if [[ $service == webview ]]; then health=healthy; fi
      ((generation+=1))
      if [[ -f $STATE_DIR/fail-$service ]]; then
        read -r health_failure <"$STATE_DIR/fail-$service"
        rm "$STATE_DIR/fail-$service"
        if [[ $health_failure == startup ]]; then
          printf '%s %s false created %s\n' "$ref" "$id" "$generation" >"$STATE_DIR/$service.container"
          return 1
        fi
        health=unhealthy
      fi
      printf '%s %s %s %s %s\n' "$ref" "$id" "$running" "$health" "$generation" >"$STATE_DIR/$service.container"
      ;;
    ps)
      if [[ -f $STATE_DIR/$service.container ]]; then echo "$service-id"; fi
      ;;
    stop)
      echo "compose $*" >>"$calls"
      sed -i 's/ true [^ ]* / false exited /' "$STATE_DIR/$service.container"
      ;;
    rm)
      echo "compose $*" >>"$calls"
      [[ $* == "rm -f -s $service" ]] && rm -f "$STATE_DIR/$service.container"
      ;;
    *) return 1 ;;
  esac
}

run_ok() { menu <<<"$1" >"$STATE_DIR/menu.log" 2>&1 || { cat "$STATE_DIR/menu.log" >&2; fail "menu $1 failed"; }; }
run_fail() { if menu <<<"$1" >"$STATE_DIR/menu.log" 2>&1; then fail "menu $1 succeeded"; fi; }
install_reader() { READER_INSTALL_VERSION=$1; run_ok 1; }
install_webview() { run_ok $'11\nv1.0.0'; }
snapshot() { cp "$COMPOSE_FILE" "$STATE_DIR/before.yaml"; }
config_unchanged() { expect cmp -s "$COMPOSE_FILE" "$STATE_DIR/before.yaml"; }
data_intact() { expect has 'persistent Reader data' "$STATE_DIR/reader-data"; }

for entry in plugin standalone; do
  if [[ $entry == plugin ]]; then validator=${COMPOSE_V2:-}; else validator=${COMPOSE_V1:-}; fi

  for tag in latest 1.2.1; do
    reset "fresh-$tag"
    if [[ $tag == latest ]]; then run_ok 1; else install_reader "$tag"; fi
    expect has "$READER_IMAGE:$tag" "$COMPOSE_FILE"
    reject has '  webview:' "$COMPOSE_FILE"
    no_webview_actions
  done
  printf 'PASS %s AC-01 default and compatible fresh installs\n' "$entry"

  reset reader-only
  install_reader 1.2.0
  printf 'stale\n' >"$STATE_DIR/webview-version"
  clear_calls
  run_ok $'10\nv1.2.1'
  expect has "$READER_IMAGE:1.2.1" "$COMPOSE_FILE"
  expect has 'stale' "$STATE_DIR/webview-version"
  reject has '  webview:' "$COMPOSE_FILE"
  no_webview_actions

  reset legacy-combined
  install_reader 1.2.1
  install_webview
  if [[ $entry == standalone ]]; then printf 'version: "2.3"\n' >"$COMPOSE_FILE"; else : >"$COMPOSE_FILE"; fi
  sed 's/{{READER_VERSION}}/1.2.1/g; s/{{WEBVIEW_VERSION}}/1.0.0/g' "$repo/docker/docker-compose.webview.yaml" >>"$COMPOSE_FILE"
  cp "$STATE_DIR/webview.container" "$STATE_DIR/webview.expected"
  clear_calls
  run_ok $'10\n1.2.1'
  expect cmp -s "$STATE_DIR/webview.expected" "$STATE_DIR/webview.container"
  no_webview_actions
  sed -i 's/ true healthy / false exited /' "$STATE_DIR/webview.container"
  cp "$STATE_DIR/webview.container" "$STATE_DIR/webview.expected"
  snapshot
  for tag in 1.2.0 1.2.1; do
    clear_calls
    run_ok "$(printf '10\n%s' "$tag")"
    expect has "$READER_IMAGE:$tag" "$COMPOSE_FILE"
    expect cmp -s "$STATE_DIR/webview.expected" "$STATE_DIR/webview.container"
    diff -u <(sed '/^    image: .*reader-next:/d' "$STATE_DIR/before.yaml") \
      <(sed '/^    image: .*reader-next:/d' "$COMPOSE_FILE") || fail 'changed existing Compose settings'
    no_webview_actions
  done
  clear_calls
  run_ok 1
  expect cmp -s "$STATE_DIR/webview.expected" "$STATE_DIR/webview.container"
  no_webview_actions
  # The existing project stays intact even when its Reader container was removed.
  rm "$STATE_DIR/reader.container"
  clear_calls
  run_ok $'10\n1.2.0'
  expect has "$READER_IMAGE:1.2.0" "$COMPOSE_FILE"
  expect has "$WEBVIEW_IMAGE:1.0.0" "$COMPOSE_FILE"
  expect cmp -s "$STATE_DIR/webview.expected" "$STATE_DIR/webview.container"
  no_webview_actions
  printf 'PASS %s AC-02 Reader update, downgrade, reinstall and recovery with running or stopped legacy WebView\n' "$entry"

  reset webview-opt-in
  install_reader 1.2.1
  if [[ $entry == standalone ]]; then sed -i 's/^version: "2.3"/version: "3.3"/' "$COMPOSE_FILE"; fi
  sed -i '/^    logging:/i\    environment:\n    - KEEP_ME=value\n    - REMOTE_WEBVIEW_URL=old' "$COMPOSE_FILE"
  cp "$READER_ENV" "$STATE_DIR/reader.env.expected"
  echo sha256:reader-next:1.2.1-moved >"$STATE_DIR/reader-next:1.2.1.tag"
  clear_calls
  run_ok $'11\n\n'
  expect has 'latest 1432433gg/webview-next' "$calls"
  expect has 'REMOTE_WEBVIEW_URL=http://webview:8050' "$COMPOSE_FILE"
  expect has 'KEEP_ME=value' "$COMPOSE_FILE"
  reject has 'REMOTE_WEBVIEW_URL=old' "$COMPOSE_FILE"
  expect has '127.0.0.1:8080:8080' "$COMPOSE_FILE"
  expect has 'reader-data:/app/storage' "$COMPOSE_FILE"
  expect cmp -s "$READER_ENV" "$STATE_DIR/reader.env.expected"
  expect has "$READER_IMAGE:1.2.1 sha256:reader-next:1.2.1-default" "$STATE_DIR/reader.container"
  expect has "$WEBVIEW_IMAGE:1.1.0" "$STATE_DIR/webview.container"
  expect has '1.1.0' "$STATE_DIR/webview-version"
  [[ $(sed -n '/^  webview:/,/^  reader:/p' "$COMPOSE_FILE") != *ports:* ]] || fail 'WebView has a host port'
  data_intact
  run_ok $'10\n1.2.0'
  cp "$STATE_DIR/reader.container" "$STATE_DIR/reader.expected"
  clear_calls
  run_ok $'11\nv1.2.0'
  reject has 'latest ' "$calls"
  reject has 'compose up -d --no-deps reader' "$calls"
  expect cmp -s "$STATE_DIR/reader.expected" "$STATE_DIR/reader.container"
  expect has "$WEBVIEW_IMAGE:1.2.0" "$STATE_DIR/webview.container"
  expect has '1.2.0' "$STATE_DIR/webview-version"
  run_ok 7
  expect grep -Eq 'WebView：.*1\.2\.0' "$STATE_DIR/menu.log"

  reset first-explicit
  install_reader 1.2.1
  install_webview
  expect has "$WEBVIEW_IMAGE:1.0.0" "$STATE_DIR/webview.container"
  reject has 'latest ' "$calls"
  rm "$STATE_DIR/webview.container"
  run_ok $'11\n1.1.0'
  expect has "$WEBVIEW_IMAGE:1.1.0" "$STATE_DIR/webview.container"
  [[ $(grep -c '^  webview:' "$COMPOSE_FILE") == 1 ]] || fail 'duplicated the configured service'
  printf 'PASS %s AC-03 first install with Enter and explicit tags, private wiring, independent update and status\n' "$entry"

  reset guard-fresh
  fixture_mode=""
  run_ok 11
  expect has '请先通过菜单 1 或 2 完成安装' "$STATE_DIR/menu.log"
  no_webview_actions
  reset guard-ss
  fixture_mode=ss
  touch "$INFO_FILE"
  run_fail $'11\n1.0.0'
  no_webview_actions
  reject test -e "$COMPOSE_FILE"
  run_ok 7
  expect has 'Shadowsocks 2022' "$STATE_DIR/menu.log"
  reject has 'WebView：' "$STATE_DIR/menu.log"
  reset guard-reader
  install_reader 1.2.0
  snapshot
  run_fail $'11\n1.0.0'
  expect has '菜单 10' "$STATE_DIR/menu.log"
  config_unchanged
  no_webview_actions
  printf 'PASS %s AC-04 fresh host, Shadowsocks, incompatible Reader guards\n' "$entry"

  reset first-failure
  install_reader 1.2.1
  snapshot
  cp "$STATE_DIR/reader.container" "$STATE_DIR/reader.expected"
  printf 'stale\n' >"$STATE_DIR/webview-version"
  run_fail $'11\ninvalid:tag'
  config_unchanged
  run_fail $'11\nmissing'
  config_unchanged
  for failure in startup unhealthy; do
    echo "$failure" >"$STATE_DIR/fail-webview"
    run_fail $'11\n1.0.0'
    config_unchanged
    expect cmp -s "$STATE_DIR/reader.expected" "$STATE_DIR/reader.container"
    reject test -e "$STATE_DIR/webview.container"
    reject test -e "$STATE_DIR/webview-seccomp.json"
    expect has 'stale' "$STATE_DIR/webview-version"
  done
  echo startup >"$STATE_DIR/fail-reader"
  clear_calls
  run_fail $'11\n1.0.0'
  config_unchanged
  expect has "$READER_IMAGE:1.2.1 sha256:reader-next:1.2.1-default true running 3" "$STATE_DIR/reader.container"
  reject test -e "$STATE_DIR/webview.container"
  expect has 'stale' "$STATE_DIR/webview-version"
  data_intact
  install_webview
  snapshot
  for running in true false; do
    if [[ $running == false ]]; then sed -i 's/ true healthy / false exited /' "$STATE_DIR/webview.container"; fi
    clear_calls
    echo unhealthy >"$STATE_DIR/fail-webview"
    run_fail $'11\n1.1.0'
    config_unchanged
    expect has "$WEBVIEW_IMAGE:1.0.0 sha256:webview-next:1.0.0-default $running" "$STATE_DIR/webview.container"
    expect has '1.0.0' "$STATE_DIR/webview-version"
    reject has 'compose up -d --no-deps reader' "$calls"
  done
  data_intact
  printf 'PASS %s AC-05 invalid/missing tag, first-install startup and health failures, Reader rollback, running and stopped WebView rollback\n' "$entry"

  reset config-validation
  install_reader 1.2.1
  install_webview
  expect cmp -s "$repo/docker/webview-seccomp.json" "$STATE_DIR/webview-seccomp.json"
  expect has '安装 / 更新 / 指定版本 WebView' "$repo/install.sh"
  expect has 'WebView is opt-in' "$repo/README.md"
  printf 'PASS %s AC-06 Compose configuration validated by %s\n' "$entry" "${validator:-fixture}"
done
