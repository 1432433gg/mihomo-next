#!/usr/bin/env bash
set -euo pipefail

repo=$(cd "$(dirname "$0")/.." && pwd)
baseline=37270e5cccacca8857ac4908cecfb800677a5db1
scratch=$(mktemp -d)
trap 'rm -rf -- "$scratch"' EXIT
export SELF_UPDATE_INSTALLER="$scratch/install.sh"
export SELF_UPDATE_DOWNLOAD="$repo/install.sh"
export SELF_UPDATE_TRACE="$scratch/trace"
export SELF_UPDATE_URL="https://raw.githubusercontent.com/1432433gg/mihomo-next/main/install.sh"

git -C "$repo" show "$baseline:install.sh" >"$SELF_UPDATE_INSTALLER"
grep -Fx 'SCRIPT_VERSION="1.1.0"' "$SELF_UPDATE_INSTALLER"
grep -Fx 'SCRIPT_VERSION="1.1.1"' "$SELF_UPDATE_DOWNLOAD"
[[ ! -e $scratch/.git ]]

cat >"$scratch/host-fixture.sh" <<'FIXTURE'
if [[ $0 == "$SELF_UPDATE_INSTALLER" ]]; then
  # Substitute host checks once the standalone script has defined them.
  # This also runs on the real self-update exec of the replacement file.
  configure_fixture_host() {
    [[ $1 == 'menu "$@"' ]] || return 0
    trap - DEBUG
    is_root() { :; }
    detect_system() { OS_ID=debian; }
    printf 'launch %s\n' "$SCRIPT_VERSION" >>"$SELF_UPDATE_TRACE"
  }
  trap 'configure_fixture_host "$BASH_COMMAND"' DEBUG

  wget() {
    [[ $# == 6 && $4 == -O && $6 == "$SELF_UPDATE_URL" ]] || return 1
    printf 'download %s\n' "$6" >>"$SELF_UPDATE_TRACE"
    command cp -- "$SELF_UPDATE_DOWNLOAD" "$5"
  }

  mv() {
    [[ $# == 3 && $1 == -f && $3 == "$SELF_UPDATE_INSTALLER" ]] || return 1
    printf 'replace %s\n' "$3" >>"$SELF_UPDATE_TRACE"
    command mv "$@"
  }
fi
FIXTURE

cd "$scratch"

run_upgrade() {
  local input=$1 output=$2
  if ! BASH_ENV="$scratch/host-fixture.sh" bash "$SELF_UPDATE_INSTALLER" <<<"$input" >"$output" 2>&1; then
    cat "$output" >&2
    return 1
  fi
}

run_upgrade $'3\n0' upgrade.log
cmp "$SELF_UPDATE_INSTALLER" "$SELF_UPDATE_DOWNLOAD"
grep -F '已从 1.1.0 升级到 1.1.1' upgrade.log
grep -F '[1.1.1]' upgrade.log
printf 'launch 1.1.0\ndownload %s\nreplace %s\nlaunch 1.1.1\n' \
  "$SELF_UPDATE_URL" "$SELF_UPDATE_INSTALLER" >expected
diff -u expected "$SELF_UPDATE_TRACE"

: >"$SELF_UPDATE_TRACE"
run_upgrade 3 current.log
cmp "$SELF_UPDATE_INSTALLER" "$SELF_UPDATE_DOWNLOAD"
grep -F '[1.1.1]' current.log
grep -F '已是最新版本 1.1.1' current.log
printf 'launch 1.1.1\ndownload %s\n' "$SELF_UPDATE_URL" >expected
diff -u expected "$SELF_UPDATE_TRACE"

printf 'Requested URL: %s\n' "$SELF_UPDATE_URL"
sha256sum "$SELF_UPDATE_INSTALLER" "$SELF_UPDATE_DOWNLOAD"
printf 'PASS AC-08 exact standalone upgrade, relaunch, and same-version no replacement\n'
