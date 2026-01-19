#!/bin/sh
set -eu

SRC="${SRC:-/upd}"
DST="${DST:-/gmodserv/garrysmod}"

STATE_DIR="${STATE_DIR:-/tmp/garrysmod}"
BAK_DIR="$STATE_DIR/bak"
MANAGED_LIST="$STATE_DIR/managed.list"
CHECKSUMS="$STATE_DIR/checksums.txt"

IGNORE_FILE="${IGNORE_FILE:-$SRC/.dockerignore}"
INCLUDE_PREFIXES="${INCLUDE_PREFIXES:-}"

POLL_INTERVAL="${POLL_INTERVAL:-2}"

GREEN="$(printf '\033[32m')"
ORANGE="$(printf '\033[33m')"
CYAN="$(printf '\033[36m')"
RESET="$(printf '\033[0m')"

msg_new() { printf '%s[Hotload] new file uploaded: %s%s\n' "$GREEN" "$1" "$RESET" >&2; }
msg_old() { printf '%s[Hotload] old file loaded from backup: %s%s\n' "$ORANGE" "$1" "$RESET" >&2; }
msg_rep() { printf '%s[Hotload] replaced original file: %s%s\n' "$CYAN" "$1" "$RESET" >&2; }
msg_del() { printf '%s[Hotload] file deleted: %s%s\n' "$ORANGE" "$1" "$RESET" >&2; }

mkdir -p "$STATE_DIR" "$BAK_DIR"
touch "$MANAGED_LIST" "$CHECKSUMS"

ensure_dir() {
  d="$1"
  [ -d "$d" ] || mkdir -p "$d"
}

relpath() {
  p="$1"
  printf '%s' "$p" | sed "s#^$SRC/##"
}

is_included() {
  r="$1"
  [ -z "$INCLUDE_PREFIXES" ] && return 0
  rr="$(printf '%s' "$r" | sed 's#^./##; s#//*#/#g; s#^/##')"
  for p in $INCLUDE_PREFIXES; do
    p="$(printf '%s' "$p" | sed 's#^./##; s#/*$##')"
    case "$rr" in
      "$p"|"${p}/"*) return 0 ;;
    esac
  done
  return 1
}

is_ignored_by_dockerignore() {
  r="$1"
  [ -f "$IGNORE_FILE" ] || return 1
  rr="$(printf '%s' "$r" | sed 's#^./##; s#//*#/#g; s#^/##')"
  while IFS= read -r pat || [ -n "$pat" ]; do
    pat="$(printf '%s' "$pat" | sed 's/[[:space:]]*$//')"
    [ -z "$pat" ] && continue
    case "$pat" in \#*) continue ;; esac
    case "$pat" in !*) continue ;; esac
    pat="$(printf '%s' "$pat" | sed 's#^./##; s#//*#/#g')"
    case "$pat" in */) pat="${pat}*" ;; esac
    case "$rr" in
      $pat) return 0 ;;
    esac
  done < "$IGNORE_FILE"
  return 1
}

should_sync() {
  r="$1"
  is_included "$r" || return 1
  is_ignored_by_dockerignore "$r" && return 1
  return 0
}

is_managed() {
  r="$1"
  grep -Fqx "$r" "$MANAGED_LIST"
}

mark_managed() {
  r="$1"
  if ! is_managed "$r"; then
    printf '%s\n' "$r" >> "$MANAGED_LIST"
  fi
}

unmark_managed() {
  r="$1"
  tmp="$STATE_DIR/managed.list.unmark.$$"
  : > "$tmp"
  grep -Fvx "$r" "$MANAGED_LIST" > "$tmp" 2>/dev/null || true
  mv -f "$tmp" "$MANAGED_LIST"
}

bak_orig_path() {
  r="$1"
  printf '%s/%s.orig' "$BAK_DIR" "$r"
}

get_file_checksum() {
  f="$1"
  [ -f "$f" ] || return 1
  md5sum "$f" 2>/dev/null | awk '{print $1}'
}

