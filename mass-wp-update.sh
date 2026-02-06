#!/usr/bin/env bash
# mass-wp-update.sh
# Bulk WordPress updater using WP-CLI (core/plugins/themes + local ZIP plugin packages)
# Designed for multi-account hosting environments. Run as root.
#
# Usage:
#   ./mass-wp-update.sh 1   # dry run
#   ./mass-wp-update.sh 2   # normal run
#
# Notes:
# - Configuration is loaded from ./mass-wp-update.conf if present.
# - Installs list is cached to wpinstalls.txt and reused on next runs.
# - Optionally discovers NEW installs at the end and updates only those.
# - Logs:
#   ./logs/mass-wp-update.log
#   ./logs/updater.jsonl

set -u

# ==================================================
# BASE DIR (repo directory)
# ==================================================
BASE_DIR="$(cd "$(dirname "$0")" && pwd)"

# ==================================================
# DEFAULTS (can be overridden by mass-wp-update.conf)
# ==================================================
SEARCH_ROOTS_DEFAULT=(
  "/home"             # common (cPanel, CyberPanel)
  "/var/www/vhosts"   # Plesk
  "/var/www/clients"  # ISPConfig
  "/var/www"          # generic
  "/var/www/html"     # generic
)

# Paths/files (default relative to BASE_DIR)
INSTALLS_FILE_DEFAULT="$BASE_DIR/wpinstalls.txt"
CUSTOM_ROOTS_FILE_DEFAULT="$BASE_DIR/custom-roots.txt"
PREMIUM_ZIP_DIR_DEFAULT="$BASE_DIR/premium-zips"
LOG_DIR_DEFAULT="$BASE_DIR/logs"

# Binaries
WP_BIN_DEFAULT="/usr/local/bin/wp"
PHP_BIN_DEFAULT=""  # auto-detect

# Behavior toggles
USE_OWNER_USER_DEFAULT=1          # run wp-cli as owner of wp-config.php
ALLOW_ROOT_DEFAULT=0              # only used if USE_OWNER_USER=0 (not recommended)
SKIP_PLUGINS_DEFAULT=1
SKIP_THEMES_DEFAULT=1
WP_CLI_COLOR_DEFAULT=1

# ==================================================
# LOAD CONFIG
# ==================================================
CONF_FILE="${CONF_FILE:-$BASE_DIR/mass-wp-update.conf}"
if [[ -f "$CONF_FILE" ]]; then
  # shellcheck disable=SC1090
  source "$CONF_FILE"
fi

# Apply defaults if not set by config
INSTALLS_FILE="${INSTALLS_FILE:-$INSTALLS_FILE_DEFAULT}"
CUSTOM_ROOTS_FILE="${CUSTOM_ROOTS_FILE:-$CUSTOM_ROOTS_FILE_DEFAULT}"
PREMIUM_ZIP_DIR="${PREMIUM_ZIP_DIR:-$PREMIUM_ZIP_DIR_DEFAULT}"
LOG_DIR="${LOG_DIR:-$LOG_DIR_DEFAULT}"

WP_BIN="${WP_BIN:-$WP_BIN_DEFAULT}"
PHP_BIN="${PHP_BIN:-$PHP_BIN_DEFAULT}"

USE_OWNER_USER="${USE_OWNER_USER:-$USE_OWNER_USER_DEFAULT}"
ALLOW_ROOT="${ALLOW_ROOT:-$ALLOW_ROOT_DEFAULT}"
SKIP_PLUGINS="${SKIP_PLUGINS:-$SKIP_PLUGINS_DEFAULT}"
SKIP_THEMES="${SKIP_THEMES:-$SKIP_THEMES_DEFAULT}"
WP_CLI_COLOR="${WP_CLI_COLOR:-$WP_CLI_COLOR_DEFAULT}"

