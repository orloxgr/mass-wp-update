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
FLUSH_PERMALINKS_DEFAULT=0      # 1 = soft flush rewrite rules after updates
CLEAR_CACHE_DEFAULT=0           # 1 = clear supported caches after updates
CLEAR_BUILDERS_DEFAULT=0        # 1 = run supported builder regeneration/clear commands after updates

# Binaries
WP_BIN_DEFAULT="/usr/local/bin/wp"
PHP_BIN_DEFAULT=""   # auto-detect
PHP_AUTO_FALLBACK_DEFAULT=1
PHP_ARGS_DEFAULT=(
  "-d" "max_execution_time=999999"
  "-d" "max_input_time=999999"
  "-d" "memory_limit=2048M"
  "-d" "max_input_vars=20000"
  "-d" "post_max_size=2048M"
  "-d" "upload_max_filesize=2048M"
)

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
FLUSH_PERMALINKS="${FLUSH_PERMALINKS:-$FLUSH_PERMALINKS_DEFAULT}"
CLEAR_CACHE="${CLEAR_CACHE:-$CLEAR_CACHE_DEFAULT}"
CLEAR_BUILDERS="${CLEAR_BUILDERS:-$CLEAR_BUILDERS_DEFAULT}"
WP_BIN="${WP_BIN:-$WP_BIN_DEFAULT}"
PHP_BIN="${PHP_BIN:-$PHP_BIN_DEFAULT}"
PHP_AUTO_FALLBACK="${PHP_AUTO_FALLBACK:-$PHP_AUTO_FALLBACK_DEFAULT}"
USE_OWNER_USER="${USE_OWNER_USER:-$USE_OWNER_USER_DEFAULT}"
ALLOW_ROOT="${ALLOW_ROOT:-$ALLOW_ROOT_DEFAULT}"
SKIP_PLUGINS="${SKIP_PLUGINS:-$SKIP_PLUGINS_DEFAULT}"
SKIP_THEMES="${SKIP_THEMES:-$SKIP_THEMES_DEFAULT}"
WP_CLI_COLOR="${WP_CLI_COLOR:-$WP_CLI_COLOR_DEFAULT}"

