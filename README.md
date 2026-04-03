# Mass WP Update

Mass WP Update is a server-side administration tool for discovering, backing up, and updating multiple WordPress installations using WP-CLI. It is intended for system administrators and operators who manage many WordPress sites across shared, reseller, or multi-user hosting environments.

The tool automates routine update and backup tasks while respecting filesystem ownership, standard WordPress update mechanisms, and common hosting layouts.

## Features

### Automatic discovery of WordPress installations
Finds valid WordPress roots by locating `wp-config.php` across common hosting directory layouts and optional user-defined paths.

Discovery is hardened to avoid false positives inside directories such as:

- `wp-content`
- `node_modules`
- `vendor`
- `.git`

It also validates discovered paths by checking for expected WordPress structure such as `wp-load.php` and `wp-content`.

### Bulk updates via WP-CLI
Performs updates for:

- WordPress core
- Installed plugins
- Installed themes

### Premium / local ZIP plugin updates
Updates already installed plugins using administrator-supplied ZIP packages from a local directory when available.

### Pre-update backups
Supports optional backups before updates are applied:

- Database export via `wp db export`
- Per-plugin ZIP archives for plugins with available updates

Backups are stored per site, per run, with timestamped snapshot directories.

### Backup manifests
Generates a `manifest.json` file for each backup snapshot containing information such as:

- backup timestamp
- WordPress path
- site URL
- WordPress version
- database dump filename
- archived plugin filenames

### Backup retention
Can automatically purge old backup snapshots based on a configurable retention period.

### Correct execution context
Executes WP-CLI as the owning system user of each WordPress installation to reduce permission problems and align with multi-user hosting environments.

### Interactive mode
When run without arguments, launches a guided setup wizard that allows the operator to choose:

- dry run or real run
- backup type
- backup directory setup

### Dry-run mode
Allows previewing actions without applying updates or writing backup files.

### Detailed logging
Provides both:

- human-readable log output with timestamps and per-site separators
- JSONL log output suitable for parsing, monitoring, or external integrations

### Incremental discovery
Optionally detects newly added WordPress installations and processes only those, without reprocessing the entire existing list.

### Configurable operation
Supports configuration via a separate `mass-wp-update.conf` file, including:

- search roots
- custom root file
- backup directory
- retention policy
- WP-CLI and PHP binary paths
- color output
- plugin/theme skip flags
- owner-user execution behavior

### Panel-agnostic operation
Designed to work across common hosting environments, including:

- cPanel
- Plesk
- DirectAdmin
- ISPConfig
- CyberPanel / OpenLiteSpeed
- generic Linux directory layouts

## Requirements

- Linux-based operating system
- Bash
- PHP (CLI)
- WP-CLI
- `sudo` access for executing commands as site owners
- `zip` for plugin archive backups
- `unzip` for local ZIP plugin updates

## Installation

Clone the repository and make the script executable:

```bash
git clone https://github.com/orloxgr/mass-wp-update.git
cd mass-wp-update
chmod +x mass-wp-update.sh
