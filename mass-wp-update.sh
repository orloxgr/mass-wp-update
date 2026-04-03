#!/usr/bin/env bash

# mass-wp-update.sh
# Bulk WordPress updater using WP-CLI (core/plugins/themes + local ZIP plugin packages)
# Designed for multi-account hosting environments. Run as root.
#
# Usage:
#   ./mass-wp-update.sh             # show full help and all options
#   ./mass-wp-update.sh 1           # dry run
#   ./mass-wp-update.sh 2           # normal run
#   ./mass-wp-update.sh 2 --backup-db --backup-plugins
#   ./mass-wp-update.sh 2 --conf /etc/wp-updater/staging.conf --refresh
#
# Run with no arguments for full usage, all options, and examples.

set -uo pipefail

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

# Backup defaults
BACKUP_DIR_DEFAULT="$BASE_DIR/backups"
BACKUP_DB_DEFAULT=0           # 1 = dump DB before updating
BACKUP_PLUGINS_DEFAULT=0      # 1 = ZIP each updatable plugin before updating
BACKUP_RETENTION_DAYS_DEFAULT=30  # 0 = keep forever

# Binaries
WP_BIN_DEFAULT="/usr/local/bin/wp"
PHP_BIN_DEFAULT=""   # auto-detect

# Behavior toggles
USE_OWNER_USER_DEFAULT=1    # run wp-cli as owner of wp-config.php
ALLOW_ROOT_DEFAULT=0        # only used if USE_OWNER_USER=0 (not recommended)
SKIP_PLUGINS_DEFAULT=1
SKIP_THEMES_DEFAULT=1
WP_CLI_COLOR_DEFAULT=1

# ==================================================
# LOAD CONFIG
# Pre-scan argv for --conf before sourcing so the right
# config file is loaded before defaults are applied.
# --help / no-args are handled after show_help is defined.
# ==================================================

CONF_FILE="${CONF_FILE:-$BASE_DIR/mass-wp-update.conf}"
# Pre-scan for --conf
_pre_next=""
for _i in "$@"; do
  if [[ "$_pre_next" == "conf" ]]; then
    CONF_FILE="$_i"
    _pre_next=""
  fi
  [[ "$_i" == "--conf" ]] && _pre_next="conf" || true
done
unset _i _pre_next

if [[ -f "$CONF_FILE" ]]; then
  # shellcheck disable=SC1090
  source "$CONF_FILE"
fi

# Apply defaults if not set by config
INSTALLS_FILE="${INSTALLS_FILE:-$INSTALLS_FILE_DEFAULT}"
CUSTOM_ROOTS_FILE="${CUSTOM_ROOTS_FILE:-$CUSTOM_ROOTS_FILE_DEFAULT}"
PREMIUM_ZIP_DIR="${PREMIUM_ZIP_DIR:-$PREMIUM_ZIP_DIR_DEFAULT}"
LOG_DIR="${LOG_DIR:-$LOG_DIR_DEFAULT}"
BACKUP_DIR="${BACKUP_DIR:-$BACKUP_DIR_DEFAULT}"
BACKUP_DB="${BACKUP_DB:-$BACKUP_DB_DEFAULT}"
BACKUP_PLUGINS="${BACKUP_PLUGINS:-$BACKUP_PLUGINS_DEFAULT}"
BACKUP_RETENTION_DAYS="${BACKUP_RETENTION_DAYS:-$BACKUP_RETENTION_DAYS_DEFAULT}"
WP_BIN="${WP_BIN:-$WP_BIN_DEFAULT}"
PHP_BIN="${PHP_BIN:-$PHP_BIN_DEFAULT}"
USE_OWNER_USER="${USE_OWNER_USER:-$USE_OWNER_USER_DEFAULT}"
ALLOW_ROOT="${ALLOW_ROOT:-$ALLOW_ROOT_DEFAULT}"
SKIP_PLUGINS="${SKIP_PLUGINS:-$SKIP_PLUGINS_DEFAULT}"
SKIP_THEMES="${SKIP_THEMES:-$SKIP_THEMES_DEFAULT}"
WP_CLI_COLOR="${WP_CLI_COLOR:-$WP_CLI_COLOR_DEFAULT}"