if [[ "${PHP_ARGS+set}" != "set" || ${#PHP_ARGS[@]} -eq 0 ]]; then
  PHP_ARGS=("${PHP_ARGS_DEFAULT[@]}")
fi

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

  Running without arguments launches a step-by-step wizard.

  If the config file does not exist yet, the wizard first offers to create one
  after checking your environment and proposing sensible defaults.

    Step 1 — Config file setup (first run only)
              Detects existing search roots, PHP/WP-CLI paths, backup directory,
              and recommended execution mode, then offers to save them.

    Step 2 — Backup directory setup
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

  --flush-permalinks  Soft-flush WordPress rewrite rules after updates.

  --clear-cache       Clear supported WordPress caches after updates.

  --clear-builders    Run supported builder cache / asset regeneration commands
                      after updates (more invasive; opt-in).

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
  FLUSH_PERMALINKS     1 = soft flush rewrite rules after updates (default: 0).
  CLEAR_CACHE          1 = clear supported caches after updates (default: 0).
  CLEAR_BUILDERS       1 = run supported builder regeneration commands after updates (default: 0).
  WP_BIN              Path to WP-CLI binary.
  PHP_BIN             Preferred PHP CLI path (auto-detected if empty).
  PHP_AUTO_FALLBACK   1 = try other detected PHP binaries per site if needed.
  PHP_ARGS            Extra PHP CLI flags passed before WP-CLI.
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

  6.  Normal run with a soft permalink flush and cache/builder clearing at the end:

        ./mass-wp-update.sh 2 --flush-permalinks --clear-cache

  7.  Dry run with a custom config to preview a staging environment update:

        ./mass-wp-update.sh 1 --conf /etc/wp-updater/staging.conf --no-color

  8.  Cron-friendly normal run — backups on, no color, custom log dir via conf:

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
OPT_FLUSH_PERMALINKS_OVERRIDE=0
OPT_CLEAR_CACHE_OVERRIDE=0
OPT_CLEAR_BUILDERS_OVERRIDE=0
INTERACTIVE=0   # set to 1 when running the wizard (no args given)

if [[ $# -eq 0 ]]; then
  # ── No arguments: run the interactive wizard ──────────────────────────────
  INTERACTIVE=1
else
  if [[ ! -f "$CONF_FILE" ]]; then
    echo "WARN: Config file not found at $CONF_FILE — using built-in defaults for this run."
  fi
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
      --flush-permalinks)
        OPT_FLUSH_PERMALINKS_OVERRIDE=1; shift
        ;;
      --clear-cache)
        OPT_CLEAR_CACHE_OVERRIDE=1; shift
        ;;
      --clear-builders)
        OPT_CLEAR_BUILDERS_OVERRIDE=1; shift
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
  [[ "$OPT_FLUSH_PERMALINKS_OVERRIDE" == "1" ]] && FLUSH_PERMALINKS=1
  [[ "$OPT_CLEAR_CACHE_OVERRIDE"      == "1" ]] && CLEAR_CACHE=1
  [[ "$OPT_CLEAR_BUILDERS_OVERRIDE"   == "1" ]] && CLEAR_BUILDERS=1
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


trim_whitespace() {
  local s="$1"
  s="${s#${s%%[![:space:]]*}}"
  s="${s%${s##*[![:space:]]}}"
  printf '%s' "$s"
}

config_file_exists() {
  [[ -f "$CONF_FILE" ]]
}

progress_stream() {
  if [[ -w /dev/tty ]]; then
    printf '%s' '/dev/tty'
  else
    printf '%s' '/dev/stderr'
  fi
}

progress_msg() {
  local msg="$1"
  local stream
  stream="$(progress_stream)"
  printf '
[2K%s' "$msg" > "$stream"
}

progress_done() {
  local stream
  stream="$(progress_stream)"
  printf '
' > "$stream"
}

php_cli_version_of_bin() {
  local bin="$1" out=""
  [[ -x "$bin" ]] || return 1
  out="$("$bin" -r 'echo PHP_SAPI,":",PHP_VERSION;' 2>/dev/null || true)"
  [[ "$out" == cli:* ]] || return 1
  printf '%s' "${out#cli:}"
}

detect_php_binaries() {
  local show_progress="${1:-0}"
  local -a candidates=()
  local -A seen=()
  local c version

  add_php_candidate() {
    local bin="$1"
    [[ -n "$bin" && -x "$bin" ]] || return 0

    case "$bin" in
      /usr/share/cagefs/*|/usr/share/cagefs-skeleton/*|/usr/share/cagefs-skeleton.old/*)
        return 0
        ;;
    esac

    [[ -n "${seen[$bin]+x}" ]] && return 0

    version="$(php_cli_version_of_bin "$bin" || true)"
    [[ -n "$version" ]] || return 0

    seen["$bin"]=1
    candidates+=("$bin")
  }

  [[ -n "${PHP_BIN:-}" ]] && add_php_candidate "$PHP_BIN"
  c="$(command -v php 2>/dev/null || true)"
  [[ -n "$c" ]] && add_php_candidate "$c"

  local patterns=(
    "/usr/local/bin/php"
    "/usr/bin/php"
    "/bin/php"
    "/usr/local/php*/bin/php"
    "/usr/local/php[0-9]*/bin/php"
    "/usr/local/cwp/php*/bin/php"
    "/opt/plesk/php/*/bin/php"
    "/opt/cpanel/ea-php*/root/usr/bin/php"
    "/opt/cpanel/ea-php*/root/bin/php"
    "/opt/alt/php*/usr/bin/php"
    "/usr/local/cpanel/3rdparty/bin/php"
    "/usr/local/cpanel/3rdparty/php/*/bin/php"
    "/usr/local/lsws/lsphp*/bin/php"
  )

  local p match
  for p in "${patterns[@]}"; do
    while IFS= read -r match; do
      add_php_candidate "$match"
    done < <(compgen -G "$p" || true)
  done

  if [[ "$show_progress" == "1" ]]; then
    progress_msg "  Detecting PHP binaries on this server..."
  fi
  while IFS= read -r match; do
    [[ "$match" =~ /bin/php$ ]] || continue
    add_php_candidate "$match"
  done < <(find /usr /usr/local /opt -type f -path '*/bin/php' -print 2>/dev/null || true)
  if [[ "$show_progress" == "1" ]]; then
    progress_done
  fi

  printf '%s
' "${candidates[@]}"
}

php_version_of_bin() {
  local bin="$1"
  [[ -x "$bin" ]] || return 1
  php_cli_version_of_bin "$bin" 2>/dev/null || true
}

detect_php_bin_candidate() {
  local first=""
  first="$(detect_php_binaries | head -n1 || true)"
  printf '%s' "$first"
}

detect_wp_bin_candidate() {
  local candidates=()
  [[ -n "${WP_BIN:-}" ]] && candidates+=("$WP_BIN")
  local found
  found="$(command -v wp 2>/dev/null || true)"
  [[ -n "$found" ]] && candidates+=("$found")
  candidates+=("/usr/local/bin/wp" "/usr/bin/wp")

  local c
  for c in "${candidates[@]}"; do
    [[ -n "$c" && -x "$c" ]] && { printf '%s' "$c"; return 0; }
  done
  printf '%s' "${WP_BIN_DEFAULT}"
}

detect_search_roots_candidates() {
  local roots=()
  local r
  for r in "${SEARCH_ROOTS_DEFAULT[@]}"; do
    [[ -d "$r" ]] && roots+=("$r")
  done
  if [[ ${#roots[@]} -eq 0 ]]; then
    roots=("${SEARCH_ROOTS_DEFAULT[@]}")
  fi
  printf '%s
' "${roots[@]}"
}

detect_backup_dir_candidate() {
  local candidates=()
  if [[ "$(id -u)" -eq 0 ]]; then
    candidates+=("/var/backups/mass-wp-update")
  fi
  candidates+=("$BACKUP_DIR_DEFAULT")

  local c parent
  for c in "${candidates[@]}"; do
    parent="$(dirname "$c")"
    if [[ -d "$c" ]]; then
      printf '%s' "$c"
      return 0
    fi
    if [[ -d "$parent" && -w "$parent" ]]; then
      printf '%s' "$c"
      return 0
    fi
  done
  printf '%s' "$BACKUP_DIR_DEFAULT"
}

wizard_out() {
  local line
  for line in "$@"; do
    if [[ -w /dev/tty ]]; then
      printf '%s
' "$line" > /dev/tty
    else
      printf '%s
' "$line" >&2
    fi
  done
}

wizard_prompt_read() {
  local prompt="$1" answer=""
  if [[ -w /dev/tty ]]; then
    printf '%s' "$prompt" > /dev/tty
    IFS= read -r answer < /dev/tty
  else
    printf '%s' "$prompt" >&2
    IFS= read -r answer
  fi
  printf '%s' "$answer"
}

prompt_with_default() {
  local prompt="$1" default="$2" value_kind="${3:-value}" answer
  while true; do
    wizard_out "  $prompt"
    if [[ -n "$default" ]]; then
      wizard_out "    Press Enter to keep the autodiscovered $value_kind:"
      wizard_out "    $default"
    else
      wizard_out "    Enter a $value_kind."
    fi
    answer="$(wizard_prompt_read '  > ')"
    if [[ -z "$answer" ]]; then
      printf '%s' "$default"
      return 0
    fi
    case "$answer" in
      Y|y|N|n)
        wizard_out "  This field expects a $value_kind, not Y/N."
        wizard_out "  Press Enter to keep the autodiscovered value, or type a custom one."
        ;;
      *)
        printf '%s' "$answer"
        return 0
        ;;
    esac
  done
}

prompt_yes_no_default() {
  local prompt="$1" default="$2" answer
  while true; do
    wizard_out "  $prompt"
    wizard_out "    Type Y or N only. Press Enter to keep the default: $default"
    answer="$(wizard_prompt_read '  > ')"
    answer="${answer:-$default}"
    case "$answer" in
      Y|y|N|n) printf '%s' "$answer"; return 0 ;;
      *) wizard_out "  Please type Y or N only." ;;
    esac
  done
}

prompt_number_choice() {
  local prompt="$1" default="$2"; shift 2
  local -a valid=("$@")
  local answer opt
  while true; do
    wizard_out "  $prompt"
    wizard_out "    Valid options: ${valid[*]}. Press Enter to keep the default: $default"
    answer="$(wizard_prompt_read '  > ')"
    answer="${answer:-$default}"
    for opt in "${valid[@]}"; do
      [[ "$answer" == "$opt" ]] && { printf '%s' "$answer"; return 0; }
    done
    wizard_out "  Please choose one of: ${valid[*]}"
  done
}

prompt_php_bin_choice() {
  local default_bin="$1"
  local -a bins=() valid=()
  local bin version idx default_idx choice custom

  while IFS= read -r bin; do
    [[ -n "$bin" ]] && bins+=("$bin")
  done < <(detect_php_binaries 1)

  if [[ ${#bins[@]} -eq 0 ]]; then
    custom="$(prompt_with_default 'No PHP binaries were autodiscovered. Type a PHP binary path.' "$default_bin" 'PHP binary path')"
    printf '%s' "$custom"
    return 0
  fi

  default_idx=1
  wizard_out '  PHP binaries found on this server:'
  for idx in "${!bins[@]}"; do
    bin="${bins[$idx]}"
    version="$(php_version_of_bin "$bin")"
    [[ -n "$version" ]] || version='unknown'
    [[ "$bin" == "$default_bin" ]] && default_idx=$((idx+1))
    wizard_out "    $((idx+1))) $bin (PHP $version)"
  done
  wizard_out '    0) Type a custom PHP binary path'

  valid=(0)
  for idx in "${!bins[@]}"; do
    valid+=("$((idx+1))")
  done

  choice="$(prompt_number_choice 'Choose the global PHP binary for WP-CLI.' "$default_idx" "${valid[@]}")"
  if [[ "$choice" == '0' ]]; then
    custom="$(prompt_with_default 'Type a custom PHP binary path.' "$default_bin" 'PHP binary path')"
    printf '%s' "$custom"
    return 0
  fi

  printf '%s' "${bins[$((choice-1))]}"
}

write_config_file() {
  local conf_path="$1"
  local detected_php="$2"
  local detected_wp="$3"
  local backup_dir="$4"
  local use_owner_user="$5"
  local allow_root="$6"
  local search_roots_csv="$7"

  local conf_dir
  conf_dir="$(dirname "$conf_path")"
  mkdir -p "$conf_dir"

  local roots_block=""
  local IFS=','
  local root
  read -r -a _roots <<< "$search_roots_csv"
  for root in "${_roots[@]}"; do
    root="$(trim_whitespace "$root")"
    [[ -n "$root" ]] || continue
    printf -v roots_block '%s  "%s"\n' "$roots_block" "$root"
  done
  unset IFS

  cat > "$conf_path" <<EOF
# mass-wp-update.conf
# Generated by the interactive setup wizard on $(date '+%Y-%m-%d %H:%M:%S')
# Review and adjust as needed.

# --------------------------------------------------
# SEARCH PATHS
# --------------------------------------------------
SEARCH_ROOTS=(
${roots_block})

CUSTOM_ROOTS_FILE="$BASE_DIR/custom-roots.txt"

# --------------------------------------------------
# FILES & DIRECTORIES
# --------------------------------------------------
INSTALLS_FILE="$BASE_DIR/wpinstalls.txt"
PREMIUM_ZIP_DIR="$BASE_DIR/premium-zips"
LOG_DIR="$BASE_DIR/logs"
BACKUP_DIR="$backup_dir"

# --------------------------------------------------
# BACKUP SETTINGS
# --------------------------------------------------
BACKUP_DB=0
BACKUP_PLUGINS=0
BACKUP_RETENTION_DAYS=30
FLUSH_PERMALINKS=0
CLEAR_CACHE=0
CLEAR_BUILDERS=0

# --------------------------------------------------
# BINARIES
# --------------------------------------------------
WP_BIN="$detected_wp"
PHP_BIN="$detected_php"
PHP_AUTO_FALLBACK=1

# --------------------------------------------------
# EXECUTION BEHAVIOR
# --------------------------------------------------
USE_OWNER_USER=$use_owner_user
ALLOW_ROOT=$allow_root

# --------------------------------------------------
# WP-CLI OPTIONS
# --------------------------------------------------
SKIP_PLUGINS=1
SKIP_THEMES=1
WP_CLI_COLOR=1
EOF
}

interactive_config_setup() {
  [[ -f "$CONF_FILE" ]] && return 0

  echo "  STEP 1 of 5 — First-run config setup"
  echo ""
  echo "  No config file was found at: $CONF_FILE"
  echo "  I can create one now using checked defaults from this server."
  echo ""

  local create_ans
  create_ans="$(prompt_yes_no_default 'Create a config file now?' 'Y')"
  if [[ ! "$create_ans" =~ ^[Yy]$ ]]; then
    echo "  Skipped. The script will continue with built-in defaults for this run."
    echo ""
    return 0
  fi

  local detected_php detected_wp detected_backup_dir detected_use_owner detected_allow_root
  local roots_preview roots_input backup_input php_input wp_input use_owner_input

  detected_php="$(detect_php_bin_candidate)"
  detected_wp="$(detect_wp_bin_candidate)"
  detected_backup_dir="$(detect_backup_dir_candidate)"

  if [[ "$(id -u)" -eq 0 ]] && command -v sudo >/dev/null 2>&1; then
    detected_use_owner=1
    detected_allow_root=0
  else
    detected_use_owner=0
    detected_allow_root=1
  fi

  roots_preview="$(detect_search_roots_candidates | paste -sd, - | sed 's/,/, /g')"
  roots_input="$(prompt_with_default 'Search roots (comma-separated paths). Press Enter to keep the autodiscovered paths, or type custom paths.' "$roots_preview" 'path list')"
  roots_input="$(trim_whitespace "$roots_input")"
  [[ -n "$roots_input" ]] || roots_input="$roots_preview"

  backup_input="$(prompt_with_default 'Backup directory. Press Enter to keep the autodiscovered path, or type a custom path.' "$detected_backup_dir" 'path')"
  backup_input="$(trim_whitespace "$backup_input")"
  [[ -n "$backup_input" ]] || backup_input="$detected_backup_dir"

  php_input="$(prompt_php_bin_choice "$detected_php")"
  php_input="$(trim_whitespace "$php_input")"
  [[ -n "$php_input" ]] || php_input="$detected_php"

  wp_input="$(prompt_with_default 'WP-CLI binary path. Press Enter to keep the autodiscovered path, or type a custom path.' "$detected_wp" 'path')"
  wp_input="$(trim_whitespace "$wp_input")"
  [[ -n "$wp_input" ]] || wp_input="$detected_wp"

  local owner_default owner_ans allow_root_value
  [[ "$detected_use_owner" == "1" ]] && owner_default='Y' || owner_default='N'
  owner_ans="$(prompt_yes_no_default 'Run WP-CLI as each site owner (recommended)?' "$owner_default")"
  if [[ "$owner_ans" =~ ^[Yy]$ ]]; then
    use_owner_input=1
    allow_root_value=0
  else
    use_owner_input=0
    allow_root_value=1
  fi

  if [[ ! -x "$php_input" ]]; then
    echo "  ⚠  PHP binary is not executable: $php_input"
  fi
  if [[ ! -x "$wp_input" ]]; then
    echo "  ⚠  WP-CLI binary is not executable: $wp_input"
  fi

  local backup_parent
  backup_parent="$(dirname "$backup_input")"
  if [[ ! -d "$backup_input" && ! -w "$backup_parent" ]]; then
    echo "  ⚠  Backup parent is not writable right now: $backup_parent"
    echo "     If this path stays unchanged, backup creation may fail later."
  fi

  write_config_file "$CONF_FILE" "$php_input" "$wp_input" "$backup_input" "$use_owner_input" "$allow_root_value" "$roots_input"

  echo ""
  echo "  ✔  Config file created: $CONF_FILE"
  echo ""

  # Reload the freshly created config so the current run uses it.
  # shellcheck disable=SC1090
  source "$CONF_FILE"

  # Re-apply runtime variables derived from config.
  INSTALLS_FILE="${INSTALLS_FILE:-$INSTALLS_FILE_DEFAULT}"
  CUSTOM_ROOTS_FILE="${CUSTOM_ROOTS_FILE:-$CUSTOM_ROOTS_FILE_DEFAULT}"
  PREMIUM_ZIP_DIR="${PREMIUM_ZIP_DIR:-$PREMIUM_ZIP_DIR_DEFAULT}"
  LOG_DIR="${LOG_DIR:-$LOG_DIR_DEFAULT}"
  BACKUP_DIR="${BACKUP_DIR:-$BACKUP_DIR_DEFAULT}"
  BACKUP_DB="${BACKUP_DB:-$BACKUP_DB_DEFAULT}"
  BACKUP_PLUGINS="${BACKUP_PLUGINS:-$BACKUP_PLUGINS_DEFAULT}"
  BACKUP_RETENTION_DAYS="${BACKUP_RETENTION_DAYS:-$BACKUP_RETENTION_DAYS_DEFAULT}"
  FLUSH_PERMALINKS="${FLUSH_PERMALINKS:-$FLUSH_PERMALINKS_DEFAULT}"
  CLEAR_CACHE="${CLEAR_CACHE:-$CLEAR_CACHE_DEFAULT}"
  CLEAR_BUILDERS="${CLEAR_BUILDERS:-$CLEAR_BUILDERS_DEFAULT}"
  WP_BIN="${WP_BIN:-$WP_BIN_DEFAULT}"
  PHP_BIN="${PHP_BIN:-$PHP_BIN_DEFAULT}"
  PHP_AUTO_FALLBACK="${PHP_AUTO_FALLBACK:-$PHP_AUTO_FALLBACK_DEFAULT}"
  USE_OWNER_USER="${USE_OWNER_USER:-$USE_OWNER_USER_DEFAULT}"
  ALLOW_ROOT="${ALLOW_ROOT:-$ALLOW_ROOT_DEFAULT}"
  SKIP_PLUGINS="${SKIP_PLUGINS:-$SKIP_PLUGINS_DEFAULT}"
  SKIP_THEMES="${SKIP_THEMES:-$SKIP_THEMES_DEFAULT}"
  WP_CLI_COLOR="${WP_CLI_COLOR:-$WP_CLI_COLOR_DEFAULT}"
}

interactive_wizard() {
  echo ""
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo "  mass-wp-update — interactive setup"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo ""

  interactive_config_setup

  # ------------------------------------------------------------------
  # Step 2 — Backup directory
  # Ask whenever the current backup directory does not exist yet.
  # ------------------------------------------------------------------
  local configured_backup_dir
  configured_backup_dir="$(grep -E '^[[:space:]]*BACKUP_DIR=' "$CONF_FILE" 2>/dev/null | tail -1 | cut -d= -f2- | tr -d '"'"'" | xargs || true)"

  if [[ ! -d "$BACKUP_DIR" ]]; then
    echo "  STEP 2 of 5 — Backup directory"
    echo ""
    echo "  The configured backup directory does not exist yet."
    echo "  Default location: $BACKUP_DIR"
    echo ""
    local ans_bdir
    ans_bdir="$(prompt_yes_no_default 'Create this backup directory now and save it to the config file?' 'Y')"

    if [[ "$ans_bdir" =~ ^[Yy]$ ]]; then
      if mkdir -p "$BACKUP_DIR" 2>/dev/null; then
        chmod 755 "$BACKUP_DIR" 2>/dev/null || true
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
  echo "  STEP 3 of 5 — Run mode"
  echo ""
  echo "    1)  Dry run  — show what would be updated, make no changes"
  echo "    2)  Real run — apply all updates"
  echo ""
  local ans_mode
  ans_mode="$(prompt_number_choice 'Choose mode.' '1' 1 2)"
  case "$ans_mode" in
    1) MODE=1; DRY_RUN=1; echo "  ✔  Dry run selected." ;;
    2) MODE=2; DRY_RUN=0; echo "  ✔  Real run selected." ;;
  esac
  echo ""

  # ------------------------------------------------------------------
  # Step 3 — Backup options
  # ------------------------------------------------------------------
  echo "  STEP 4 of 5 — Backups before updating"
  echo ""
  echo "    1)  Database only"
  echo "    2)  Plugins only   (archives each updatable plugin as a versioned ZIP)"
  echo "    3)  Database AND plugins"
  echo "    4)  No backups"
  echo ""
  local ans_backup
  ans_backup="$(prompt_number_choice 'Choose backup option.' '3' 1 2 3 4)"
  case "$ans_backup" in
    1) BACKUP_DB=1; BACKUP_PLUGINS=0; echo "  ✔  Database backup enabled." ;;
    2) BACKUP_DB=0; BACKUP_PLUGINS=1; echo "  ✔  Plugin backup enabled." ;;
    3) BACKUP_DB=1; BACKUP_PLUGINS=1; echo "  ✔  Database and plugin backups enabled." ;;
    4) BACKUP_DB=0; BACKUP_PLUGINS=0; echo "  ✔  No backups — updates will run unguarded." ;;
  esac
  echo ""

  # ------------------------------------------------------------------
  # Step 4 — Optional post-update maintenance
  # ------------------------------------------------------------------
  echo "  STEP 5 of 5 — Optional post-update maintenance"
  echo ""

  local ans_flush ans_cache ans_builders
  ans_flush="$(prompt_yes_no_default 'Soft flush permalinks after updates?' 'N')"
  [[ "$ans_flush" =~ ^[Yy]$ ]] && FLUSH_PERMALINKS=1 || FLUSH_PERMALINKS=0

  ans_cache="$(prompt_yes_no_default 'Clear supported caches after updates?' 'N')"
  [[ "$ans_cache" =~ ^[Yy]$ ]] && CLEAR_CACHE=1 || CLEAR_CACHE=0

  ans_builders="$(prompt_yes_no_default 'Run supported builder regeneration commands after updates?' 'N')"
  [[ "$ans_builders" =~ ^[Yy]$ ]] && CLEAR_BUILDERS=1 || CLEAR_BUILDERS=0
  echo ""

  # ------------------------------------------------------------------
  # Summary before proceeding
  # ------------------------------------------------------------------
  local mode_label backup_label maintenance_label
  [[ "$DRY_RUN" == "1" ]] && mode_label="Dry run (no changes)" || mode_label="Real run"
  case "${BACKUP_DB}${BACKUP_PLUGINS}" in
    10) backup_label="Database only" ;;
    01) backup_label="Plugins only" ;;
    11) backup_label="Database + plugins" ;;
    *)  backup_label="None" ;;
  esac

  maintenance_label="None"
  maintenance_parts=()
  [[ "$FLUSH_PERMALINKS" == "1" ]] && maintenance_parts+=("Soft flush permalinks")
  [[ "$CLEAR_CACHE" == "1" ]] && maintenance_parts+=("Clear cache")
  [[ "$CLEAR_BUILDERS" == "1" ]] && maintenance_parts+=("Clear builders")
  if [[ ${#maintenance_parts[@]} -gt 0 ]]; then
    maintenance_label="$(IFS=' + '; echo "${maintenance_parts[*]}")"
  fi

  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo "  Ready to run"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo ""
  echo "  Mode    : $mode_label"
  echo "  Backups : $backup_label"
  echo "  Extras  : $maintenance_label"
  [[ "$BACKUP_DB" == "1" || "$BACKUP_PLUGINS" == "1" ]] &&     echo "  Backup  : $BACKUP_DIR"
  echo ""

  local ans_confirm
  ans_confirm="$(prompt_yes_no_default 'Proceed?' 'Y')"
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

# Commands that must load plugins/themes (rewrite flush, cache plugin CLIs)
WP_CLI_OPTS_LOADED=()
[[ "$WP_CLI_COLOR" == "1" ]] && WP_CLI_OPTS_LOADED+=(--color)

declare -A SITE_PHP_BIN_CACHE=()
declare -A SITE_PHP_BIN_CACHE_LOADED=()
declare -a PHP_BIN_CANDIDATES=()

init_php_bin_candidates() {
  local -A seen=()
  local bin
  PHP_BIN_CANDIDATES=()
  if [[ -n "${PHP_BIN:-}" && -x "${PHP_BIN:-}" ]]; then
    seen["$PHP_BIN"]=1
    PHP_BIN_CANDIDATES+=("$PHP_BIN")
  fi
  while IFS= read -r bin; do
    [[ -n "$bin" && -x "$bin" ]] || continue
    [[ -n "${seen[$bin]+x}" ]] && continue
    seen["$bin"]=1
    PHP_BIN_CANDIDATES+=("$bin")
  done < <(detect_php_binaries)
}

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

init_php_bin_candidates

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

shell_join() {
  local out="" q arg
  for arg in "$@"; do
    printf -v q '%q' "$arg"
    out+=" $q"
  done
  printf '%s' "${out# }"
}


# Run command strings without loading login/profile scripts.
# This avoids host-panel banners (e.g. CWP MOTD/profile output)
# from polluting structured command output such as:
#   wp core version
#   wp plugin list --format=csv
shell_exec() {
  local cmd="$1"
  bash --noprofile --norc -c "$cmd"
}

shell_exec_stream() {
  local cmd="$1"
  if need_cmd stdbuf; then
    stdbuf -oL -eL bash --noprofile --norc -c "$cmd"
  else
    bash --noprofile --norc -c "$cmd"
  fi
}

first_nonempty_line() {
  awk 'NF { sub(/\r$/, ""); print; exit }'
}

sanitize_token() {
  tr -cd '[:alnum:]._+-'
}

wp_command_shell_join() {
  local php_bin="$1"; shift
  local wp_path="$1"; shift
  local loaded="${1:-0}"; shift
  local -a cli_opts=()
  if [[ "$loaded" == "1" ]]; then
    cli_opts=("${WP_CLI_OPTS_LOADED[@]}")
  else
    cli_opts=("${WP_CLI_OPTS[@]}")
  fi
  shell_join "$php_bin" "${PHP_ARGS[@]}" "$WP_BIN" "--path=$wp_path" "${cli_opts[@]}" "$@"
}

probe_wp_with_php_bin() {
  local php_bin="$1" wp_path="$2" prefix="$3"
  local cmd
  # Force a real WordPress load while still skipping plugins/themes.
  # `core version` can be too weak and may succeed on PHP versions that later
  # fail during actual update commands.
  cmd="${prefix:+$prefix }$(wp_command_shell_join "$php_bin" "$wp_path" 0 option get home --quiet)"
  shell_exec "$cmd" </dev/null >/dev/null 2>&1
}

probe_wp_with_php_bin_loaded() {
  local php_bin="$1" wp_path="$2" prefix="$3"
  local cmd
  cmd="${prefix:+$prefix }$(wp_command_shell_join "$php_bin" "$wp_path" 1 option get home --quiet)"
  shell_exec "$cmd" </dev/null >/dev/null 2>&1
}

resolve_php_bin_for_site_context() {
  local wp_path="$1" pfx="$2" site="$3" phase="$4" loaded="${5:-0}"
  local prefix php_bin chosen="" cache_key note

  if [[ "$loaded" == "1" ]]; then
    if [[ -n "${SITE_PHP_BIN_CACHE_LOADED[$wp_path]+x}" && -x "${SITE_PHP_BIN_CACHE_LOADED[$wp_path]}" ]]; then
      printf '%s' "${SITE_PHP_BIN_CACHE_LOADED[$wp_path]}"
      return 0
    fi
  else
    if [[ -n "${SITE_PHP_BIN_CACHE[$wp_path]+x}" && -x "${SITE_PHP_BIN_CACHE[$wp_path]}" ]]; then
      printf '%s' "${SITE_PHP_BIN_CACHE[$wp_path]}"
      return 0
    fi
  fi

  prefix="$(wp_prefix "$wp_path")"

  if [[ -n "${PHP_BIN:-}" && -x "${PHP_BIN:-}" ]]; then
    if [[ "$loaded" == "1" ]]; then
      probe_wp_with_php_bin_loaded "$PHP_BIN" "$wp_path" "$prefix" && chosen="$PHP_BIN"
    else
      probe_wp_with_php_bin "$PHP_BIN" "$wp_path" "$prefix" && chosen="$PHP_BIN"
    fi
  fi

  if [[ -z "$chosen" && "$PHP_AUTO_FALLBACK" == "1" ]]; then
    for php_bin in "${PHP_BIN_CANDIDATES[@]}"; do
      [[ "$php_bin" == "${PHP_BIN:-}" ]] && continue
      if [[ "$loaded" == "1" ]]; then
        if probe_wp_with_php_bin_loaded "$php_bin" "$wp_path" "$prefix"; then
          chosen="$php_bin"
          break
        fi
      else
        if probe_wp_with_php_bin "$php_bin" "$wp_path" "$prefix"; then
          chosen="$php_bin"
          break
        fi
      fi
    done
  fi

  if [[ -z "$chosen" ]]; then
    if [[ "$loaded" == "1" ]]; then
      printf '%s\n' "[$(ts)] ${pfx}${site} | ${phase} | WARN: No PHP binary could load WordPress with plugins/themes for this site. Skipping this loaded WP-CLI task." | tee -a "$TEXT_LOG" >&2
      log_json "warn" "$site" "$phase" "No PHP binary could load WordPress with plugins/themes for this site; skipping loaded task"
      return 1
    fi

    chosen="${PHP_BIN:-$(command -v php 2>/dev/null || true)}"
    if [[ -n "$chosen" ]]; then
      printf '%s\n' "[$(ts)] ${pfx}${site} | ${phase} | WARN: No working PHP binary was auto-confirmed for this site. Using configured/default PHP: $chosen" | tee -a "$TEXT_LOG" >&2
      log_json "warn" "$site" "$phase" "No working PHP binary auto-confirmed; using $chosen"
    fi
  elif [[ "$chosen" != "${PHP_BIN:-}" ]]; then
    if [[ "$loaded" == "1" ]]; then
      note='plugins/themes loaded'
    else
      note='core-only probes'
    fi
    printf '%s\n' "[$(ts)] ${pfx}${site} | ${phase} | INFO: Falling back to site-compatible PHP binary ($note): $chosen" | tee -a "$TEXT_LOG" >&2
    log_json "info" "$site" "$phase" "Falling back to site-compatible PHP binary ($note): $chosen"
  fi

  if [[ -n "$chosen" ]]; then
    if [[ "$loaded" == "1" ]]; then
      SITE_PHP_BIN_CACHE_LOADED["$wp_path"]="$chosen"
    else
      SITE_PHP_BIN_CACHE["$wp_path"]="$chosen"
    fi
  fi

  printf '%s' "$chosen"
}

resolve_php_bin_for_site() {
  resolve_php_bin_for_site_context "$1" "$2" "$3" "$4" 0
}

resolve_php_bin_for_site_loaded() {
  resolve_php_bin_for_site_context "$1" "$2" "$3" "$4" 1
}

# ==================================================
# DISCOVERY
# ==================================================

discover_wp_installs() {
  local roots=()
  local scan_targets=()
  local root child
  local total=0
  local idx=0
  local pct=0
  local has_children=0

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
    has_children=0

    while IFS= read -r -d '' child; do
      scan_targets+=("$child")
      has_children=1
    done < <(find "$root" -mindepth 1 -maxdepth 1 -type d -print0 2>/dev/null || true)

    if [[ "$has_children" -eq 0 ]]; then
      scan_targets+=("$root")
    fi
  done

  total=${#scan_targets[@]}
  if [[ "$total" -eq 0 ]]; then
    return 0
  fi

  progress_msg "  Discovering WordPress installs... 0% (0/${total})"

  for root in "${scan_targets[@]}"; do
    idx=$((idx + 1))
    pct=$(( idx * 100 / total ))
    progress_msg "  Discovering WordPress installs... ${pct}% (${idx}/${total}) — ${root}"

    find "$root"       -type d \( -name wp-content -o -name node_modules -o -name vendor -o -name .git \) -prune -o       -type f -name "wp-config.php" -print 2>/dev/null
  done |
  while IFS= read -r cfg; do
    site="${cfg%/wp-config.php}"
    [[ -f "$site/wp-load.php" && -d "$site/wp-content" ]] && printf '%s
' "$site"
  done | sort -u

  progress_done
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
# WP RUNNER (timestamped lines + JSONL + CORRECTED)
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

  local php_bin joined_args cmd
  php_bin="$(resolve_php_bin_for_site "$wp_path" "$pfx" "$site" "$phase")"
  if [[ -z "$php_bin" ]]; then
    local msg="WARN: No usable PHP binary resolved for this site. Skipping wp command."
    echo "[$(ts)] ${pfx}${site} | ${phase} | $msg" | tee -a "$TEXT_LOG"
    log_json "warn" "$site" "$phase" "$msg"
    return 0
  fi
  joined_args="$(wp_command_shell_join "$php_bin" "$wp_path" 0 "$@")"
  cmd="${prefix:+$prefix }$joined_args"

  if [[ "$DRY_RUN" == "1" ]]; then
    echo "[$(ts)] ${pfx}${site} | ${phase} | [DRY] $cmd" | tee -a "$TEXT_LOG"
    log_json "info" "$site" "$phase" "[DRY] $cmd"
    return 0
  fi

  echo "[$(ts)] ${pfx}${site} | ${phase} | [RUN] $cmd" | tee -a "$TEXT_LOG"
  log_json "info" "$site" "$phase" "[RUN] $cmd"

  local rc=0
  if need_cmd stdbuf; then
    shell_exec_stream "$cmd" </dev/null 2>&1 | while IFS= read -r line; do
      echo "[$(ts)] ${pfx}${site} | ${phase} | $line" | tee -a "$TEXT_LOG"
      log_json "info" "$site" "$phase" "$line"
    done
    rc=${PIPESTATUS[0]:-0}
  else
    shell_exec_stream "$cmd" </dev/null 2>&1 | while IFS= read -r line; do
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

wp_run_loaded() {
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

  local php_bin joined_args cmd
  php_bin="$(resolve_php_bin_for_site_loaded "$wp_path" "$pfx" "$site" "$phase")"
  if [[ -z "$php_bin" ]]; then
    return 0
  fi
  joined_args="$(wp_command_shell_join "$php_bin" "$wp_path" 1 "$@")"
  cmd="${prefix:+$prefix }$joined_args"

  if [[ "$DRY_RUN" == "1" ]]; then
    echo "[$(ts)] ${pfx}${site} | ${phase} | [DRY] $cmd" | tee -a "$TEXT_LOG"
    log_json "info" "$site" "$phase" "[DRY] $cmd"
    return 0
  fi

  echo "[$(ts)] ${pfx}${site} | ${phase} | [RUN] $cmd" | tee -a "$TEXT_LOG"
  log_json "info" "$site" "$phase" "[RUN] $cmd"

  local rc=0
  if need_cmd stdbuf; then
    shell_exec_stream "$cmd" </dev/null 2>&1 | while IFS= read -r line; do
      echo "[$(ts)] ${pfx}${site} | ${phase} | $line" | tee -a "$TEXT_LOG"
      log_json "info" "$site" "$phase" "$line"
    done
    rc=${PIPESTATUS[0]:-0}
  else
    shell_exec_stream "$cmd" </dev/null 2>&1 | while IFS= read -r line; do
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

plugin_is_installed() {
  local wp_path="$1"
  local slug="$2"
  local prefix php_bin cmd
  prefix="$(wp_prefix "$wp_path")"
  php_bin="$(resolve_php_bin_for_site "$wp_path" "" "$wp_path" "probe")"
  [[ -n "$php_bin" ]] || return 1
  cmd="${prefix:+$prefix }$(wp_command_shell_join "$php_bin" "$wp_path" 0 plugin is-installed "$slug")"

  shell_exec "$cmd" </dev/null >/dev/null 2>&1
}

plugin_dir_exists() {
  local wp_path="$1"
  local plugin_dir="$2"
  [[ -d "$wp_path/wp-content/plugins/$plugin_dir" ]]
}

theme_dir_exists() {
  local wp_path="$1"
  local theme_dir="$2"
  [[ -d "$wp_path/wp-content/themes/$theme_dir" ]]
}

wp_command_exists_loaded() {
  local wp_path="$1"
  local command_name="$2"
  local prefix php_bin cmd
  prefix="$(wp_prefix "$wp_path")"
  php_bin="$(resolve_php_bin_for_site_loaded "$wp_path" "" "$wp_path" "probe-loaded")"
  [[ -n "$php_bin" ]] || return 1
  cmd="${prefix:+$prefix }$(wp_command_shell_join "$php_bin" "$wp_path" 1 help "$command_name")"

  shell_exec "$cmd" </dev/null >/dev/null 2>&1
}

flush_permalinks_soft() {
  local wp_path="$1" pfx="$2" site="$3"

  [[ "$FLUSH_PERMALINKS" == "1" ]] || return 0

  wp_run_loaded "$wp_path" "$pfx" "$site" "rewrite" rewrite flush
}

clear_site_builders() {
  local wp_path="$1" pfx="$2" site="$3"

  [[ "$CLEAR_BUILDERS" == "1" ]] || return 0

  local did_anything=0
  local saw_unsupported=0

  if plugin_is_installed "$wp_path" "elementor" && wp_command_exists_loaded "$wp_path" "elementor"; then
    did_anything=1
    wp_run_loaded "$wp_path" "$pfx" "$site" "builder" elementor flush-css --regenerate
  fi

  if plugin_is_installed "$wp_path" "elementor-pro" && wp_command_exists_loaded "$wp_path" "elementor-pro"; then
    did_anything=1
    wp_run_loaded "$wp_path" "$pfx" "$site" "builder" elementor-pro theme-builder clear-conditions
  fi

  if wp_command_exists_loaded "$wp_path" "breakdance"; then
    did_anything=1
    wp_run_loaded "$wp_path" "$pfx" "$site" "builder" breakdance clear_cache
  fi

  if wp_command_exists_loaded "$wp_path" "beaver"; then
    did_anything=1
    wp_run_loaded "$wp_path" "$pfx" "$site" "builder" beaver clearcache
  fi

  if plugin_dir_exists "$wp_path" "oxygen"; then
    saw_unsupported=1
    echo "[$(ts)] ${pfx}${site} | builder | Oxygen detected; official docs expose a manual Regenerate CSS Cache tool, but no supported WP-CLI command is used here. Skipping." | tee -a "$TEXT_LOG"
    log_json "info" "$site" "builder" "Oxygen detected; manual Regenerate CSS Cache exists, but no supported WP-CLI command is used here. Skipping"
  fi

  if plugin_dir_exists "$wp_path" "js_composer"; then
    saw_unsupported=1
    echo "[$(ts)] ${pfx}${site} | builder | WPBakery detected; no documented WP-CLI cache/regeneration command was added. Skipping." | tee -a "$TEXT_LOG"
    log_json "info" "$site" "builder" "WPBakery detected; no documented WP-CLI cache/regeneration command was added. Skipping"
  fi

  if plugin_dir_exists "$wp_path" "bold-page-builder"; then
    saw_unsupported=1
    echo "[$(ts)] ${pfx}${site} | builder | Bold Builder detected; no documented WP-CLI cache/regeneration command was added. Skipping." | tee -a "$TEXT_LOG"
    log_json "info" "$site" "builder" "Bold Builder detected; no documented WP-CLI cache/regeneration command was added. Skipping"
  fi

  if theme_dir_exists "$wp_path" "Divi" || theme_dir_exists "$wp_path" "Extra"; then
    saw_unsupported=1
    echo "[$(ts)] ${pfx}${site} | builder | Divi/Extra detected; manual/programmatic cache clearing exists in vendor docs, but no stable WP-CLI command is used here. Skipping." | tee -a "$TEXT_LOG"
    log_json "info" "$site" "builder" "Divi/Extra detected; manual/programmatic cache clearing exists, but no stable WP-CLI command is used here. Skipping"
  fi

  if theme_dir_exists "$wp_path" "bricks"; then
    saw_unsupported=1
    echo "[$(ts)] ${pfx}${site} | builder | Bricks detected; no documented WP-CLI cache/regeneration command was added. Skipping." | tee -a "$TEXT_LOG"
    log_json "info" "$site" "builder" "Bricks detected; no documented WP-CLI cache/regeneration command was added. Skipping"
  fi

  if [[ "$did_anything" == "0" && "$saw_unsupported" == "0" ]]; then
    echo "[$(ts)] ${pfx}${site} | builder | No supported builder command detected; skipping." | tee -a "$TEXT_LOG"
    log_json "info" "$site" "builder" "No supported builder command detected; skipping"
  fi
}

# FIX: Flattened PHP code for eval to avoid bash syntax errors with multi-line blocks
clear_wp_rocket_cache() {
  local wp_path="$1" pfx="$2" site="$3"

  if ! plugin_is_installed "$wp_path" "wp-rocket"; then
    return 1
  fi

  if wp_command_exists_loaded "$wp_path" "rocket"; then
    wp_run_loaded "$wp_path" "$pfx" "$site" "cache" rocket clean --confirm
    return 0
  fi

  wp_run_loaded "$wp_path" "$pfx" "$site" "cache" eval 'if(function_exists("rocket_clean_domain")){rocket_clean_domain();if(function_exists("rocket_clean_minify")){rocket_clean_minify();}WP_CLI::success("WP Rocket cache cleared via PHP fallback.");}else{WP_CLI::warning("WP Rocket detected but no wp rocket command or PHP fallback is available.");}'
  return 0
}

# FIX: Flattened PHP code for eval to avoid bash syntax errors with multi-line blocks
clear_wp_fastest_cache() {
  local wp_path="$1" pfx="$2" site="$3"

  if ! plugin_is_installed "$wp_path" "wp-fastest-cache"; then
    return 1
  fi

  if wp_command_exists_loaded "$wp_path" "fastest-cache"; then
    wp_run_loaded "$wp_path" "$pfx" "$site" "cache" fastest-cache clear all
    return 0
  fi

  wp_run_loaded "$wp_path" "$pfx" "$site" "cache" eval 'if(function_exists("wpfc_clear_all_cache")){wpfc_clear_all_cache();WP_CLI::success("WP Fastest Cache cleared via PHP fallback.");}else{WP_CLI::warning("WP Fastest Cache detected but no CLI command or PHP fallback function is available.");}'
  return 0
}

clear_site_cache() {
  local wp_path="$1" pfx="$2" site="$3"

  [[ "$CLEAR_CACHE" == "1" ]] || return 0

  local did_anything=0

  if plugin_is_installed "$wp_path" "litespeed-cache"; then
    did_anything=1
    wp_run_loaded "$wp_path" "$pfx" "$site" "cache" litespeed-purge all
  fi

  if plugin_is_installed "$wp_path" "wp-rocket"; then
    did_anything=1
    clear_wp_rocket_cache "$wp_path" "$pfx" "$site"
  fi

  if plugin_is_installed "$wp_path" "w3-total-cache"; then
    did_anything=1
    wp_run_loaded "$wp_path" "$pfx" "$site" "cache" w3-total-cache flush all
  fi

  if plugin_is_installed "$wp_path" "wp-fastest-cache"; then
    did_anything=1
    clear_wp_fastest_cache "$wp_path" "$pfx" "$site"
  fi

  if plugin_is_installed "$wp_path" "wp-super-cache" && wp_command_exists_loaded "$wp_path" "super-cache"; then
    did_anything=1
    wp_run_loaded "$wp_path" "$pfx" "$site" "cache" super-cache flush
  elif plugin_is_installed "$wp_path" "wp-super-cache"; then
    echo "[$(ts)] ${pfx}${site} | cache | WP Super Cache detected, but wp-super-cache-cli is not installed; skipping explicit purge." | tee -a "$TEXT_LOG"
    log_json "info" "$site" "cache" "WP Super Cache detected, but wp-super-cache-cli is not installed; skipping explicit purge"
  fi

  if plugin_is_installed "$wp_path" "wp-optimize"; then
    did_anything=1
    echo "[$(ts)] ${pfx}${site} | cache | WP-Optimize detected; relying on its automatic cache purge behavior after plugin/theme/permalink updates." | tee -a "$TEXT_LOG"
    log_json "info" "$site" "cache" "WP-Optimize detected; relying on its automatic cache purge behavior after plugin/theme/permalink updates"
  fi

  if wp_command_exists_loaded "$wp_path" "redis" || plugin_is_installed "$wp_path" "redis-cache" || plugin_is_installed "$wp_path" "wp-redis"; then
    did_anything=1
    if wp_command_exists_loaded "$wp_path" "redis"; then
      wp_run_loaded "$wp_path" "$pfx" "$site" "cache" redis flush
    else
      echo "[$(ts)] ${pfx}${site} | cache | Redis object cache detected, but no wp redis command is available; falling back to generic object cache flush if possible." | tee -a "$TEXT_LOG"
      log_json "info" "$site" "cache" "Redis object cache detected, but no wp redis command is available; falling back to generic object cache flush if possible"
    fi
  fi

  if [[ -f "$wp_path/wp-content/object-cache.php" ]]; then
    did_anything=1
    wp_run_loaded "$wp_path" "$pfx" "$site" "cache" cache flush
  fi

  if [[ "$did_anything" == "0" ]]; then
    echo "[$(ts)] ${pfx}${site} | cache | No supported cache plugin or object cache detected; skipping." | tee -a "$TEXT_LOG"
    log_json "info" "$site" "cache" "No supported cache plugin or object cache detected; skipping"
  fi
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
        chmod 755 "$BACKUP_DIR" 2>/dev/null || true
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


prepare_site_backup_dirs() {
  local wp_path="$1" bdir="$2"
  local owner db_dir plugins_dir

  owner="$(owner_of_install "$wp_path")"
  bdir="$(realpath -m "$bdir")"
  db_dir="$bdir/db"
  plugins_dir="$bdir/plugins"

  mkdir -p "$BACKUP_DIR" "$bdir" "$db_dir" "$plugins_dir"

  # Keep the global backup root traversable; site-specific paths can stay tighter.
  chmod 755 "$BACKUP_DIR" 2>/dev/null || true
  chmod 750 "$bdir" "$db_dir" "$plugins_dir" 2>/dev/null || true

  # The owning site user must be able to write DB dumps here when wp db export
  # runs through sudo -u <owner>. Root can still write plugin archives/manifest.
  chown "$owner":"$owner" "$bdir" "$db_dir" "$plugins_dir" 2>/dev/null || true
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
  prepare_site_backup_dirs "$wp_path" "$bdir"

  local owner
  owner="$(owner_of_install "$wp_path")"

  # Fetch the current WP version to embed in the filename
  local prefix wp_version dump_file
  prefix="$(wp_prefix "$wp_path")"
  local php_bin
  php_bin="$(resolve_php_bin_for_site "$wp_path" "$pfx" "$site" "$phase")"
  wp_version="$(shell_exec "${prefix:+$prefix }$(wp_command_shell_join "$php_bin" "$wp_path" 0 core version --quiet) 2>/dev/null" </dev/null | first_nonempty_line || true)"
  wp_version="${wp_version:-unknown}"
  wp_version="$(printf '%s' "$wp_version" | sanitize_token)"
  [[ -n "$wp_version" ]] || wp_version="unknown"

  local site_id
  site_id="$(site_id_from_path "$wp_path")"
  dump_file="$(realpath -m "${db_dir}/${site_id}_wp${wp_version}.sql")"

  echo "[$(ts)] ${pfx}${site} | ${phase} | Dumping DB (WP ${wp_version}) -> $dump_file" | tee -a "$TEXT_LOG"
  log_json "info" "$site" "$phase" "Dumping DB (WP ${wp_version}) -> $dump_file"

  local cmd out rc
  cmd="${prefix:+$prefix }$(wp_command_shell_join "$php_bin" "$wp_path" 0 db export "$dump_file" --quiet)"
  out="$(shell_exec "$cmd" </dev/null 2>&1)"
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
  local prefix php_bin
  prefix="$(wp_prefix "$wp_path")"
  php_bin="$(resolve_php_bin_for_site "$wp_path" "$pfx" "$site" "$phase")"

  local plugin_list
  plugin_list="$(shell_exec \
    "${prefix:+$prefix }$(wp_command_shell_join "$php_bin" "$wp_path" 0 plugin list --update=available --fields=name,version --format=csv --quiet) 2>/dev/null" \
    </dev/null || true)"

  if [[ -z "$plugin_list" ]]; then
    echo "[$(ts)] ${pfx}${site} | ${phase} | No updatable plugins found; skipping plugin backup." | tee -a "$TEXT_LOG"
    log_json "info" "$site" "$phase" "No updatable plugins found; skipping plugin backup"
    return 0
  fi

  # Use an absolute path for the backup dir so it stays valid after cd
  local plugins_bdir
  prepare_site_backup_dirs "$wp_path" "$bdir"
  plugins_bdir="$(realpath -m "$bdir/plugins")"

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
    slug="$(printf '%s' "$slug" | sanitize_token)"
    version="$(printf '%s' "$version" | sanitize_token)"
    [[ -n "$slug" && -n "$version" ]] || continue

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

  local prefix php_bin
  prefix="$(wp_prefix "$wp_path")"
  php_bin="$(resolve_php_bin_for_site "$wp_path" "" "$site" "backup:manifest")"

  local wp_version site_url
  wp_version="$(shell_exec \
    "${prefix:+$prefix }$(wp_command_shell_join "$php_bin" "$wp_path" 0 core version --quiet) 2>/dev/null" \
    </dev/null | first_nonempty_line || true)"
  wp_version="${wp_version:-unknown}"
  site_url="$(shell_exec \
    "${prefix:+$prefix }$(wp_command_shell_join "$php_bin" "$wp_path" 0 option get siteurl --quiet) 2>/dev/null" \
    </dev/null | first_nonempty_line || true)"
  site_url="${site_url:-unknown}"

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
# PREMIUM ZIP UPDATES (only if installed) - FIX: Escaping applied via shell_join in wp_run
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
      local php_bin
      php_bin="$(resolve_php_bin_for_site "$wp_path" "$pfx" "$site" "premium")"
      cmd="${prefix:+$prefix }$(wp_command_shell_join "$php_bin" "$wp_path" 0 plugin is-installed "$slug")"
    else
      local php_bin
      php_bin="$(resolve_php_bin_for_site "$wp_path" "$pfx" "$site" "premium")"
      cmd="$(wp_command_shell_join "$php_bin" "$wp_path" 0 plugin is-installed "$slug")"
    fi

    # Using shell_join to represent the escaped zip path for logging in DRY RUN
    local escaped_zip
    escaped_zip=$(shell_join "$zip")

    if [[ "$DRY_RUN" == "1" ]]; then
      echo "[$(ts)] ${pfx}${site} | premium | [DRY] if installed: $slug -> install $escaped_zip --force" | tee -a "$TEXT_LOG"
      log_json "info" "$site" "premium" "[DRY] if installed: $slug -> install $escaped_zip --force"
      continue
    fi

    if shell_exec "$cmd" </dev/null >/dev/null 2>&1; then
      echo "[$(ts)] ${pfx}${site} | premium | Updating premium plugin: $slug" | tee -a "$TEXT_LOG"
      log_json "info" "$site" "premium" "Updating premium plugin: $slug"
      # Passes the zip file to wp_run, where joined_args="$(shell_join "$@")" correctly escapes it
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

  # ---- Optional post-update maintenance ----
  flush_permalinks_soft "$wp_path" "$pfx" "$site"
  clear_site_cache      "$wp_path" "$pfx" "$site"

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

RUN_MODE_LABEL="Dry Run"
[[ "$DRY_RUN" == "0" ]] && RUN_MODE_LABEL="Real Run"

log_plain "==== $(ts) START (${RUN_MODE_LABEL}, total=$TOTAL) ===="
log_json "info" "GLOBAL" "start" "Start run (${RUN_MODE_LABEL}, total=$TOTAL)"

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
ANSWER="$(prompt_yes_no_default 'Discover NEW WordPress installations and update only those?' 'N')"

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
