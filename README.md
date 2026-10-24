# StatusBridge for WHM

**Server health on your Better Stack status page, straight from cPanel & WHM.**

StatusBridge is a WHM plugin that monitors the health of a cPanel server and publishes it on a
[Better Stack](https://betterstack.com) status page, right next to your regular uptime monitors.
Visitors don't just see whether a website responds. They also see whether mail, DNS, databases,
backups and the server itself are healthy.

> StatusBridge is an independent open-source project. It is not affiliated with, endorsed by or
> supported by Better Stack or cPanel, L.L.C. "Better Stack" and "cPanel" are trademarks of their
> respective owners.

---

## Contents

- [How it works](#how-it-works)
- [What is monitored](#what-is-monitored)
- [Requirements](#requirements)
- [Installation](#installation)
- [Configuration](#configuration)
- [The WHM interface](#the-whm-interface)
- [Bundles and the heartbeat quota](#bundles-and-the-heartbeat-quota)
- [Languages](#languages)
- [Data flow and privacy](#data-flow-and-privacy)
- [Self-healing synchronisation](#self-healing-synchronisation)
- [Command line](#command-line)
- [Updating and uninstalling](#updating-and-uninstalling)
- [Files](#files)
- [Troubleshooting](#troubleshooting)
- [Development](#development)
- [Security](#security)
- [License](#license)

---

## How it works

Every check reports to a **heartbeat** in Better Stack Uptime. Each heartbeat appears as an item
on your status page.

```
  Your server (cron, every minute)                    Better Stack
  ────────────────────────────────                    ────────────
  run the checks that are due
  ├─ all fine      ── HTTPS GET  heartbeat URL ─────►  item stays green
  ├─ outage        ── HTTPS POST heartbeat URL/fail ►  incident, team alerted, item red
  └─ live details  ── HTTPS PATCH status page item ─►  current values shown as item text
```

If the server goes down entirely, the heartbeats stop arriving and Better Stack shows that too.

On the status page it looks like this:

```
server1.example.com
├─ Server                  ● CPU load: Load 0.80 / 0.65 / 0.60 (8 cores, 8% used) · Memory: 62% used …
├─ Services                ● 9 services running · Database connections: Reachable, 14 connections …
├─ Email                   ● Mail queue: 12 messages in the queue · Email reputation: Not listed (4 lists checked)
└─ Security & backups      ● SSL certificates: 184 certificates, next one expires in 21 days · Backups: Succeeded …
```

When something fails, the failing part is listed first (for example `✖ Web server: Not running`).

## What is monitored

| Check | What it looks at | Outage (default) | Interval |
|---|---|---|---|
| Server reachable | Sign of life from the server | Server stops reporting | 60 s |
| cPanel services | Customer-facing services from `whmapi1 servicestatus`: web server, database, Exim, Dovecot, DNS, FTP, cPanel/WHM, CalDAV | Service not running | 60 s |
| CPU load | 5-minute load average per core | ≥ 4 per core (warning ≥ 1.5) | 60 s |
| Memory & swap | Memory in use, based on `MemAvailable` | ≥ 98% (warning ≥ 90%) | 60 s |
| Disk space & inodes | Every local partition | ≥ 95% (warning ≥ 85%) | 300 s |
| Database reachable | `mysqladmin status`: connections, queries/s | Not reachable | 60 s |
| Mail queue | `exim -bpc` | ≥ 2500 messages (warning ≥ 500) | 300 s |
| Blacklist check | Main IP (plus optional extra IPs) against Spamhaus ZEN, SpamCop, Barracuda and PSBL | Listed | 1800 s |
| SSL certificates | Installed and AutoSSL certificates, plus the cPanel service certificate. Optionally without suspended accounts | Expires within 3 days (warning within 14) | 3600 s |
| cPanel backups | Result and age of the latest backup log | Failed or older than 30 hours | 3600 s |
| Software RAID | `/proc/mdstat` | Array degraded | 300 s |

Every check can be switched on or off, and its interval, thresholds and published details can be
changed in WHM.

**Warnings and outages.** A warning shows up in WHM and in the item text (⚠), but the item stays
green. Only an outage creates an incident in Better Stack.

**Suspended accounts.** Turn on *Exclude suspended accounts* in the SSL check to leave out the
certificates of suspended cPanel accounts (`/var/cpanel/suspended`, matched via
`/etc/userdomains`). It is off by default. WHM shows how many certificates were skipped.

**Off by default.** Internal services such as `lfd`, `rsyslogd`, `p0f`, `queueprocd`, IP aliases,
LMTP/POP3, `nscd` and SSH are discovered but switched off by default, and so are `/boot` partitions.
You can switch them on in WHM.

## Requirements

- A server running cPanel & WHM, with root SSH access. The plugin uses cPanel's bundled Perl
  (`/usr/local/cpanel/3rdparty/bin/perl`) and needs no extra packages.
- A Better Stack account with Uptime and a status page.
- A Better Stack Uptime **API token**. A team token is recommended (**Uptime → Settings → API tokens**).
- Outbound HTTPS (TCP 443) to `incidents.betterstack.com` and `uptime.betterstack.com`, plus DNS for
  the blacklist check. No inbound ports are needed.

## Installation

On the server, as root:

```bash
git clone https://github.com/prinsopdefoto-max/whm-betterstackbridge.git /root/whm-betterstackbridge
cd /root/whm-betterstackbridge
./install.sh
```

The installer:
- copies the plugin to `/opt/betterstack-whm`;
- registers the page in WHM;
- installs a cron job (`/etc/cron.d/betterstack-whm`) that runs every minute;
- runs a first round of checks.

It refuses to install from a directory that contains files not owned by root or writable by
others.

## Configuration

1. Open **WHM → Plugins → StatusBridge**.
2. Go to **Settings**, paste your Better Stack API token and click **Save & synchronise**.
3. Choose your status page and set a server name. The server name is public: it becomes the
   heading on the status page.
4. Save again.

The plugin then creates:
- a heartbeat group named after the server;
- a section on the status page (or one per category, see *Layout*);
- one heartbeat and status page item per bundle.

The cron job only runs the checks that are due. New services and partitions are picked up
automatically, and anything that disappears is cleaned up.

### Multiple servers

Install the plugin on each server and point them all at the same status page. Each server gets its
own section and heartbeat group, based on its server name.

## The WHM interface

| Tab | Contents |
|---|---|
| **Overview** | System status, counters, and a card per heartbeat with its checks, private details (WHM only) and the text currently shown on the status page. |
| **Status page** | Per category: which checks are on, their public names, the bundle name, and which checks get their own heartbeat. |
| **Checks** | Interval, thresholds and published details for each check. |
| **Settings** | Connection, status page, layout, languages, alert channels and behaviour, plus a danger zone that removes everything from Better Stack. |
| **Log** | Recent log entries, newest first. |

**Testing a check that is switched off.** A check that is off has a *Test* button: on the
*Status page* tab for a single check, on the *Checks* tab for a whole check type. It runs the check
on the server and shows the result right there. Nothing is sent to Better Stack, so it never pings
a heartbeat or opens an incident. Unsaved changes on that tab are not kept, so save first.

The page only loads local assets (no external fonts, scripts or images). It also works without
JavaScript and on small screens.

## Bundles and the heartbeat quota

Better Stack plans limit the number of heartbeats. By default, all checks of a category share
**one bundled heartbeat**: Server, Services, Email, and Security & backups. That means at most four
heartbeats per server.

- **A bundle fails** when any of its checks fails. The item text lists which check failed.
- **Own heartbeat.** On the *Status page* tab, turn on *Own heartbeat* to show a single check as a
  separate item. This uses one extra heartbeat.
- **Quota reached.** If you exceed your plan, the plugin reports it once and retries after 15
  minutes. It does not flood you with errors.

The number of heartbeats in use is shown above the list of items.

## Languages

English, Dutch and German. There are two separate settings:

- **Language of the WHM page.** Automatic by default: it follows the WHM account's locale, then the
  browser. You can also fix it via the menu at the top or in Settings.
- **Status page language.** The language of the names and texts your visitors see. When you change
  it, names and texts in Better Stack are updated on the next synchronisation. Names you entered
  yourself are kept.

Log entries, errors and incident texts for your team follow the language of the WHM page.

To add a language, add a column to the tables in `lib/BetterStack/WHM/I18N.pm` and `UIStrings.pm`
and add the language to `@LANGS`. `t/04-i18n.t` fails if a translation is missing or if the
placeholders (`%s`, `%d`) don't match.

## Data flow and privacy

- **Outbound only.** The plugin never opens a port and has no webhook endpoint. All connections are
  started by the server over HTTPS, with certificate verification and without following redirects.
- **What is published** (when *Live details* is on): general values such as percentages, counts
  and ages.
- **What stays private:**
  - domain names, IP addresses, error messages and uptime;
  - these are shown in WHM only;
  - they are included in the outage report to *your own* Better Stack team.
- **Turning details off.** *Live details* can be switched off globally or per check.
- **Third parties.** The blacklist check sends the server IP (reversed, as a DNS query) to the
  blacklist operators, which is inherent to that kind of check.
- **The server name is public.** Choose a neutral one if you'd rather not show the hostname.

## Self-healing synchronisation

On every synchronisation (after a change, at install and every 6 hours), the plugin compares what
exists in Better Stack with what it expects:

- **Adopt instead of duplicating.** Existing heartbeats, sections and items of this server are
  recognised and re-used. This also works after the local state file was lost.
- **Clean up.** Duplicates and leftovers of this server are removed.
- **Your own objects are never touched.** Only heartbeats in this server's heartbeat group named
  `<server name>: …`, and sections named after the server, are considered. A section that also
  holds other items (such as your own URL monitors) is always kept.

The state file is written with `fsync` and a backup copy, so it survives a hard reset.

## Command line

```
bswhm check        run all checks locally, without contacting Better Stack
bswhm check --all  the same, including checks that are switched off
bswhm status       latest results and link state
bswhm test         test the API token and list status pages
bswhm sync         synchronise now
bswhm run --force  run and report all checks now
bswhm cleanup      remove everything this plugin created in Better Stack
```

## Updating and uninstalling

```bash
cd /root/whm-betterstackbridge
git pull
git log -p HEAD@{1}..   # review the changes, the code runs as root
./install.sh
```

Settings are kept across updates.

```bash
./uninstall.sh           # remove the plugin; Better Stack items and local settings stay
./uninstall.sh --purge   # also remove its heartbeats/items from Better Stack and the local settings
```

## Files

The internal paths and the Perl namespace use the technical name `betterstack-whm`.

| Path | Contents |
|---|---|
| `/opt/betterstack-whm/` | Code (`lib/`, `bin/bswhm`) |
| `/usr/local/cpanel/whostmgr/docroot/cgi/betterstack/` | WHM page |
| `/etc/betterstack-whm/config.json` | Settings and API token (mode 0600, root only) |
| `/var/lib/betterstack-whm/state.json` | Links to Better Stack objects and latest results (0600) |
| `/var/log/betterstack-whm.log` | Log (0600) |
| `/etc/cron.d/betterstack-whm` | Cron job |

## Troubleshooting

**"Heartbeat quota reached"**
Your plan's heartbeat limit is reached. Turn off *Own heartbeat* for some checks, disable checks, or
delete unused heartbeats in Better Stack.

**Blacklist check says "cannot be checked"**
- Spamhaus refuses queries from public resolvers (Google, Cloudflare, Quad9 …). Use a local
  resolver (for example `unbound`), or a Spamhaus DQS key in the blacklist settings.
- Every list is first verified with the RFC 5782 test entries. A resolver that answers for any name
  (wildcard, hijacking, `search` domains) therefore never causes false listings.

**Duplicate sections or items on the status page**
Run `bswhm sync`. The self-healing synchronisation adopts what belongs to this server and removes
duplicates.

**Nothing changes on the status page**
Check `bswhm status` and the *Log* tab. *Run checks* in WHM re-sends all texts immediately.

## Development

```bash
prove -l t/
```

The tests run without cPanel and use a simulated Better Stack API. They cover:
- the checks and their parsing;
- provisioning, adoption and clean-up;
- quota handling and migrations;
- security (access control, CSRF, escaping, clean child environment, file permissions, input and
  API validation);
- translations;
- real clicks in a headless browser (`t/05-browser.t`, skipped when Node.js with Playwright is not
  available).

## Security

See [SECURITY.md](SECURITY.md) for the threat model, the measures taken and the remaining risks.
Please report vulnerabilities privately, not in a public issue.

## License

[MIT](LICENSE)