# SEARCH_ROOTS: if config didn't set it, use defaults
if [[ "${SEARCH_ROOTS+set}" != "set" || ${#SEARCH_ROOTS[@]} -eq 0 ]]; then
  SEARCH_ROOTS=("${SEARCH_ROOTS_DEFAULT[@]}")
fi

# Auto-detect PHP_BIN if empty
if [[ -z "$PHP_BIN" ]]; then
  PHP_BIN="$(command -v php || true)"
fi

# ==================================================
# HELP
# ==================================================

show_help() {
  cat <<EOF

  mass-wp-update.sh
  Bulk WordPress updater via WP-CLI — core, plugins, themes, and premium ZIPs.
  Designed for multi-account hosting environments. Must be run as root.

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  USAGE
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

  $0                        # interactive wizard (recommended for first run)
  $0 <mode> [options]       # scripted / cron path

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  INTERACTIVE MODE  (no arguments)
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

  Running without arguments launches a step-by-step wizard that asks:

    Step 1 — Backup directory setup
              If no backup directory is configured and none exists yet, offers
              to create one in the current folder and save it to the conf file.
              This step is skipped on subsequent runs once BACKUP_DIR is set.

    Step 2 — Run mode
              1 = Dry run   (no changes, preview only)
              2 = Real run  (updates are applied)

    Step 3 — Backup scope
              1 = Database only
              2 = Plugins only  (updatable plugins archived as versioned ZIPs)
              3 = Database AND plugins
              4 = No backups

  A summary is shown before anything runs, with a final confirmation prompt.

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  SCRIPTED / CRON MODES  (positional first argument required)
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

  1             Dry run — discover installs and log every action that WOULD be
                taken, without making any changes or writing any backups.

  2             Normal run — perform all updates. Backups are taken before
                updating if BACKUP_DB=1 or BACKUP_PLUGINS=1 in the conf.

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  OPTIONS
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

  -h, --help          Show this help message and exit.

  --conf <file>       Path to a custom configuration file.
                      Default: ./mass-wp-update.conf

  --backup-db         Enable database backup for this run only,
                      overriding the BACKUP_DB setting in the conf file.

  --backup-plugins    Enable plugin archive backup for this run only,
                      overriding the BACKUP_PLUGINS setting in the conf file.

  --backup-dir <dir>  Override the BACKUP_DIR path for this run only.

  --refresh           Force re-discovery of all WordPress installations,
                      ignoring and replacing the cached wpinstalls.txt file.

  --no-color          Disable colored WP-CLI output for this run only.

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  CONFIGURATION FILE  (mass-wp-update.conf)
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

  Key settings you can configure in mass-wp-update.conf:

  SEARCH_ROOTS        Array of directories to scan for wp-config.php.
  CUSTOM_ROOTS_FILE   File with additional paths to scan (one per line).
  INSTALLS_FILE       Where the cached list of WP installs is stored.
  PREMIUM_ZIP_DIR     Directory of premium plugin ZIP files to install.
  LOG_DIR             Directory for log output.
  BACKUP_DIR          Root directory for all backups.
  BACKUP_DB           1 = dump database before updating  (default: 0).
  BACKUP_PLUGINS      1 = ZIP updatable plugins before updating  (default: 0).
  BACKUP_RETENTION_DAYS  Days to keep old snapshots; 0 = forever (default: 30).
  WP_BIN              Path to WP-CLI binary.
  PHP_BIN             Path to PHP CLI (auto-detected if empty).
  USE_OWNER_USER      1 = run WP-CLI as the file owner  (default: 1).
  ALLOW_ROOT          1 = allow running as root directly  (default: 0).
  SKIP_PLUGINS        1 = pass --skip-plugins to WP-CLI  (default: 1).
  SKIP_THEMES         1 = pass --skip-themes to WP-CLI   (default: 1).
  WP_CLI_COLOR        1 = enable WP-CLI color output     (default: 1).

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  BACKUP DIRECTORY LAYOUT
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

  backups/
    home__alice__public_html/          ← one directory per site
      20250401_143022/                 ← one snapshot per run (timestamp)
        db/
          home__alice__public_html_wp6.5.3.sql
        plugins/
          woocommerce_v8.7.0.zip       ← slug + version before update
          yoast-seo_v22.1.0.zip
        manifest.json                  ← site URL, WP version, file list

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  EXAMPLES
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

  1.  Dry run — see what would be updated, no changes made:

        ./mass-wp-update.sh 1

  2.  Normal run — update all discovered WordPress installations:

        ./mass-wp-update.sh 2

  3.  Normal run with database and plugin backups enabled for this run only:

        ./mass-wp-update.sh 2 --backup-db --backup-plugins

  4.  Normal run using a custom config file (e.g. for a staging environment):

        ./mass-wp-update.sh 2 --conf /etc/wp-updater/staging.conf

  5.  Normal run, force refresh of the install cache, backups sent to /mnt/nas:

        ./mass-wp-update.sh 2 --refresh --backup-db --backup-dir /mnt/nas/wp-backups

  6.  Dry run with a custom config to preview a staging environment update:

        ./mass-wp-update.sh 1 --conf /etc/wp-updater/staging.conf --no-color

  7.  Cron-friendly normal run — backups on, no color, custom log dir via conf:

        ./mass-wp-update.sh 2 --backup-db --backup-plugins --no-color

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  LOGS
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

  ./logs/mass-wp-update.log   Human-readable timestamped output.
  ./logs/updater.jsonl        Structured JSON lines for monitoring/parsing.

EOF
}

# ==================================================
# ARGUMENT PARSING
# ==================================================

MODE=""
OPT_REFRESH=0
OPT_BACKUP_DB_OVERRIDE=0
OPT_BACKUP_PLUGINS_OVERRIDE=0
OPT_BACKUP_DIR_OVERRIDE=""
OPT_NO_COLOR=0
INTERACTIVE=0   # set to 1 when running the wizard (no args given)

if [[ $# -eq 0 ]]; then
  # ── No arguments: run the interactive wizard ──────────────────────────────
  INTERACTIVE=1
else
  # ── Arguments given: cron / scripted path ────────────────────────────────
  case "${1:-}" in
    -h|--help) show_help; exit 0 ;;
    1|2)       MODE="$1"; shift  ;;
    *)
      echo "ERROR: First argument must be a mode (1 = dry run, 2 = normal run)."
      echo "       Run without arguments to launch the interactive wizard."
      echo "       Run with --help for full usage."
      exit 1
      ;;
  esac

  while [[ $# -gt 0 ]]; do
    case "$1" in
      -h|--help)
        show_help; exit 0
        ;;
      --conf)
        [[ -z "${2:-}" ]] && { echo "ERROR: --conf requires a path."; exit 1; }
        CONF_FILE="$2"; shift 2
        ;;
      --backup-db)
        OPT_BACKUP_DB_OVERRIDE=1; shift
        ;;
      --backup-plugins)
        OPT_BACKUP_PLUGINS_OVERRIDE=1; shift
        ;;
      --backup-dir)
        [[ -z "${2:-}" ]] && { echo "ERROR: --backup-dir requires a path."; exit 1; }
        OPT_BACKUP_DIR_OVERRIDE="$2"; shift 2
        ;;
      --refresh)
        OPT_REFRESH=1; shift
        ;;
      --no-color)
        OPT_NO_COLOR=1; shift
        ;;
      *)
        echo "ERROR: Unknown option: $1"
        echo "       Run without arguments to launch the interactive wizard."
        echo "       Run with --help for full usage."
        exit 1
        ;;
    esac
  done

  # Apply CLI overrides on top of config values
  [[ "$OPT_BACKUP_DB_OVERRIDE"      == "1" ]] && BACKUP_DB=1
  [[ "$OPT_BACKUP_PLUGINS_OVERRIDE" == "1" ]] && BACKUP_PLUGINS=1
  [[ -n "$OPT_BACKUP_DIR_OVERRIDE"        ]] && BACKUP_DIR="$OPT_BACKUP_DIR_OVERRIDE"
  [[ "$OPT_NO_COLOR"                == "1" ]] && WP_CLI_COLOR=0
  [[ "$OPT_REFRESH"                 == "1" && -f "$INSTALLS_FILE" ]] && rm -f "$INSTALLS_FILE"
