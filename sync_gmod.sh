#!/bin/sh
set -eu

SRC="${SRC:-/upd}"
DST="${DST:-/gmodserv/garrysmod}"

STATE_DIR="${STATE_DIR:-/tmp/garrysmod}"
BAK_DIR="$STATE_DIR/bak"
MANAGED_LIST="$STATE_DIR/managed.list"

IGNORE_FILE="${IGNORE_FILE:-$SRC/.dockerignore}"
INCLUDE_PREFIXES="${INCLUDE_PREFIXES:-}"

GREEN='\033[32m'
ORANGE='\033[33m'
CYAN='\033[36m'
RESET='\033[0m'

msg_new() { printf "${GREEN}[Hotload] new file uploaded: %s${RESET}\n" "$1" >&2; }
msg_old() { printf "${ORANGE}[Hotload] old file loaded from backup: %s${RESET}\n" "$1" >&2; }
msg_rep() { printf "${CYAN}[Hotload] replaced original file: %s${RESET}\n" "$1" >&2; }

mkdir -p "$STATE_DIR" "$BAK_DIR"
touch "$MANAGED_LIST"

ensure_dir() {
  [ -d "$1" ] || mkdir -p "$1"
}

relpath() {
  printf '%s' "${1#$SRC/}"
}

is_included() {
  [ -z "$INCLUDE_PREFIXES" ] && return 0
  local rr="${1#./}"
  rr="${rr#/}"
  rr="${rr//\/\//\/}"
  
  for p in $INCLUDE_PREFIXES; do
    p="${p#./}"
    p="${p%/}"
    case "$rr" in
      "$p"|"${p}/"*) return 0 ;;
    esac
  done
  return 1
}

is_ignored_by_dockerignore() {
  [ -f "$IGNORE_FILE" ] || return 1
  local rr="${1#./}"
  rr="${rr#/}"
  rr="${rr//\/\//\/}"
  
  while IFS= read -r pat || [ -n "$pat" ]; do
    pat="${pat%"${pat##*[![:space:]]}"}"
    [ -z "$pat" ] && continue
    case "$pat" in \#*|!*) continue ;; esac
    
    pat="${pat#./}"
    pat="${pat//\/\//\/}"
    case "$pat" in */) pat="${pat}*" ;; esac
    
    case "$rr" in $pat) return 0 ;; esac
  done < "$IGNORE_FILE"
  return 1
}

should_sync() {
  is_included "$1" || return 1
  is_ignored_by_dockerignore "$1" && return 1
  return 0
}

is_managed() {
  awk -v r="$1" '$0 == r {exit 0} END {exit 1}' "$MANAGED_LIST"
}

mark_managed() {
  is_managed "$1" || printf '%s\n' "$1" >> "$MANAGED_LIST"
}

unmark_managed() {
  local tmp="$STATE_DIR/managed.list.$$"
  awk -v r="$1" '$0 != r' "$MANAGED_LIST" > "$tmp" 2>/dev/null || : > "$tmp"
  mv -f "$tmp" "$MANAGED_LIST"
}

bak_orig_path() {
  printf '%s/%s.orig' "$BAK_DIR" "$1"
}

backup_original_if_needed() {
  local dstf="$DST/$1"
  local bakf="$(bak_orig_path "$1")"
  
  is_managed "$1" && return 1
  
  if [ -f "$dstf" ] && [ ! -f "$bakf" ]; then
    ensure_dir "$(dirname "$bakf")"
    cp -p "$dstf" "$bakf"
    return 0
  fi
  return 1
}

deploy_file() {
  local r="$(relpath "$1")"
  should_sync "$r" || return 0

  local dstf="$DST/$r"
  ensure_dir "$(dirname "$dstf")"

  if [ -f "$dstf" ]; then
    if backup_original_if_needed "$r"; then
      cp -p "$1" "$dstf"
      mark_managed "$r"
      msg_rep "$r"
      return 0
    fi
    
    cmp -s "$1" "$dstf" && return 0
    
    cp -p "$1" "$dstf"
    mark_managed "$r"
    msg_new "$r"
    return 0
  fi

  cp -p "$1" "$dstf"
  mark_managed "$r"
  msg_new "$r"
}

deploy_dir() {
  local r="$(relpath "$1")"
  should_sync "$r" || return 0
  ensure_dir "$DST/$r"
}

handle_delete_file() {
  should_sync "$1" || return 0

  local dstf="$DST/$1"
  local bakf="$(bak_orig_path "$1")"

  if [ -f "$bakf" ]; then
    ensure_dir "$(dirname "$dstf")"
    cp -p "$bakf" "$dstf"
    unmark_managed "$1"
    msg_old "$1"
    return 0
  fi

  if is_managed "$1"; then
    rm -f "$dstf" 2>/dev/null || true
    unmark_managed "$1"
  fi
}

handle_delete_dir() {
  local prefix="${1#./}"
  prefix="${prefix//\/\//\/}"
  prefix="${prefix%/}"
  
  should_sync "$prefix" || return 0

  local tmp="$STATE_DIR/managed.list.$$"
  awk -v prefix="$prefix/" '
    index($0, prefix) == 1 {next}
    {print}
  ' "$MANAGED_LIST" > "$tmp"

  awk -v prefix="$prefix/" 'index($0, prefix) == 1 {print}' "$MANAGED_LIST" | \
    while IFS= read -r r; do
      handle_delete_file "$r"
    done
  
  mv -f "$tmp" "$MANAGED_LIST"
  [ -d "$DST/$prefix" ] && rmdir "$DST/$prefix" 2>/dev/null || true
}

initial_sync() {
  find "$SRC" -type d ! -path "$SRC" -exec sh -c '
    for d; do
      r="${d#'"$SRC"'/}"
      if ./should_sync "$r"; then
        ensure_dir "'"$DST"'/$r"
      fi
    done
  ' sh {} +

  find "$SRC" -type f -exec sh -c '
    for f; do
      deploy_file "$f"
    done
  ' sh {} +
}

watch_loop() {
  inotifywait -m -r \
    -e create -e modify -e delete -e moved_to -e moved_from -e attrib \
    --format '%e|%w%f' \
    "$SRC" | while IFS='|' read -r ev full; do

    [ "$full" = "$SRC" ] && continue
    local r="$(relpath "$full")"
    should_sync "$r" || continue

    case "$ev" in
      *CREATE*|*MOVED_TO*|*ATTRIB*|*MODIFY*)
        if [ -d "$full" ]; then
          deploy_dir "$full"
        elif [ -f "$full" ]; then
          deploy_file "$full"
        fi
        ;;
      *DELETE*|*MOVED_FROM*)
        if grep -qF "$r/" "$MANAGED_LIST" 2>/dev/null; then
          handle_delete_dir "$r"
        else
          handle_delete_file "$r"
        fi
        ;;
    esac
  done
}

[ -d "$SRC" ] || exit 1
ensure_dir "$DST"

initial_sync
watch_loop