# SEARCH_ROOTS: if config didn’t set it, use defaults
if [[ "${SEARCH_ROOTS+set}" != "set" || ${#SEARCH_ROOTS[@]} -eq 0 ]]; then
  SEARCH_ROOTS=("${SEARCH_ROOTS_DEFAULT[@]}")
fi

# Auto-detect PHP_BIN if empty
if [[ -z "$PHP_BIN" ]]; then
  PHP_BIN="$(command -v php || true)"
fi

# ==================================================
# MODE
#   1 = dry run
#   2 = normal run
# ==================================================
MODE="${1:-}"
if [[ "$MODE" != "1" && "$MODE" != "2" ]]; then
  echo "Usage: $0 <mode>"
  echo "  1 = Dry run"
  echo "  2 = Normal run"
  exit 1
fi
DRY_RUN=0
[[ "$MODE" == "1" ]] && DRY_RUN=1

# ==================================================
# WP-CLI OPTIONS
# ==================================================
WP_CLI_OPTS=()
[[ "$WP_CLI_COLOR" == "1" ]] && WP_CLI_OPTS+=(--color)
[[ "$SKIP_PLUGINS" == "1" ]] && WP_CLI_OPTS+=(--skip-plugins)
[[ "$SKIP_THEMES" == "1" ]] && WP_CLI_OPTS+=(--skip-themes)

# ==================================================
# LOGGING
# ==================================================
TEXT_LOG="$LOG_DIR/mass-wp-update.log"
JSON_LOG="$LOG_DIR/updater.jsonl"

mkdir -p "$LOG_DIR"
touch "$TEXT_LOG" "$JSON_LOG"

ts()     { date "+%Y-%m-%d %H:%M:%S"; }
ts_iso() { date -u "+%Y-%m-%dT%H:%M:%SZ"; }

json_escape() {
  local s="${1//$'\r'/}"
  s="${s//\\/\\\\}"
  s="${s//\"/\\\"}"
  s="${s//$'\n'/\\n}"
  printf '%s' "$s"
}

log_plain() { echo "$*" | tee -a "$TEXT_LOG"; }

log_json() {
  local level="$1" site="$2" phase="$3" msg="$4"
  printf '{"ts":"%s","level":"%s","site":"%s","phase":"%s","msg":"%s"}\n' \
    "$(json_escape "$(ts_iso)")" \
    "$(json_escape "$level")" \
    "$(json_escape "$site")" \
    "$(json_escape "$phase")" \
    "$(json_escape "$msg")" \
    >> "$JSON_LOG"
}

site_banner() {
  local pfx="$1" site="$2"
  log_plain ""
  log_plain "================================================================================"
  log_plain "[$(ts)] ${pfx}SITE: $site"
  log_plain "================================================================================"
  log_json "info" "$site" "site" "${pfx}SITE START"
}

# ==================================================
# REQUIREMENTS CHECKS (soft)
# ==================================================
need_cmd() { command -v "$1" >/dev/null 2>&1; }

if ! need_cmd sudo;   then log_plain "[$(ts)] WARN: sudo not found"; fi
if ! need_cmd unzip;  then log_plain "[$(ts)] WARN: unzip not found (premium ZIP updates disabled)"; fi
if ! need_cmd stdbuf; then log_plain "[$(ts)] WARN: stdbuf not found (output may buffer)"; fi
if [[ ! -x "$WP_BIN" ]]; then log_plain "[$(ts)] WARN: WP_BIN not executable: $WP_BIN"; fi
if [[ -z "$PHP_BIN" || ! -x "$PHP_BIN" ]]; then log_plain "[$(ts)] WARN: PHP_BIN not executable/empty: $PHP_BIN"; fi

# ==================================================
# USER SELECTION
# ==================================================
owner_of_install() {
  local wp_path="$1"
  if [[ -f "$wp_path/wp-config.php" ]]; then
    stat -c '%U' "$wp_path/wp-config.php" 2>/dev/null || echo root
  else
    echo root
  fi
}

# Build command prefix for WP-CLI execution
# - If USE_OWNER_USER=1 and sudo exists: run as owner
# - Else: run as current user (root only if ALLOW_ROOT=1)
wp_prefix() {
  local wp_path="$1"
  if [[ "$USE_OWNER_USER" == "1" ]] && need_cmd sudo; then
    local owner
    owner="$(owner_of_install "$wp_path")"
    echo "sudo -u \"$owner\" -H"
    return 0
  fi

  # No sudo or disabled owner mode
  if [[ "$(id -u)" -eq 0 && "$ALLOW_ROOT" != "1" ]]; then
    echo ""
    return 0
  fi

  echo ""
}

# ==================================================
# DISCOVERY
# ==================================================
discover_wp_installs() {
  local roots=()

  # Config roots
  if [[ ${#SEARCH_ROOTS[@]} -gt 0 ]]; then
    roots+=("${SEARCH_ROOTS[@]}")
  fi

  # Optional custom roots file (one path per line)
  if [[ -f "$CUSTOM_ROOTS_FILE" ]]; then
    while IFS= read -r r; do
      [[ -n "${r// /}" ]] && roots+=("$r")
    done < "$CUSTOM_ROOTS_FILE"
  fi

  # Scan each existing root
  for root in "${roots[@]}"; do
    [[ -d "$root" ]] || continue
    find "$root" -type f -name "wp-config.php" 2>/dev/null \
      | sed 's#/wp-config\.php$##'
  done | sort -u
}

# ==================================================
# PREMIUM ZIP HELPERS
# ==================================================
get_plugin_slug_from_zip() {
  local zip="$1"
  [[ -f "$zip" ]] || return 1
  need_cmd unzip || return 1

  unzip -Z1 "$zip" 2>/dev/null \
    | sed 's/\r//' \
    | awk -F/ 'NF>1 && $1!="__MACOSX" {print $1; exit}'
}

# ==================================================
# WP RUNNER (timestamped lines + JSONL)
# ==================================================
wp_run() {
  local wp_path="$1"; shift
  local pfx="$1"; shift
  local site="$1"; shift
  local phase="$1"; shift

  local prefix
  prefix="$(wp_prefix "$wp_path")"

  # Refuse root unless explicitly allowed when not using sudo-owner mode
  if [[ -z "$prefix" && "$(id -u)" -eq 0 && "$ALLOW_ROOT" != "1" && "$USE_OWNER_USER" != "1" ]]; then
    local msg="WARN: Running as root is not enabled (ALLOW_ROOT=1). Skipping wp command."
    echo "[$(ts)] ${pfx}${site} | ${phase} | $msg" | tee -a "$TEXT_LOG"
    log_json "warn" "$site" "$phase" "$msg"
    return 0
  fi

  local cmd="$prefix \"$PHP_BIN\" \"$WP_BIN\" --path=\"$wp_path\" ${WP_CLI_OPTS[*]} $*"

  if [[ "$DRY_RUN" == "1" ]]; then
    echo "[$(ts)] ${pfx}${site} | ${phase} | [DRY] $cmd" | tee -a "$TEXT_LOG"
    log_json "info" "$site" "$phase" "[DRY] $cmd"
    return 0
  fi

  echo "[$(ts)] ${pfx}${site} | ${phase} | [RUN] $cmd" | tee -a "$TEXT_LOG"
  log_json "info" "$site" "$phase" "[RUN] $cmd"

  # Execute (never read from stdin)
  local rc=0
  if need_cmd stdbuf; then
    stdbuf -oL -eL bash -lc "$cmd" </dev/null 2>&1 | while IFS= read -r line; do
      echo "[$(ts)] ${pfx}${site} | ${phase} | $line" | tee -a "$TEXT_LOG"
      log_json "info" "$site" "$phase" "$line"
    done
    rc=${PIPESTATUS[0]:-0}
  else
    bash -lc "$cmd" </dev/null 2>&1 | while IFS= read -r line; do
      echo "[$(ts)] ${pfx}${site} | ${phase} | $line" | tee -a "$TEXT_LOG"
      log_json "info" "$site" "$phase" "$line"
    done
    rc=${PIPESTATUS[0]:-0}
  fi

  if [[ $rc -ne 0 ]]; then
    local msg="WARN: wp command exited rc=$rc"
    echo "[$(ts)] ${pfx}${site} | ${phase} | $msg" | tee -a "$TEXT_LOG"
    log_json "warn" "$site" "$phase" "$msg"
  fi

  return 0
}

# ==================================================
# PREMIUM ZIP UPDATES (only if installed)
# ==================================================
premium_update_for_site() {
  local wp_path="$1" pfx="$2" site="$3"

  [[ -d "$PREMIUM_ZIP_DIR" ]] || return 0
  need_cmd unzip || return 0

  shopt -s nullglob
  local zip slug prefix owner cmd

  for zip in "$PREMIUM_ZIP_DIR"/*.zip; do
    slug="$(get_plugin_slug_from_zip "$zip" || true)"
    [[ -n "$slug" ]] || continue

    # Check installed
    prefix="$(wp_prefix "$wp_path")"
    owner="$(owner_of_install "$wp_path")"

    if [[ "$USE_OWNER_USER" == "1" && -n "$prefix" ]]; then
      cmd="$prefix \"$PHP_BIN\" \"$WP_BIN\" --path=\"$wp_path\" ${WP_CLI_OPTS[*]} plugin is-installed \"$slug\""
    else
      cmd="\"$PHP_BIN\" \"$WP_BIN\" --path=\"$wp_path\" ${WP_CLI_OPTS[*]} plugin is-installed \"$slug\""
    fi

    if [[ "$DRY_RUN" == "1" ]]; then
      echo "[$(ts)] ${pfx}${site} | premium | [DRY] if installed: $slug -> install $zip --force" | tee -a "$TEXT_LOG"
      log_json "info" "$site" "premium" "[DRY] if installed: $slug -> install $zip --force"
      continue
    fi

    if bash -lc "$cmd" </dev/null >/dev/null 2>&1; then
      echo "[$(ts)] ${pfx}${site} | premium | Updating premium plugin: $slug" | tee -a "$TEXT_LOG"
      log_json "info" "$site" "premium" "Updating premium plugin: $slug"
      wp_run "$wp_path" "$pfx" "$site" "premium" plugin install "$zip" --force
    else
      echo "[$(ts)] ${pfx}${site} | premium | Skip premium (not installed): $slug" | tee -a "$TEXT_LOG"
      log_json "info" "$site" "premium" "Skip premium (not installed): $slug"
    fi
  done
}

# ==================================================
# PER-SITE UPDATE
# ==================================================
update_one_install() {
  local wp_path="$1" pfx="$2" site="$3"

  site_banner "$pfx" "$site"

  if [[ ! -f "$wp_path/wp-config.php" ]]; then
    local msg="Skip (no wp-config.php): $wp_path"
    echo "[$(ts)] ${pfx}${site} | precheck | $msg" | tee -a "$TEXT_LOG"
    log_json "warn" "$site" "precheck" "$msg"
    return 0
  fi

  wp_run "$wp_path" "$pfx" "$site" "precheck" plugin list --update=available
  wp_run "$wp_path" "$pfx" "$site" "precheck" theme list --update=available
  wp_run "$wp_path" "$pfx" "$site" "precheck" core check-update

  wp_run "$wp_path" "$pfx" "$site" "update" plugin update --all
  wp_run "$wp_path" "$pfx" "$site" "update" core update
  wp_run "$wp_path" "$pfx" "$site" "update" theme update --all

  premium_update_for_site "$wp_path" "$pfx" "$site"
  log_json "info" "$site" "site" "${pfx}SITE END"
}

# ==================================================
# MAIN
# ==================================================
cd "$BASE_DIR"

# Build installs list if not present
if [[ ! -f "$INSTALLS_FILE" ]]; then
  discover_wp_installs > "$INSTALLS_FILE"
fi

# Load installs into array (no stdin interactions during run)
mapfile -t INSTALLS < <(awk 'NF' "$INSTALLS_FILE")
TOTAL="${#INSTALLS[@]}"

log_plain "==== $(ts) START (dry_run=$DRY_RUN, total=$TOTAL) ===="
log_json "info" "GLOBAL" "start" "Start run (dry_run=$DRY_RUN, total=$TOTAL)"

for ((i=0; i<TOTAL; i++)); do
  wp_path="${INSTALLS[$i]}"
  pfx="[$((i+1))/$TOTAL] "
  site="$wp_path"
  update_one_install "$wp_path" "$pfx" "$site"
done

log_plain "==== $(ts) END ===="
log_json "info" "GLOBAL" "end" "End run"

# ==================================================
# OPTIONAL: DISCOVER NEW INSTALLS (DELTA ONLY)
# ==================================================
echo
read -r -p "Discover NEW WordPress installations and update only those? [y/N]: " ANSWER

if [[ "$ANSWER" =~ ^[Yy]$ ]]; then
  tmp_old_sorted="$(mktemp)"
  tmp_new_sorted="$(mktemp)"
  tmp_delta="$(mktemp)"

  awk 'NF' "$INSTALLS_FILE" | sort -u > "$tmp_old_sorted"
  discover_wp_installs | sort -u > "$tmp_new_sorted"
  comm -13 "$tmp_old_sorted" "$tmp_new_sorted" > "$tmp_delta" || true

  if [[ ! -s "$tmp_delta" ]]; then
    log_plain "[$(ts)] No new installations found."
    log_json "info" "GLOBAL" "discover" "No new installations found"
  else
    NEW_TOTAL="$(wc -l < "$tmp_delta" | tr -d ' ')"
    log_plain "[$(ts)] Found $NEW_TOTAL NEW installations. Appending and updating only new ones..."
    log_json "info" "GLOBAL" "discover" "Found $NEW_TOTAL new installations"

    cat "$tmp_delta" >> "$INSTALLS_FILE"
    sort -u "$INSTALLS_FILE" -o "$INSTALLS_FILE"

    mapfile -t NEW_INSTALLS < "$tmp_delta"
    for ((j=0; j<${#NEW_INSTALLS[@]}; j++)); do
      wp_path="${NEW_INSTALLS[$j]}"
      pfx="[NEW $((j+1))/${#NEW_INSTALLS[@]}] "
      site="$wp_path"
      update_one_install "$wp_path" "$pfx" "$site"
    done
  fi

  rm -f "$tmp_old_sorted" "$tmp_new_sorted" "$tmp_delta"
else
  log_plain "[$(ts)] Skipping discovery."
  log_json "info" "GLOBAL" "discover" "User skipped discovery"
fi