fi

DRY_RUN=0
[[ "$MODE" == "1" ]] && DRY_RUN=1

# ==================================================
# INTERACTIVE WIZARD
# Runs only when no arguments are given.
# Asks three questions in order:
#   1. Backup directory setup  (first-run only)
#   2. Mode  (dry run / real run)
#   3. What to back up
# ==================================================

interactive_wizard() {
  echo ""
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo "  mass-wp-update — interactive setup"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo ""

  # ------------------------------------------------------------------
  # Step 1 — Backup directory
  # Only ask if BACKUP_DIR is still the default (i.e. not configured)
  # and the directory does not yet exist.
  # ------------------------------------------------------------------
  local configured_backup_dir
  configured_backup_dir="$(grep -E '^[[:space:]]*BACKUP_DIR=' "$CONF_FILE" 2>/dev/null | tail -1 | cut -d= -f2- | tr -d '"'"'" | xargs || true)"

  if [[ -z "$configured_backup_dir" && ! -d "$BACKUP_DIR" ]]; then
    echo "  STEP 1 of 3 — Backup directory"
    echo ""
    echo "  No backup directory is configured and none exists yet."
    echo "  Default location: $BACKUP_DIR"
    echo ""
    local ans_bdir
    read -r -p "  Create backup directory here and save to config? [Y/n]: " ans_bdir
    ans_bdir="${ans_bdir:-Y}"

    if [[ "$ans_bdir" =~ ^[Yy]$ ]]; then
      if mkdir -p "$BACKUP_DIR" 2>/dev/null; then
        echo "  ✔  Created: $BACKUP_DIR"
        # Persist to config: append or update BACKUP_DIR line
        if [[ -f "$CONF_FILE" ]]; then
          if grep -qE '^[[:space:]]*#?[[:space:]]*BACKUP_DIR=' "$CONF_FILE"; then
            # Uncomment / replace any existing BACKUP_DIR line
            sed -i "s|^[[:space:]]*#*[[:space:]]*BACKUP_DIR=.*|BACKUP_DIR=\"$BACKUP_DIR\"|" "$CONF_FILE"
          else
            # Append under the BACKUP SETTINGS section header if it exists, else at end
            echo "" >> "$CONF_FILE"
            echo "BACKUP_DIR=\"$BACKUP_DIR\"" >> "$CONF_FILE"
          fi
          echo "  ✔  Saved BACKUP_DIR to: $CONF_FILE"
        else
          echo "  ⚠  Config file not found ($CONF_FILE); BACKUP_DIR not persisted."
          echo "     Add this line manually: BACKUP_DIR=\"$BACKUP_DIR\""
        fi
      else
        echo "  ✘  Could not create $BACKUP_DIR — check permissions."
        echo "     Continuing without a backup directory."
      fi
    else
      echo "  Skipped. You can set BACKUP_DIR in $CONF_FILE later."
    fi
    echo ""
  fi

  # ------------------------------------------------------------------
  # Step 2 — Mode
  # ------------------------------------------------------------------
  echo "  STEP 2 of 3 — Run mode"
  echo ""
  echo "    1)  Dry run  — show what would be updated, make no changes"
  echo "    2)  Real run — apply all updates"
  echo ""
  local ans_mode
  while true; do
    read -r -p "  Choose mode [1/2]: " ans_mode
    case "$ans_mode" in
      1) MODE=1; DRY_RUN=1; echo "  ✔  Dry run selected.";  break ;;
      2) MODE=2; DRY_RUN=0; echo "  ✔  Real run selected."; break ;;
      *) echo "  Please enter 1 or 2." ;;
    esac
  done
  echo ""

  # ------------------------------------------------------------------
  # Step 3 — Backup options
  # ------------------------------------------------------------------
  echo "  STEP 3 of 3 — Backups before updating"
  echo ""
  echo "    1)  Database only"
  echo "    2)  Plugins only   (archives each updatable plugin as a versioned ZIP)"
  echo "    3)  Database AND plugins"
  echo "    4)  No backups"
  echo ""
  local ans_backup
  while true; do
    read -r -p "  Choose backup option [1/2/3/4]: " ans_backup
    case "$ans_backup" in
      1) BACKUP_DB=1; BACKUP_PLUGINS=0; echo "  ✔  Database backup enabled.";                    break ;;
      2) BACKUP_DB=0; BACKUP_PLUGINS=1; echo "  ✔  Plugin backup enabled.";                      break ;;
      3) BACKUP_DB=1; BACKUP_PLUGINS=1; echo "  ✔  Database and plugin backups enabled.";        break ;;
      4) BACKUP_DB=0; BACKUP_PLUGINS=0; echo "  ✔  No backups — updates will run unguarded.";    break ;;
      *) echo "  Please enter 1, 2, 3 or 4." ;;
    esac
  done
  echo ""

  # ------------------------------------------------------------------
  # Summary before proceeding
  # ------------------------------------------------------------------
  local mode_label backup_label
  [[ "$DRY_RUN" == "1" ]] && mode_label="Dry run (no changes)" || mode_label="Real run"
  case "${BACKUP_DB}${BACKUP_PLUGINS}" in
    10) backup_label="Database only" ;;
    01) backup_label="Plugins only" ;;
    11) backup_label="Database + plugins" ;;
    *)  backup_label="None" ;;
  esac

  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo "  Ready to run"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo ""
  echo "  Mode    : $mode_label"
  echo "  Backups : $backup_label"
  [[ "$BACKUP_DB" == "1" || "$BACKUP_PLUGINS" == "1" ]] &&     echo "  Backup  : $BACKUP_DIR"
  echo ""

  local ans_confirm
  read -r -p "  Proceed? [Y/n]: " ans_confirm
  ans_confirm="${ans_confirm:-Y}"
  if [[ ! "$ans_confirm" =~ ^[Yy]$ ]]; then
    echo "  Aborted."
    exit 0
  fi
  echo ""
}

