# Mass WP Update

Mass WP Update is a server-side administration tool for discovering, backing up, updating, and post-maintenance refreshing multiple WordPress installations using WP-CLI.

It is intended for system administrators and operators who manage many WordPress sites across shared, reseller, or multi-user hosting environments.

The tool automates routine maintenance while respecting filesystem ownership, standard WordPress update mechanisms, and common hosting layouts.

## Features

### Automatic discovery of WordPress installations
Mass WP Update discovers WordPress roots by locating `wp-config.php` across common hosting directory layouts and optional user-defined paths.

Discovery is hardened to avoid false positives inside directories such as:

- `wp-content`
- `node_modules`
- `vendor`
- `.git`

It also validates discovered paths by checking for expected WordPress structure such as `wp-load.php` and `wp-content`.

### Bulk updates via WP-CLI
Performs updates for:

- WordPress core
- installed plugins
- installed themes

### Premium / local ZIP plugin updates
Updates already-installed plugins using administrator-supplied ZIP packages from a local directory when available.

### Pre-update backups
Supports optional backups before updates are applied:

- database export via `wp db export`
- per-plugin ZIP archives for plugins that have available updates

Backups are stored per site, per run, in timestamped snapshot directories.

### Backup manifests
Generates a `manifest.json` file for each backup snapshot containing:

- backup timestamp
- WordPress path
- site URL
- WordPress version
- database dump filename
- archived plugin filenames

### Backup retention
Can automatically purge old backup snapshots based on a configurable retention period.

### Correct execution context
Runs WP-CLI as the owning system user of each WordPress installation to reduce permission issues in multi-user hosting environments.

### Interactive mode
When run without arguments, launches a guided wizard for selecting:

- dry run or real run
- backup type
- backup directory setup
- optional post-update maintenance actions

### Dry-run mode
Allows previewing actions without applying updates or writing backup files.

### Detailed logging
Provides both:

- human-readable log output with timestamps and per-site separators
- JSONL log output suitable for parsing or monitoring

### Incremental discovery
Can optionally detect newly added WordPress installations and process only those.

### Optional post-update maintenance
Supports optional post-update refresh actions such as:

- soft permalink flush
- supported cache purges
- supported page-builder asset regeneration / cache clearing

### Panel-agnostic operation
Designed to work across common hosting environments, including:

- cPanel
- Plesk
- DirectAdmin
- ISPConfig
- CyberPanel / OpenLiteSpeed
- generic Linux directory layouts

## Supported post-update maintenance

The script can optionally run maintenance tasks after updates complete.

### Soft permalink flush
When enabled, the script performs a soft rewrite refresh using:

```bash
wp rewrite flush
```

This refreshes rewrite rules without forcing a `.htaccess` rewrite.

### Supported cache purges
When `--clear-cache` is enabled, the script can automatically clear caches for the following systems when detected:

| System | Detection | Action |
|---|---|---|
| LiteSpeed Cache | `litespeed-cache` plugin installed | `wp litespeed-purge all` |
| WP Rocket | `wp-rocket` plugin installed | `wp rocket clean --confirm` |
| W3 Total Cache | `w3-total-cache` plugin installed | `wp w3-total-cache flush all` |
| WP Fastest Cache | `wp-fastest-cache` plugin installed | `wp fastest-cache clear all` |
| WP Super Cache | `wp-super-cache` plugin installed **and** `super-cache` WP-CLI command available | `wp super-cache flush` |
| Persistent object cache | `wp-content/object-cache.php` exists | `wp cache flush` |

### Supported builder asset regeneration / cache clearing
Builder-specific regeneration runs before page-cache purges so page caches can refill using fresh generated assets.

| Builder / plugin | Detection | Action |
|---|---|---|
| Elementor | `elementor` plugin installed and command available | `wp elementor flush-css --regenerate` |
| Elementor Pro | `elementor-pro` plugin installed and command available | `wp elementor-pro theme-builder clear-conditions` |
| Breakdance | `breakdance` WP-CLI command available | `wp breakdance clear_cache` |
| Beaver Builder | `beaver` WP-CLI command available | `wp beaver clearcache` |

## Detected but intentionally skipped

Some cache or builder systems are detected and logged, but the script does not run an automatic purge/regeneration command for them.

### WP-Optimize
When `wp-optimize` is detected, the script logs the detection and relies on the plugin's own automatic purge behavior after updates / permalink refreshes rather than forcing a separate cache-clear command.

### Other detected builders without scripted regeneration
The script currently detects and logs these systems, but skips automatic regeneration because no supported command path is wired into the script:

- Oxygen
- WPBakery
- Bold Builder
- Divi / Extra
- Bricks

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
```

## Usage

Run with no arguments for interactive mode:

```bash
./mass-wp-update.sh
```

Dry run:

```bash
./mass-wp-update.sh 1
```

Normal run:

```bash
./mass-wp-update.sh 2
```

Normal run with backups enabled for this run only:

```bash
./mass-wp-update.sh 2 --backup-db --backup-plugins
```

Normal run with post-update maintenance enabled:

```bash
./mass-wp-update.sh 2 --flush-permalinks --clear-cache
```

Force a fresh rediscovery of installations:

```bash
./mass-wp-update.sh 2 --refresh
```

Use a custom configuration file:

```bash
./mass-wp-update.sh 2 --conf /path/to/mass-wp-update.conf
```

Full example:

```bash
./mass-wp-update.sh 2 --refresh --backup-db --backup-plugins --flush-permalinks --clear-cache
```

## Configuration

The script supports configuration via `mass-wp-update.conf`.

Common options include:

- search roots
- custom roots file
- installs cache file
- premium ZIP directory
- log directory
- backup directory
- backup retention
- WP-CLI and PHP binary paths
- owner-user execution behavior
- color output
- plugin/theme skip flags

If you want permalink flush and cache clearing enabled by default, add:

```bash
FLUSH_PERMALINKS=1
CLEAR_CACHE=1
```

If you want them disabled by default, use:

```bash
FLUSH_PERMALINKS=0
CLEAR_CACHE=0
```

## Backup directory layout

Example:

```text
backups/
  home__alice__public_html/
    20260403_153954/
      db/
        home__alice__public_html_wp6.9.4.sql
      plugins/
        woocommerce_v10.6.1.zip
        yoast-seo_v24.7.zip
      manifest.json
```

## Notes on cache command loading

Most plugin-specific cache commands require plugins to be loaded in WP-CLI.

For that reason, cache-clearing and builder-regeneration actions are run through a plugin-loaded command path instead of the standard update path that may use `--skip-plugins` for safer updates.

## Intended use

Mass WP Update is intended for administrators who need a practical and repeatable way to maintain large numbers of WordPress installations while keeping backups, execution context, logging, and post-update refresh tasks under control.
