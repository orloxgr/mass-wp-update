# Mass WP Update

Mass WP Update is a server-side administration tool for discovering and updating
multiple WordPress installations using WP-CLI. It is intended for system
administrators and operators who manage many WordPress sites across shared or
multi-user hosting environments.

The tool automates routine update tasks while respecting filesystem ownership
and standard WordPress update mechanisms.

---

## Features

- **Automatic discovery of WordPress installations**  
  Finds WordPress roots by locating `wp-config.php` across common hosting
  directory layouts and user-defined paths.

- **Bulk updates via WP-CLI**  
  Performs updates for:
  - WordPress core
  - Installed plugins
  - Installed themes

- **Plugin updates from local packages**  
  Updates installed plugins using administrator-supplied ZIP packages when
  available.

- **Correct execution context**  
  Executes WP-CLI as the owning system user of each WordPress installation to
  avoid permission issues.

- **Dry-run mode**  
  Allows previewing actions without applying changes.

- **Detailed logging**  
  - Human-readable log output with timestamps and per-site separators  
  - JSON log output suitable for parsing or external monitoring

- **Incremental discovery**  
  Optionally detects newly added WordPress installations and processes only
  those.

- **Panel-agnostic operation**  
  Designed to work across common hosting environments, including:
  - cPanel
  - Plesk
  - DirectAdmin
  - ISPConfig
  - CyberPanel / OpenLiteSpeed
  - Generic Linux directory layouts

---

## Requirements

- Linux-based operating system
- Bash
- PHP (CLI)
- WP-CLI
- Sudo access for executing commands as site owners

---

## Installation

Clone the repository and make the script executable:

```bash
git clone https://github.com/your-org/mass-wp-update.git
cd mass-wp-update
chmod +x mass-wp-update.sh