# Run the wizard only in interactive mode
[[ "$INTERACTIVE" == "1" ]] && interactive_wizard

# ==================================================
# WP-CLI OPTIONS
# ==================================================

WP_CLI_OPTS=()
[[ "$WP_CLI_COLOR" == "1" ]] && WP_CLI_OPTS+=(--color)
[[ "$SKIP_PLUGINS"  == "1" ]] && WP_CLI_OPTS+=(--skip-plugins)
[[ "$SKIP_THEMES"   == "1" ]] && WP_CLI_OPTS+=(--skip-themes)

# ==================================================
# LOGGING
# ==================================================

TEXT_LOG="$LOG_DIR/mass-wp-update.log"
JSON_LOG="$LOG_DIR/updater.jsonl"

mkdir -p "$LOG_DIR"
touch "$TEXT_LOG" "$JSON_LOG"

ts()     { date "+%Y-%m-%d %H:%M:%S"; }
ts_iso() { date -u "+%Y-%m-%dT%H:%M:%SZ"; }
ts_compact() { date "+%Y%m%d_%H%M%S"; }

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
    "$(json_escape "$level")"   \
    "$(json_escape "$site")"    \
    "$(json_escape "$phase")"   \
    "$(json_escape "$msg")"     \
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
if ! need_cmd zip;    then log_plain "[$(ts)] WARN: zip not found (plugin backups disabled)"; fi
if ! need_cmd stdbuf; then log_plain "[$(ts)] WARN: stdbuf not found (output may buffer)"; fi

if [[ ! -x "$WP_BIN" ]]; then
  log_plain "[$(ts)] WARN: WP_BIN not executable: $WP_BIN"
fi
if [[ -z "$PHP_BIN" || ! -x "$PHP_BIN" ]]; then
  log_plain "[$(ts)] WARN: PHP_BIN not executable/empty: $PHP_BIN"
