#!/usr/bin/env bash
# lm-studio — launch immediately; update in the background
# - Launches LM Studio right away.
# - Background worker resolves latest, downloads if newer (resumable), swaps symlink,
#   notifies at START and END of download, then prompts to restart.
#   On “Yes”, it CLEANLY CLOSES the old LM Studio and starts the new one.
# - --wait-update: do the update first, then launch (foreground).
# - Keeps at most KEEP_N AppImages.

set -euo pipefail

# === Settings ===============================================================
APPDIR="${APPDIR:-$HOME/.apps/lm-studio}"
SYMLINK="$APPDIR/LM-Studio-latest.AppImage"
URL_CACHE="$APPDIR/source.url"
RESOLVED_CACHE="$APPDIR/resolved.url"
RESOLVED_TS="$APPDIR/resolved.ts"
LOCKFILE="$APPDIR/update.lock"
KEEP_N="${KEEP_N:-4}"
TTL_SEC="${TTL_SEC:-21600}"   # 6h

CURL_BIN="${CURL_BIN:-curl}"
CURL_BASE=(env -u http_proxy -u https_proxy -u ALL_PROXY -u all_proxy -u no_proxy \
           "$CURL_BIN" -q -4 --http1.1 --alt-svc "")

LMSTUDIO_VERBOSE="${LMSTUDIO_VERBOSE:-1}"
[[ "${LMSTUDIO_DEBUG:-0}" = "1" ]] && { set -x; PS4='+ $(date -Is) '; }

mkdir -p "$APPDIR"
SELF="$(readlink -f "$0")"

# === Utils ==================================================================
msg(){ [[ "$LMSTUDIO_VERBOSE" = "1" ]] && printf "[lmstudio] %s\n" "$*" >&2; }
note(){  # quiet notifications
  local title="${1:-}" body="${2:-}"
  if command -v notify-send >/dev/null 2>&1 && { [[ -n "${DISPLAY:-}" ]] || [[ -n "${WAYLAND_DISPLAY:-}" ]]; }; then
    notify-send -a "LM Studio Updater" "$title" "${body:-}" >/dev/null 2>&1 || true
  else
    msg "$title${body:+ — $body}"
  fi
}
have(){ command -v "$1" >/dev/null 2>&1; }

best_current(){
  local cur=""
  if [[ -L "$SYMLINK" ]]; then cur="$(readlink -f "$SYMLINK" 2>/dev/null || true)"; fi
  if [[ -z "$cur" || ! -f "$cur" ]]; then
    cur="$(ls -1t "$APPDIR"/LM-Studio-*.AppImage 2>/dev/null | head -n1 || true)"
  fi
  printf '%s' "${cur:-}"
}

cache_valid(){
  [[ "$TTL_SEC" -gt 0 && -f "$RESOLVED_CACHE" && -f "$RESOLVED_TS" ]] || return 1
  local now ts url file
  now=$(date +%s); ts=$(cat "$RESOLVED_TS" 2>/dev/null || echo 0)
  (( now - ts < TTL_SEC )) || return 1
  url="$(<"$RESOLVED_CACHE" 2>/dev/null || true)"; [[ -n "$url" ]] || return 1
  file="${url##*/}"; [[ -f "$APPDIR/$file" ]] || return 1
  printf '%s' "$url"
}

