# Mass WP Update

Mass WP Update is a server-side administration tool for discovering, backing up, updating, and post-maintenance refreshing multiple WordPress installations using WP-CLI.

It is intended for system administrators and operators who manage many WordPress sites across shared, reseller, or multi-user hosting environments.

The tool automates routine maintenance while respecting filesystem ownership, standard WordPress update mechanisms, and common hosting layouts.

## Features

### Automatic discovery of WordPress installations
Mass WP Update discovers WordPress roots by locating `wp-config.php` across common hosting directory layouts and optional user-defined paths.

Discovery is hardened to avoid false positives inside directories such as:
* `wp-content`
* `node_modules`
* `vendor`
* `.git`

It also validates discovered paths by checking for expected WordPress structure such as `wp-load.php` and `wp-content`.

### Bulk updates via WP-CLI
Performs updates for:
* WordPress core
* installed plugins
* installed themes

### Premium / local ZIP plugin updates
Updates already-installed plugins using administrator-supplied ZIP packages from a local directory when available. File paths with spaces and parentheses are safely escaped.

### Pre-update backups
Supports optional backups before updates are applied:
* database export via `wp db export`
* per-plugin ZIP archives for plugins that have available updates

Backups are stored per site, per run, in timestamped snapshot directories.

### Backup manifests
Generates a `manifest.json` file for each backup snapshot containing:
* backup timestamp
* WordPress path
* site URL
* WordPress version
* database dump filename
* archived plugin filenames

### Backup retention
Can automatically purge old backup snapshots based on a configurable retention period.

### Correct execution context
Runs WP-CLI as the owning system user of each WordPress installation to reduce permission issues in multi-user hosting environments.

### Interactive mode
When run without arguments, launches a guided wizard for selecting:
* dry run or real run
* backup type
* backup directory setup
* optional post-update maintenance actions

### Dry-run mode
Allows previewing actions without applying updates or writing backup files.

### Detailed logging
Provides both:
* human-readable log output with timestamps and per-site separators
* JSONL log output suitable for parsing or monitoring

### Incremental discovery
Can optionally detect newly added WordPress installations and process only those.

### Optional post-update maintenance
Supports optional post-update refresh actions such as:
* soft permalink flush
* supported cache purges
* supported page-builder asset regeneration / cache clearing

### Panel-agnostic operation
Designed to work across common hosting environments, including:
* cPanel
* Plesk
* DirectAdmin
* ISPConfig
* CyberPanel / OpenLiteSpeed
* generic Linux directory layouts

## Supported post-update maintenance

The script can optionally run maintenance tasks after updates complete.

### Soft permalink flush
When enabled, the script performs a soft rewrite refresh using:
```bash
wp rewrite flush
