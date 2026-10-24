# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and the project uses
[Semantic Versioning](https://semver.org/).

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