backup_original_if_needed() {
  r="$1"
  dstf="$DST/$r"
  bakf="$(bak_orig_path "$r")"
  if is_managed "$r"; then
    return 1
  fi
  if [ -f "$dstf" ] && [ ! -f "$bakf" ]; then
    ensure_dir "$(dirname "$bakf")"
    cp -p "$dstf" "$bakf"
    return 0
  fi
  return 1
}

deploy_file() {
  srcf="$1"
  r="$(relpath "$srcf")"
  should_sync "$r" || return 0

  dstf="$DST/$r"
  ensure_dir "$(dirname "$dstf")"

  if [ -f "$dstf" ]; then
    if backup_original_if_needed "$r"; then
      cp -p "$srcf" "$dstf"
      mark_managed "$r"
      msg_rep "$r"
      return 0
    fi
    if [ -f "$dstf" ] && cmp -s "$srcf" "$dstf"; then
      return 0
    fi
    cp -p "$srcf" "$dstf"
    mark_managed "$r"
    msg_new "$r"
    return 0
  fi

  cp -p "$srcf" "$dstf"
  mark_managed "$r"
  msg_new "$r"
}

deploy_dir() {
  srcd="$1"
  r="$(relpath "$srcd")"
  should_sync "$r" || return 0
  ensure_dir "$DST/$r"
}

handle_delete_file() {
  r="$1"
  should_sync "$r" || return 0

  dstf="$DST/$r"
  bakf="$(bak_orig_path "$r")"

  if [ -f "$bakf" ]; then
    ensure_dir "$(dirname "$dstf")"
    cp -p "$bakf" "$dstf"
    unmark_managed "$r"
    msg_old "$r"
    return 0
  fi

  if is_managed "$r"; then
    rm -f "$dstf" 2>/dev/null || true
    unmark_managed "$r"
    msg_del "$r"
  fi
}

initial_sync() {
  find "$SRC" -type d -print | while IFS= read -r d; do
    [ "$d" = "$SRC" ] && continue
    deploy_dir "$d"
  done
find "$SRC" -type f -print | while IFS= read -r f; do
    deploy_file "$f"
  done

  update_checksums
}

update_checksums() {
  tmp="$STATE_DIR/checksums.tmp.$$"
  : > "$tmp"
  
  find "$SRC" -type f -print | while IFS= read -r f; do
    r="$(relpath "$f")"
    should_sync "$r" || continue
    checksum="$(get_file_checksum "$f" || echo "DELETED")"
    printf '%s %s\n' "$checksum" "$r" >> "$tmp"
  done
  
  mv -f "$tmp" "$CHECKSUMS"
}

poll_loop() {
  echo "[Hotload] Starting polling mode (interval: ${POLL_INTERVAL}s)..." >&2
  
  while true; do
    sleep "$POLL_INTERVAL"

    tmp_new="$STATE_DIR/checksums.new.$$"
    : > "$tmp_new"
    
    find "$SRC" -type f -print | while IFS= read -r f; do
      r="$(relpath "$f")"
      should_sync "$r" || continue
      checksum="$(get_file_checksum "$f" || echo "DELETED")"
      printf '%s %s\n' "$checksum" "$r" >> "$tmp_new"
    done

    while IFS=' ' read -r old_sum old_file || [ -n "$old_file" ]; do
      new_sum="$(grep " $old_file$" "$tmp_new" 2>/dev/null | awk '{print $1}')"
      
      if [ -z "$new_sum" ]; then
        handle_delete_file "$old_file"
      elif [ "$old_sum" != "$new_sum" ]; then
        deploy_file "$SRC/$old_file"
      fi
    done < "$CHECKSUMS"

    while IFS=' ' read -r new_sum new_file || [ -n "$new_file" ]; do
      if ! grep -q " $new_file$" "$CHECKSUMS" 2>/dev/null; then
        deploy_file "$SRC/$new_file"
      fi
    done < "$tmp_new"

    mv -f "$tmp_new" "$CHECKSUMS"
  done
}

[ -d "$SRC" ] || exit 1
ensure_dir "$DST"

initial_sync
poll_loop
