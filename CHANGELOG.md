# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and the project uses
[Semantic Versioning](https://semver.org/).

## [Unreleased]

### Added
- **Test switched-off checks.** A *Test* button in WHM runs a check that is switched off (on the
  *Status page* tab for a single check, on the *Checks* tab for a whole check type) and shows its
  result there, without reloading the page. Nothing is sent to Better Stack, so it never pings a
  heartbeat or opens an incident. On the command line: `bswhm check --all`.
- **Charts on the overview.** Meters with threshold marks, 24-hour sparklines and hourly status
  strips per check, plus *Closest to a threshold* at the top. History is stored locally in
  `history.json` and never sent anywhere.
- **Update check.** Once a day (and on request in WHM) the plugin looks for new commits in the git
  clone it was installed from. WHM shows a notice, the list of new changes and the command to
  update. Nothing is installed automatically. On the command line: `bswhm update-check`.
- **SSL certificates: exclude suspended accounts.** A new option on the SSL check leaves out the
  certificates of suspended cPanel accounts. The number skipped is shown in WHM only.

### Changed
- **Faster SSL check.** Certificate end dates are remembered per file, so `openssl` only runs for
  new or renewed certificates. On servers with many certificates the check (and its test in WHM)
  is much faster after the first run.

## [1.0.0] - 2026-10-24

First public release.

### Added
- **Health checks:**
  - server reachability and cPanel services;
  - CPU load, memory and swap;
  - disk space and inodes per partition;
  - database reachability and mail queue;
  - blacklist (RBL) check;
  - SSL certificate expiry;
  - cPanel backups and software RAID.
- **Better Stack provisioning:**
  - heartbeats, a heartbeat group, status page sections and status page items;
  - outages reported via `/fail` with details for your team.
- **Bundling** of checks per category (at most four heartbeats per server), with optional own
  heartbeats per check and clear handling of the plan's heartbeat quota.
- **Live details** as status page item text, refreshed every 5 minutes and immediately on a
  status change.
- **Self-healing synchronisation:** adopts existing objects after a lost state file and removes
  duplicates and leftovers, without touching unrelated monitors.
- **WHM interface** with overview, status page, checks, settings and log tabs.
- **English, Dutch and German**, separately for the WHM page and the public status page.
- **`bswhm` command line tool** for checks, status, connection tests, synchronisation and
  clean-up.
- **Security hardening:**
  - root-only, fail-closed access and a CSRF token;
  - a clean child environment, timeouts that stop whole process groups, durable 0600 files;
  - HTTPS without redirects and validated API responses.
- **Test suite** covering checks, provisioning, security, translations and browser interaction.