resolve_latest_url(){
  local seed loc url code resolved
  url="$(cache_valid || true)"
  if [[ -n "$url" ]]; then printf '%s' "$url"; return 0; fi
  if [[ -f "$URL_CACHE" ]]; then seed="$(head -n1 "$URL_CACHE" | tr -d $'\r\n')"
  else seed="https://lmstudio.ai/download/latest/linux/x64"; printf '%s\n' "$seed" >"$URL_CACHE"; fi

  loc="$("${CURL_BASE[@]}" -I -sS --connect-timeout 2 -m 5 "$seed" 2>/dev/null \
        | awk -F': ' 'tolower($1)=="location"{print $2}' | tr -d '\r')"
  if [[ "$loc" == https://installers.lmstudio.ai/linux/x64/*.AppImage ]]; then
    url="$loc"
  else
    resolved="$("${CURL_BASE[@]}" -L -s -o /dev/null --connect-timeout 3 -m 10 -w '%{url_effective}' "$seed" 2>/dev/null || true)"
    url="${resolved:-}"
  fi
  [[ "$url" == https://installers.lmstudio.ai/linux/x64/*.AppImage ]] || return 1

  code="$("${CURL_BASE[@]}" -sS -o /dev/null -w '%{http_code}' -I "$url" || true)"
  [[ "$code" == "200" || "$code" == "302" ]] || return 1

  printf '%s' "$url" >"$RESOLVED_CACHE"; date +%s >"$RESOLVED_TS"
  printf '%s' "$url"
}

download_file(){  # $1 url $2 out
  local url="$1" out="$2"
  "${CURL_BASE[@]}" -sS -fL --retry 3 --connect-timeout 10 -C - -o "$out.part" "$url"
  mv -f "$out.part" "$out"
  chmod +x "$out"
}

download_and_link(){
  local url="$1" headers etag lmod file target code
  code="$("${CURL_BASE[@]}" -sS -o /dev/null -w '%{http_code}' -I "$url" || true)"
  if [[ "$code" != "200" && "$code" != "302" && -f "$RESOLVED_CACHE" ]]; then
    rm -f "$RESOLVED_CACHE" "$RESOLVED_TS"
    url="$(resolve_latest_url)" || return 1
  fi

  headers="$("${CURL_BASE[@]}" -m 20 -fsSI "$url" 2>/dev/null || true)"
  etag="$(printf '%s' "$headers" | awk -F': ' 'tolower($1)=="etag"{print $2}' | tr -d '\r')"
  lmod="$(printf '%s' "$headers" | awk -F': ' 'tolower($1)=="last-modified"{print $2}' | tr -d '\r')"

  file="${url##*/}"; target="$APPDIR/$file"
  trap 'rm -f "$target.part" 2>/dev/null || true' INT TERM

  if [[ -f "$target" ]]; then
    if [[ -n "$etag" && -f "$APPDIR/.remote.etag" && "$etag" == "$(cat "$APPDIR/.remote.etag")" ]] ||
       [[ -n "$lmod" && -f "$APPDIR/.remote.lastmod" && "$lmod" == "$(cat "$APPDIR/.remote.lastmod")" ]] ||
       [[ -z "$etag" && -z "$lmod" ]]; then
      : # already have file
    else
      download_file "$url" "$target"
      [[ -n "$etag" ]] && printf '%s' "$etag" >"$APPDIR/.remote.etag" || true
      [[ -n "$lmod" ]] && printf '%s' "$lmod" >"$APPDIR/.remote.lastmod" || true
    fi
  else
    download_file "$url" "$target"
    [[ -n "$etag" ]] && printf '%s' "$etag" >"$APPDIR/.remote.etag" || true
    [[ -n "$lmod" ]] && printf '%s' "$lmod" >"$APPDIR/.remote.lastmod" || true
  fi

  ln -sfn "$target" "$SYMLINK"
}

prune_old(){
  shopt -s nullglob
  local files=()
  mapfile -t files < <(ls -1t "$APPDIR"/LM-Studio-*.AppImage 2>/dev/null || true)
  if (( ${#files[@]} > KEEP_N )); then
    local f
    for f in "${files[@]:$KEEP_N}"; do
      [[ "$(readlink -f "$f")" == "$(readlink -f "$SYMLINK")" ]] && continue
      rm -f -- "$f" && msg "Pruned $f"
    done
  fi
}

# --- Restart logic: close old LM Studio cleanly, then launch new -------------
find_lmstudio_main_pids(){ # prints PIDs of main LM Studio processes (AppImage entry)
  ps -eo pid=,cmd= \
    | grep -E '[L]M-Studio-.*\.AppImage|LM-Studio-latest\.AppImage' \
    | grep -v -- '--type=' \
    | awk '{print $1}' \
    | tr -d '\r'
}

kill_lmstudio_graceful(){ # TERM then KILL if needed
  local pids=("$@")
  ((${#pids[@]})) || return 0
  kill -TERM "${pids[@]}" 2>/dev/null || true
  local end=$((SECONDS+8))
  while (( SECONDS < end )); do
    sleep 0.3
    local alive=0
    for p in "${pids[@]}"; do
      if kill -0 "$p" 2>/dev/null; then alive=1; fi
    done
    (( alive==0 )) && return 0
  done
  kill -KILL "${pids[@]}" 2>/dev/null || true
}

prompt_restart(){  # ask, then close old and open new if confirmed
  local file="$1"
  if command -v kdialog >/dev/null 2>&1 && { [[ -n "${DISPLAY:-}" ]] || [[ -n "${WAYLAND_DISPLAY:-}" ]]; }; then
    if kdialog --yesno "LM Studio update downloaded:\n\n$file\n\nRestart LM Studio now?"; then
      mapfile -t pids < <(find_lmstudio_main_pids || true)
      kill_lmstudio_graceful "${pids[@]}" || true
      ( "$SYMLINK" >/dev/null 2>&1 & disown ) || true
    fi
  else
    note "LM Studio updated" "$file — close the app and open it again to use the new version."
  fi
}


# === Background worker ======================================================
background_check_and_update(){
  set -euo pipefail

  if command -v flock >/dev/null 2>&1; then
    exec {lf}>"$LOCKFILE" 2>/dev/null || true
    if ! flock -n "$lf" 2>/dev/null; then exit 0; fi
  fi

  local current current_file latest_url latest_file
  current="$(best_current)"; current_file="$(basename "${current:-}" 2>/dev/null || true)"
  latest_url="$(resolve_latest_url || true)" || exit 0
  [[ -n "$latest_url" ]] || exit 0
  latest_file="${latest_url##*/}"

  if [[ -n "$current_file" && "$current_file" == "$latest_file" ]]; then
    # No update needed; already have the latest AppImage
    exit 0
  fi

  note "Downloading LM Studio update…" "$latest_file"
  if download_and_link "$latest_url"; then
    prune_old
    note "LM Studio update ready" "$latest_file"
    prompt_restart "$latest_file"
  fi
  exit 0
}

# === Subcommands (handled first) ============================================
if [[ "${1:-}" == "--run-bg-update" ]]; then
  background_check_and_update; exit 0
fi
if [[ "${1:-}" == "--seed" ]]; then
  [[ -n "${2:-}" ]] || { echo "Usage: lmstudio --seed <URL>"; exit 1; }
  printf '%s\n' "$2" >"$URL_CACHE"; msg "Saved seed URL to $URL_CACHE"; exit 0
fi
if [[ "${1:-}" == "--clear-seed" ]]; then rm -f "$URL_CACHE"; msg "Cleared seed"; exit 0; fi
if [[ "${1:-}" == "--refresh" ]];    then rm -f "$RESOLVED_CACHE" "$RESOLVED_TS"; shift || true; fi
 

# === Main ===================================================================
WAIT_UPDATE=0
if [[ "${1:-}" == "--wait-update" ]]; then WAIT_UPDATE=1; shift; fi

current="$(best_current)"; current="${current:-}"

if (( WAIT_UPDATE == 1 )); then
  latest_url="$(resolve_latest_url || true)"
  if [[ -z "$latest_url" ]]; then
    echo "[lmstudio] ERROR: Could not resolve latest installers URL. Try: lmstudio --seed 'https://lmstudio.ai/download/latest/linux/x64'"; exit 1
  fi
  # If we already have the latest file, avoid showing a download notification and skip download
  current_file="$(basename "$(best_current)" 2>/dev/null || true)"
  latest_file="${latest_url##*/}"
  if [[ -n "$current_file" && "$current_file" == "$latest_file" ]]; then
    exec "${SYMLINK:-$current}" "$@"
  fi
  note "Downloading LM Studio update…" "${latest_file}"
  download_and_link "$latest_url"; prune_old
  exec "$SYMLINK" "$@"
fi

# Default: launch immediately, then background update worker.
if [[ -n "$current" && -x "$current" ]]; then
  ( LMSTUDIO_VERBOSE=0 "$SELF" --run-bg-update </dev/null >/dev/null 2>&1 & disown ) || true
  exec "$current" "$@"
fi

# No current installed – must fetch once, then launch.
latest_url="$(resolve_latest_url || true)"
if [[ -z "$latest_url" ]]; then
  echo "[lmstudio] ERROR: Could not resolve latest installers URL. Try: lmstudio --seed 'https://lmstudio.ai/download/latest/linux/x64'"; exit 1
fi
note "Downloading LM Studio…" "${latest_url##*/}"
download_and_link "$latest_url"; prune_old
exec "$SYMLINK" "$@"
