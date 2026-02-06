Mass WP Update is a server-side administration tool for discovering and updating multiple WordPress installations using WP-CLI.
It is designed for system administrators and operators who manage many WordPress sites on a single server or across shared hosting environments.

The tool automates routine maintenance tasks while respecting filesystem ownership and standard WordPress update mechanisms.

Features

Automatic discovery of WordPress installations
Finds WordPress roots by locating wp-config.php across common hosting directory layouts and user-defined paths.

Bulk updates via WP-CLI
Performs updates for:

WordPress core

Installed plugins

Installed themes

Plugin updates from local packages
Supports updating installed plugins using administrator-supplied ZIP packages when present.

Correct execution context
Runs WP-CLI as the owning system user of each WordPress installation to avoid permission issues.

Dry-run mode
Allows previewing actions without applying changes.

Detailed logging

Human-readable log output with timestamps and per-site separators

JSON log output suitable for parsing or external monitoring

Incremental discovery
Optionally detects newly added WordPress installations and processes only those.

Panel-agnostic operation
Works across common hosting environments, including:

cPanel

Plesk

DirectAdmin

ISPConfig

CyberPanel / OpenLiteSpeed

Generic Linux directory layouts

Typical Use Cases

Maintaining multiple WordPress installations on shared servers

Performing routine update operations across many sites

Managing production, staging, and development environments

Centralizing WordPress maintenance through a single administrative tool

How It Works

Searches configured directory roots for wp-config.php files

Identifies WordPress installation paths

Executes WP-CLI commands for each installation in sequence

Applies updates and logs all actions

All operations rely on standard WordPress and WP-CLI behavior.

Configuration

The tool supports a configuration file where administrators can:

Define search paths for WordPress installations

Add custom directories

Configure binary paths for PHP and WP-CLI

Enable or disable optional features such as dry-run mode

Requirements

Linux-based operating system

Bash

WP-CLI

PHP (CLI)

Sudo access for executing commands as site owners

License

MIT License
