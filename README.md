# Mass WP Update

Mass WP Update is a server-side Bash tool for discovering, backing up, updating, and post-maintenance refreshing multiple WordPress installations using WP-CLI.

It is built for administrators who manage many WordPress sites across shared, reseller, or multi-user hosting environments and want a repeatable, ownership-aware maintenance workflow.

---

## What it does

- Automatically discovers WordPress installations by locating `wp-config.php`
- Updates WordPress core, plugins, and themes with WP-CLI
- Supports premium/local ZIP plugin updates
- Can create pre-update backups
  - database exports
  - per-plugin ZIP archives for plugins with available updates
- Stores backups in per-site, timestamped snapshot directories
- Generates backup manifests
- Can purge old snapshots based on retention rules
- Runs WP-CLI as the owning system user of each site when configured
- Includes an interactive wizard when launched without arguments
- Supports dry-run and real-run execution
- Produces human-readable logs and JSONL logs
- Can optionally run post-update maintenance such as rewrite flush, cache clears, and builder regeneration

---

## What has changed since the initial public GitHub version

This README also documents the improvements added after the initial public repository state.

### 1) Better compatibility with CWP / panel banners
Some environments print login banners or shell text that can pollute captured command output. The script was hardened so command substitution is kept clean and shell noise does not get treated as plugin names, versions, or paths.

### 2) Improved first-run interactive wizard
The wizard is now much stricter and clearer.

- default-value prompts explicitly tell the user to press Enter to keep the autodiscovered value
- `Y/N` prompts accept only valid answers
- numbered menus force valid choices
- mistaken single-key entries in text/path fields are rejected and reprompted
- startup flow reads more cleanly and avoids confusing pauses

### 3) PHP binary discovery and selection
The script now scans the server for usable PHP CLI binaries and lets the operator choose a global default.

It also filters out bad or noisy candidates such as:

- `php-cgi` style wrappers that are unsuitable for WP-CLI use
- CageFS / skeleton duplicates that clutter the list

This makes the PHP selection screen much cleaner on cPanel and similar systems.

### 4) Per-site PHP compatibility fallback
Not every WordPress installation on a server is compatible with the same PHP version.

The script now attempts to use a site-compatible PHP binary when a site fails under the global default. This is especially useful for older WordPress installs or legacy plugins/themes that cannot load under newer PHP versions.

### 5) Higher PHP CLI limits for maintenance runs
To reduce failures during large update sessions, WP-CLI execution now passes stronger CLI PHP limits:

```bash
-d max_execution_time=999999
-d max_input_time=999999
-d memory_limit=2048M
-d max_input_vars=20000
-d post_max_size=2048M
-d upload_max_filesize=2048M
```

### 6) Safer backup directory preparation
When backups are enabled, snapshot directories are prepared in a way that works better in multi-user hosting setups where WP-CLI is executed as each site owner.

### 7) Better progress visibility during long discovery
Long filesystem scans can look frozen on large servers. The script now provides visible progress / heartbeat output during discovery so the operator can see that scanning is still active.

### 8) Cleaner run-state messaging
Startup and run banners now use clearer wording such as:

- `Dry Run`
- `Real Run`

instead of exposing internal flags.

### 9) Logging and shell-fallback fixes
Several shell and variable-handling issues discovered during real-world testing were fixed so strict shell mode does not break execution and compatibility fallbacks do not contaminate commands.

---

## Interactive mode

Run the script without arguments to launch the guided wizard.

The wizard can help with:

- creating a config file on first run
- selecting dry run or real run
- choosing backup behavior
- choosing optional post-update maintenance
- selecting a global PHP binary
- setting search roots and backup directory

This is intended to make first-time setup much safer on real servers.

---

## Typical use cases

Mass WP Update is useful when you need to maintain many WordPress installations on:

- cPanel servers
- CWP servers
- Plesk servers
- DirectAdmin servers
- CyberPanel / OpenLiteSpeed setups
- generic Linux multi-user hosting layouts

---

## Backups

When enabled, backups are stored per site and per run using timestamped snapshot folders.

A typical snapshot may include:

- a database export
- ZIP archives for updatable plugins
- a `manifest.json` file describing the snapshot

This makes it easier to review what was backed up before a maintenance run.

---

## Post-update maintenance

Optional post-update maintenance can include:

- soft permalink flush
- supported cache clear / purge actions
- supported builder regeneration commands

These actions are optional because not every environment or plugin stack should run them automatically.

---

## Discovery behavior

The script discovers WordPress installations by locating `wp-config.php` and validating that the path looks like a real WordPress root.

Discovery is intended to avoid obvious false positives inside folders such as:

- `wp-content`
- `vendor`
- `node_modules`
- `.git`

---

## Premium ZIP updates

The script can also update already-installed premium plugins from locally supplied ZIP packages.

This is useful when managing commercial plugins outside the WordPress.org update channel.

---

## Recommended workflow

1. Run the script in **Dry Run** mode first.
2. Review the discovered sites and planned actions.
3. Enable backups if appropriate.
4. Run a **Real Run**.
5. Review the logs and any warnings for site-specific issues.

---

## Notes for mixed-version hosting

On older multi-site fleets, one global PHP version is often not enough.

Examples of site-specific failures include:

- older WordPress code failing on newer PHP versions
- legacy plugins/themes failing when loaded during maintenance tasks
- environment-specific cache/auth issues

The newer per-site PHP fallback logic is designed to reduce those failures without forcing one PHP version across the entire server.

---

## Logging

The script provides:

- readable console / log output with timestamps
- per-site separators
- JSONL logging for machine parsing or monitoring workflows

---

## License

MIT
