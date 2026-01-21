#!/bin/bash
set -e

./sync_gmod.sh &

VERSION_URL="${GMOD_VERSION_URL:-https://raw.githubusercontent.com/FoerMaster/gserver-docker-source/refs/heads/main/version}"
VERSION_FILE="${GMOD_VERSION_FILE:-./version}"
VERSION_POLL_INTERVAL="${GMOD_VERSION_POLL_INTERVAL:-${GMOD_VERSION_CHECK_INTERVAL:-300}}"
VERSION_CHECK_ATTEMPTS="${GMOD_VERSION_CHECK_ATTEMPTS:-3}"
VERSION_RETRY_INTERVAL="${GMOD_VERSION_RETRY_INTERVAL:-2}"
VERSION_BRANCH="${GMOD_VERSION_BRANCH:-}"

GREEN="$(printf '\033[32m')"
RED="$(printf '\033[31m')"
YELLOW="$(printf '\033[33m')"
RESET="$(printf '\033[0m')"

print_box() {
  local color="$1"
  shift
  local lines=("$@")
  local max=0
  local line
  for line in "${lines[@]}"; do
    [ "${#line}" -gt "$max" ] && max="${#line}"
  done
  local border
  border="$(printf '%*s' "$max" '' | tr ' ' '-')"
  printf '%b+-%s-+%b\n' "$color" "$border" "$RESET"
  for line in "${lines[@]}"; do
    local pad=$((max - ${#line}))
    printf '%b| %s%*s |%b\n' "$color" "$line" "$pad" "" "$RESET"
  done
  printf '%b+-%s-+%b\n' "$color" "$border" "$RESET"
}

branch_from_url() {
  local url="$1"
  local branch=""
  case "$url" in
    *"/refs/heads/"*)
      branch="${url#*/refs/heads/}"
      branch="${branch%%/*}"
      ;;
  esac
  printf '%s' "$branch"
}

read_version_line() {
  local file="$1"
  [ -f "$file" ] || return 0
  head -n 1 "$file" | tr -d '\r'
}

fetch_remote_version_line() {
  curl -fsSL "$VERSION_URL" 2>/dev/null | head -n 1 | tr -d '\r' || true
}

load_local_version() {
  local local_line
  local_line="$(read_version_line "$VERSION_FILE")"
  [ -n "$local_line" ] || return 1
  LOCAL_BUILD=""
  LOCAL_BRANCH=""
  IFS=' ' read -r LOCAL_BUILD LOCAL_BRANCH _ <<<"$local_line"
  [ -n "$LOCAL_BUILD" ] || return 1
  return 0
}

fetch_remote_version() {
  local remote_line attempt
  REMOTE_BUILD=""
  REMOTE_BRANCH=""
  attempt=1
  while [ "$attempt" -le "$VERSION_CHECK_ATTEMPTS" ]; do
    remote_line="$(fetch_remote_version_line)"
    if [ -n "$remote_line" ]; then
      IFS=' ' read -r REMOTE_BUILD REMOTE_BRANCH _ <<<"$remote_line"
      [ -n "$REMOTE_BUILD" ] && return 0
    fi
    attempt=$((attempt + 1))
    if [ "$attempt" -le "$VERSION_CHECK_ATTEMPTS" ]; then
      sleep "$VERSION_RETRY_INTERVAL"
    fi
  done
  return 1
}

resolve_branch() {
  local branch
  branch="$LOCAL_BRANCH"
  [ -n "$branch" ] || branch="$REMOTE_BRANCH"
  [ -n "$branch" ] || branch="$VERSION_BRANCH"
  [ -n "$branch" ] || branch="$(branch_from_url "$VERSION_URL")"
  [ -n "$branch" ] || branch="main"
  printf '%s' "$branch"
}

print_latest_box() {
  local branch
  branch="$(resolve_branch)"
  print_box "$GREEN" "You are using the latest server version (build $LOCAL_BUILD, branch $branch)."
}

print_update_box() {
  local branch
  branch="$(resolve_branch)"
  print_box "$RED" \
    "A newer server version is available (latest build $REMOTE_BUILD, branch $branch)." \
    "Please update your Docker image to the latest version:" \
    "docker compose pull && docker compose up"
}

print_error_box() {
  print_box "$YELLOW" \
    "Unable to check the latest server version right now." \
    "Please verify network access or the version URL:" \
    "$VERSION_URL"
}

version_check_startup() {
  if ! load_local_version; then
    return 0
  fi
  if fetch_remote_version; then
    if [ "$LOCAL_BUILD" = "$REMOTE_BUILD" ]; then
      print_latest_box
    else
      print_update_box
    fi
  else
    print_error_box
  fi
}

version_monitor_loop() {
  while true; do
    sleep "$VERSION_POLL_INTERVAL"
    if ! load_local_version; then
      continue
    fi
    if fetch_remote_version; then
      if [ "$LOCAL_BUILD" != "$REMOTE_BUILD" ]; then
        print_update_box
      fi
    else
      print_error_box
    fi
  done
}

PORT=${GMOD_PORT:-27015}
TICKRATE=${GMOD_TICKRATE:-32}
MAXPLAYERS=${GMOD_MAXPLAYERS:-16}
MAP=${GMOD_MAP:-gm_construct}
GAMEMODE=${GMOD_GAMEMODE:-sandbox}

ARGS=()

ARGS+=("-port" "$PORT")
ARGS+=("-tickrate" "$TICKRATE")
ARGS+=("-maxplayers" "$MAXPLAYERS")

if [ "$GMOD_INSECURE" = "true" ]; then
    ARGS+=("-insecure")
fi

if [ -n "$GAMEMODE" ]; then
    ARGS+=("+gamemode" "$GAMEMODE")
fi

ARGS+=("+map" "$MAP")

version_check_startup
version_monitor_loop &

exec ./srcds_run \
  -game garrysmod \
  -console \
  -norestart \
  -strictportbind \
  "${ARGS[@]}" \
  "$@"
