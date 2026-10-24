# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and the project uses
[Semantic Versioning](https://semver.org/).

## [Unreleased]

### Added
- **Test switched-off checks.** A *Test* button in WHM runs a check that is switched off (on the
  *Status page* tab for a single check, on the *Checks* tab for a whole check type) and shows its
  result there. Nothing is sent to Better Stack, so it never pings a heartbeat or opens an
  incident. On the command line: `bswhm check --all`.
- **SSL certificates: exclude suspended accounts.** A new option on the SSL check leaves out the
  certificates of suspended cPanel accounts. The number skipped is shown in WHM only.

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