fi

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

wp_prefix() {
  local wp_path="$1"
  if [[ "$USE_OWNER_USER" == "1" ]] && need_cmd sudo; then
    local owner
    owner="$(owner_of_install "$wp_path")"
    echo "sudo -u \"$owner\" -H"
    return 0
  fi
  echo ""
}

# ==================================================
# DISCOVERY
# ==================================================

discover_wp_installs() {
  local roots=()

  if [[ ${#SEARCH_ROOTS[@]} -gt 0 ]]; then
    roots+=("${SEARCH_ROOTS[@]}")
  fi

  if [[ -f "$CUSTOM_ROOTS_FILE" ]]; then
    while IFS= read -r r; do
      [[ -n "${r// /}" ]] && roots+=("$r")
    done < "$CUSTOM_ROOTS_FILE"
  fi

  for root in "${roots[@]}"; do
    [[ -d "$root" ]] || continue

    find "$root"       -type d \( -name wp-content -o -name node_modules -o -name vendor -o -name .git \) -prune -o       -type f -name "wp-config.php" -print 2>/dev/null
  done |
  while IFS= read -r cfg; do
    site="${cfg%/wp-config.php}"
    [[ -f "$site/wp-load.php" && -d "$site/wp-content" ]] && printf '%s
' "$site"
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
  local pfx="$1";     shift
  local site="$1";    shift
  local phase="$1";   shift

  local prefix
  prefix="$(wp_prefix "$wp_path")"

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
# BACKUP HELPERS
# ==================================================

# Derive a filesystem-safe site identifier from the install path.
# e.g. /home/alice/public_html  ->  home__alice__public_html
site_id_from_path() {
  local wp_path="$1"
  # Strip leading slash, replace remaining slashes with double underscores
  printf '%s' "${wp_path#/}" | tr '/' '_' | sed 's/__*/__/g'
}

# Return the absolute backup path for a given site+timestamp.
# Structure: BACKUP_DIR/<site_id>/<timestamp>/
# Uses realpath -m so the path is absolute even if BACKUP_DIR
# was set as a relative path (e.g. "./backups") in the conf.
site_backup_dir() {
  local wp_path="$1" stamp="$2"
  local site_id
  site_id="$(site_id_from_path "$wp_path")"
  realpath -m "$BACKUP_DIR/$site_id/$stamp"
}

# --------------------------------------------------
# ensure_backup_dir
#
# Called once before the main loop starts (if backups are
# enabled). Checks that BACKUP_DIR exists on disk and, if
# not, offers to create it interactively or aborts backups
# for this run so the rest of the script is unaffected.
# In non-interactive (cron) mode it exits with an error
# rather than silently skipping backups.
# --------------------------------------------------
ensure_backup_dir() {
  [[ "$BACKUP_DB" == "1" || "$BACKUP_PLUGINS" == "1" ]] || return 0
  [[ "$DRY_RUN"   == "1" ]] && return 0   # dry run never writes files

  if [[ -d "$BACKUP_DIR" ]]; then
    return 0   # already exists — nothing to do
  fi

  if [[ "$INTERACTIVE" == "1" ]]; then
    echo ""
    echo "  ⚠  Backup directory does not exist: $BACKUP_DIR"
    local ans
    read -r -p "  Create it now? [Y/n]: " ans
    ans="${ans:-Y}"
    if [[ "$ans" =~ ^[Yy]$ ]]; then
      if mkdir -p "$BACKUP_DIR" 2>/dev/null; then
        echo "  ✔  Created: $BACKUP_DIR"
        log_plain "[$(ts)] Backup directory created: $BACKUP_DIR"
        log_json "info" "GLOBAL" "backup:setup" "Created BACKUP_DIR: $BACKUP_DIR"
      else
        echo "  ✘  Could not create $BACKUP_DIR — check permissions."
        echo "     Disabling backups for this run."
        log_plain "[$(ts)] WARN: Could not create BACKUP_DIR $BACKUP_DIR — backups disabled"
        log_json "warn" "GLOBAL" "backup:setup" "Could not create BACKUP_DIR — backups disabled"
        BACKUP_DB=0
        BACKUP_PLUGINS=0
      fi
    else
      echo "  Backups disabled for this run."
      log_plain "[$(ts)] WARN: BACKUP_DIR missing and creation declined — backups disabled"
      log_json "warn" "GLOBAL" "backup:setup" "BACKUP_DIR missing, creation declined — backups disabled"
      BACKUP_DB=0
      BACKUP_PLUGINS=0
    fi
    echo ""
  else
    # Non-interactive (cron) path — fail loudly so the operator notices
    echo "ERROR: Backup directory does not exist: $BACKUP_DIR"
    echo "       Create it first or set BACKUP_DIR in $CONF_FILE."
    log_plain "[$(ts)] ERROR: BACKUP_DIR does not exist: $BACKUP_DIR — aborting"
    log_json "error" "GLOBAL" "backup:setup" "BACKUP_DIR does not exist: $BACKUP_DIR"
    exit 1
  fi
}

# --------------------------------------------------
# backup_database
#
# Dumps the WordPress database to:
#   <backup_dir>/db/<site_id>_<stamp>.sql
#
# The filename embeds the WordPress version so the dump
# is self-describing without needing a manifest.
# --------------------------------------------------
backup_database() {
  local wp_path="$1" pfx="$2" site="$3" bdir="$4"

  [[ "$BACKUP_DB" == "1" ]] || return 0

  local phase="backup:db"
  local db_dir="$bdir/db"

  if [[ "$DRY_RUN" == "1" ]]; then
    echo "[$(ts)] ${pfx}${site} | ${phase} | [DRY] would dump DB to $db_dir/" | tee -a "$TEXT_LOG"
    log_json "info" "$site" "$phase" "[DRY] would dump DB to $db_dir/"
    return 0
  fi

  # Resolve to absolute path — WP-CLI db export may run from a different cwd
  db_dir="$(realpath -m "$db_dir")"
  mkdir -p "$db_dir"

  local owner
  owner="$(owner_of_install "$wp_path")"
  chown -R "$owner":"$owner" "$bdir" 2>/dev/null || true

  # Fetch the current WP version to embed in the filename
  local prefix wp_version dump_file
  prefix="$(wp_prefix "$wp_path")"
  wp_version="$(bash -lc "$prefix "$PHP_BIN" "$WP_BIN" --path="$wp_path" ${WP_CLI_OPTS[*]} core version --quiet 2>/dev/null" </dev/null || echo "unknown")"
  wp_version="${wp_version// /_}"   # sanitise (should already be clean)

  local site_id
  site_id="$(site_id_from_path "$wp_path")"
  dump_file="$(realpath -m "${db_dir}/${site_id}_wp${wp_version}.sql")"

  echo "[$(ts)] ${pfx}${site} | ${phase} | Dumping DB (WP ${wp_version}) -> $dump_file" | tee -a "$TEXT_LOG"
  log_json "info" "$site" "$phase" "Dumping DB (WP ${wp_version}) -> $dump_file"

  local cmd out rc
  cmd="$prefix "$PHP_BIN" "$WP_BIN" --path="$wp_path" ${WP_CLI_OPTS[*]} db export "$dump_file" --quiet"
  out="$(bash -lc "$cmd" </dev/null 2>&1)"
  rc=$?

  if [[ $rc -eq 0 ]]; then
    local size_kb
    size_kb="$(du -k "$dump_file" 2>/dev/null | cut -f1)"
    echo "[$(ts)] ${pfx}${site} | ${phase} | DB dump OK (${size_kb} KB): $dump_file" | tee -a "$TEXT_LOG"
    log_json "info" "$site" "$phase" "DB dump OK (${size_kb} KB): $dump_file"
  else
    echo "[$(ts)] ${pfx}${site} | ${phase} | WARN: DB dump failed for $wp_path (rc=$rc): $out" | tee -a "$TEXT_LOG"
    log_json "warn" "$site" "$phase" "DB dump failed for $wp_path (rc=$rc): $out"
  fi
}

# --------------------------------------------------
# backup_updatable_plugins
#
# For each plugin that has an available update, archives its
# current directory to:
#   <backup_dir>/plugins/<slug>_v<current_version>_<stamp>.zip
#
# Only plugins that are actually going to be updated are backed
# up — not the entire plugin library — keeping backup size sane.
# --------------------------------------------------
backup_updatable_plugins() {
  local wp_path="$1" pfx="$2" site="$3" bdir="$4"

  [[ "$BACKUP_PLUGINS" == "1" ]] || return 0
  need_cmd zip || return 0

  local phase="backup:plugins"
  local plugin_dir_base="$wp_path/wp-content/plugins"

  if [[ ! -d "$plugin_dir_base" ]]; then
    echo "[$(ts)] ${pfx}${site} | ${phase} | No plugins directory found, skipping." | tee -a "$TEXT_LOG"
    return 0
  fi

  if [[ "$DRY_RUN" == "1" ]]; then
    echo "[$(ts)] ${pfx}${site} | ${phase} | [DRY] would archive updatable plugins to $bdir/plugins/" | tee -a "$TEXT_LOG"
    log_json "info" "$site" "$phase" "[DRY] would archive updatable plugins to $bdir/plugins/"
    return 0
  fi

  # Ask WP-CLI for plugins that have updates available.
  # Output format: slug<TAB>version
  local prefix
  prefix="$(wp_prefix "$wp_path")"

  local plugin_list
  plugin_list="$(bash -lc \
    "$prefix \"$PHP_BIN\" \"$WP_BIN\" --path=\"$wp_path\" ${WP_CLI_OPTS[*]} plugin list --update=available --fields=name,version --format=csv --quiet 2>/dev/null" \
    </dev/null || true)"

  if [[ -z "$plugin_list" ]]; then
    echo "[$(ts)] ${pfx}${site} | ${phase} | No updatable plugins found; skipping plugin backup." | tee -a "$TEXT_LOG"
    log_json "info" "$site" "$phase" "No updatable plugins found; skipping plugin backup"
    return 0
  fi

  # Use an absolute path for the backup dir so it stays valid after cd
  local plugins_bdir
  plugins_bdir="$(realpath -m "$bdir/plugins")"
  mkdir -p "$plugins_bdir"

  # CSV header is "name,version" — skip it then process each row
  local first_line=1
  while IFS=',' read -r slug version; do
    # Skip the CSV header row
    if [[ $first_line -eq 1 ]]; then
      first_line=0
      continue
    fi

    # Strip any surrounding quotes WP-CLI may emit
    slug="${slug//\"/}"
    version="${version//\"/}"
    version="${version// /_}"   # sanitise spaces just in case

    local plugin_src="$plugin_dir_base/$slug"
    if [[ ! -d "$plugin_src" ]]; then
      echo "[$(ts)] ${pfx}${site} | ${phase} | WARN: Plugin dir not found, skipping: $plugin_src" | tee -a "$TEXT_LOG"
      log_json "warn" "$site" "$phase" "Plugin dir not found: $plugin_src"
      continue
    fi

    local zip_name="${slug}_v${version}.zip"
    # zip_path must be absolute — zip is run from inside $plugin_dir_base
    # so any relative path would resolve against that dir, not BASE_DIR.
    local zip_path
    zip_path="$(realpath -m "$plugins_bdir/$zip_name")"

    echo "[$(ts)] ${pfx}${site} | ${phase} | Archiving plugin: $slug v${version} -> $zip_path" | tee -a "$TEXT_LOG"
    log_json "info" "$site" "$phase" "Archiving plugin: $slug v${version} -> $zip_path"

    # Run zip as root (current process) — reading plugin files is fine since
    # root can read all files, and the backup dir is root-owned.
    # We cd into plugin_dir_base so the archive extracts as <slug>/...
    # without extra path components.
    local zip_err
    zip_err="$(cd "$plugin_dir_base" && zip -rq "$zip_path" "$slug" 2>&1)"
    local zip_rc=$?
    if [[ $zip_rc -eq 0 ]]; then
      local size_kb
      size_kb="$(du -k "$zip_path" 2>/dev/null | cut -f1)"
      echo "[$(ts)] ${pfx}${site} | ${phase} | Plugin archive OK (${size_kb} KB): $zip_name" | tee -a "$TEXT_LOG"
      log_json "info" "$site" "$phase" "Plugin archive OK (${size_kb} KB): $zip_name"
    else
      echo "[$(ts)] ${pfx}${site} | ${phase} | WARN: Archive failed for plugin: $slug (rc=$zip_rc) $zip_err" | tee -a "$TEXT_LOG"
      log_json "warn" "$site" "$phase" "Archive failed for plugin: $slug (rc=$zip_rc) $zip_err"
    fi

  done <<< "$plugin_list"
}

# --------------------------------------------------
# write_backup_manifest
#
# Writes a JSON manifest to <backup_dir>/manifest.json
# summarising what was backed up, the WP version, and
# when the backup was taken. Useful for auditing.
# --------------------------------------------------
write_backup_manifest() {
  local wp_path="$1" bdir="$2" stamp="$3" site="$4"

  [[ "$DRY_RUN" == "1" ]] && return 0
  [[ "$BACKUP_DB" == "1" || "$BACKUP_PLUGINS" == "1" ]] || return 0
  [[ -d "$bdir" ]] || return 0

  local prefix
  prefix="$(wp_prefix "$wp_path")"

  local wp_version site_url
  wp_version="$(bash -lc \
    "$prefix \"$PHP_BIN\" \"$WP_BIN\" --path=\"$wp_path\" ${WP_CLI_OPTS[*]} core version --quiet 2>/dev/null" \
    </dev/null || echo "unknown")"
  site_url="$(bash -lc \
    "$prefix \"$PHP_BIN\" \"$WP_BIN\" --path=\"$wp_path\" ${WP_CLI_OPTS[*]} option get siteurl --quiet 2>/dev/null" \
    </dev/null || echo "unknown")"

  # Gather backed-up plugin filenames into a JSON array
  local plugins_json="[]"
  local plugins_bdir="$bdir/plugins"
  if [[ -d "$plugins_bdir" ]]; then
    local entries=()
    while IFS= read -r f; do
      entries+=("\"$(basename "$f")\"")
    done < <(find "$plugins_bdir" -maxdepth 1 -name "*.zip" | sort)
    if [[ ${#entries[@]} -gt 0 ]]; then
      plugins_json="[$(IFS=,; echo "${entries[*]}")]"
    fi
  fi

  local db_file="none"
  local db_dir="$bdir/db"
  if [[ -d "$db_dir" ]]; then
    local found_db
    found_db="$(find "$db_dir" -maxdepth 1 -name "*.sql" | head -1)"
    [[ -n "$found_db" ]] && db_file="$(basename "$found_db")"
  fi

  cat > "$bdir/manifest.json" <<EOF
{
  "backup_stamp": "$(json_escape "$stamp")",
  "backup_ts_utc": "$(json_escape "$(ts_iso)")",
  "wp_path": "$(json_escape "$wp_path")",
  "site_url": "$(json_escape "$site_url")",
  "wp_version": "$(json_escape "$wp_version")",
  "db_dump": "$(json_escape "$db_file")",
  "plugins_archived": $plugins_json
}
EOF
  log_json "info" "$site" "backup:manifest" "Manifest written: $bdir/manifest.json"
}

# --------------------------------------------------
# purge_old_backups
#
# Removes backup snapshot directories older than
# BACKUP_RETENTION_DAYS. Runs once per site at the
# end of its update cycle.
# --------------------------------------------------
purge_old_backups() {
  local wp_path="$1" pfx="$2" site="$3"

  [[ "$BACKUP_RETENTION_DAYS" -gt 0 ]] 2>/dev/null || return 0
  [[ "$BACKUP_DB" == "1" || "$BACKUP_PLUGINS" == "1" ]] || return 0

  local site_id backup_root
  site_id="$(site_id_from_path "$wp_path")"
  backup_root="$BACKUP_DIR/$site_id"

  [[ -d "$backup_root" ]] || return 0

  local phase="backup:purge"

  if [[ "$DRY_RUN" == "1" ]]; then
    echo "[$(ts)] ${pfx}${site} | ${phase} | [DRY] would purge snapshots older than ${BACKUP_RETENTION_DAYS}d in $backup_root" | tee -a "$TEXT_LOG"
    log_json "info" "$site" "$phase" "[DRY] would purge snapshots older than ${BACKUP_RETENTION_DAYS}d"
    return 0
  fi

  local count=0
  while IFS= read -r old_dir; do
    echo "[$(ts)] ${pfx}${site} | ${phase} | Removing old snapshot: $old_dir" | tee -a "$TEXT_LOG"
    log_json "info" "$site" "$phase" "Removing old snapshot: $old_dir"
    rm -rf "$old_dir"
    (( count++ )) || true
  done < <(find "$backup_root" -mindepth 1 -maxdepth 1 -type d -mtime +"$BACKUP_RETENTION_DAYS")

  if [[ $count -gt 0 ]]; then
    echo "[$(ts)] ${pfx}${site} | ${phase} | Purged $count old snapshot(s)." | tee -a "$TEXT_LOG"
    log_json "info" "$site" "$phase" "Purged $count old snapshot(s)"
  fi
}

# ==================================================
# PREMIUM ZIP UPDATES (only if installed)
# ==================================================

premium_update_for_site() {
  local wp_path="$1" pfx="$2" site="$3"

  [[ -d "$PREMIUM_ZIP_DIR" ]] || return 0
  need_cmd unzip || return 0

  shopt -s nullglob
  local zip slug prefix cmd

  for zip in "$PREMIUM_ZIP_DIR"/*.zip; do
    slug="$(get_plugin_slug_from_zip "$zip" || true)"
    [[ -n "$slug" ]] || continue

    prefix="$(wp_prefix "$wp_path")"

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

  shopt -u nullglob
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

  # ---- Pre-update snapshot ----
  # A single timestamp anchors the whole backup for this site+run,
  # so the DB dump and plugin ZIPs share the same directory.
  local stamp bdir
  stamp="$(ts_compact)"
  bdir="$(site_backup_dir "$wp_path" "$stamp")"

  backup_database           "$wp_path" "$pfx" "$site" "$bdir"
  backup_updatable_plugins  "$wp_path" "$pfx" "$site" "$bdir"
  write_backup_manifest     "$wp_path" "$bdir" "$stamp" "$site"

  # ---- Pre-update checks ----
  wp_run "$wp_path" "$pfx" "$site" "precheck" plugin list --update=available
  wp_run "$wp_path" "$pfx" "$site" "precheck" theme  list --update=available
  wp_run "$wp_path" "$pfx" "$site" "precheck" core check-update

  # ---- Updates ----
  wp_run "$wp_path" "$pfx" "$site" "update" plugin update --all
  wp_run "$wp_path" "$pfx" "$site" "update" core   update
  wp_run "$wp_path" "$pfx" "$site" "update" theme  update --all

  premium_update_for_site "$wp_path" "$pfx" "$site"

  # ---- Post-run backup housekeeping ----
  purge_old_backups "$wp_path" "$pfx" "$site"

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

# Load installs into array
mapfile -t INSTALLS < <(awk 'NF' "$INSTALLS_FILE")
TOTAL="${#INSTALLS[@]}"

# Verify backup directory exists before processing any sites
ensure_backup_dir

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

  # Ensure temp files are cleaned up on exit
  trap 'rm -f "$tmp_old_sorted" "$tmp_new_sorted" "$tmp_delta"' EXIT

  awk 'NF' "$INSTALLS_FILE" | sort -u > "$tmp_old_sorted"
  discover_wp_installs        | sort -u > "$tmp_new_sorted"
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
else
  log_plain "[$(ts)] Skipping discovery."
  log_json "info" "GLOBAL" "discover" "User skipped discovery"
fi
