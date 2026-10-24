# Security

StatusBridge runs as **root**, from cron and from the WHM page. The design goal is that nothing an
account holder, reseller or customer PHP script can influence leads to code execution, to reading
other accounts' data or to changing the configuration.

## Reporting a vulnerability

Please report vulnerabilities privately, using GitHub's **Report a vulnerability** button on the
repository's *Security* tab. Do not open a public issue. Include steps to reproduce and the affected
version.

## Threat model

| Attacker | Capability | Mitigation |
|---|---|---|
| Account holder with shell, jailshell or PHP | Inspect local files and processes, plant symlinks, create domains and certificates | All plugin files are owned by root with mode 0600/0700. Files are opened with `O_NOFOLLOW`/`O_EXCL`. No path comes from `%ENV`. Domain names and certificate data are only ever treated as data, never as code or shell arguments. |
| Reseller with WHM access | Call addon CGIs (WHM runs them as root) | The page requires the `all` ACL (`hasroot`) and fails closed if the ACL check cannot run. The AppConfig uses `acls=all`. |
| Third-party website (CSRF) | Make a logged-in root user submit a form | A per-user CSRF token (HMAC with a root-only secret) on top of WHM's `cpsess` token. State changes only happen on POST. |
| Stored XSS | Customer data (domain names, error output, API responses) shown in WHM | All output is HTML-escaped. `X-Content-Type-Options`, `X-Frame-Options`, `Referrer-Policy` and `Cache-Control: no-store` are set. |
| Network or compromised API | Tamper with responses | HTTPS only with certificate verification and no redirects (so the token cannot leak). IDs and heartbeat URLs from the API are strictly validated before they are used in a path or URL. |
| Public (status page) | Gather information about the infrastructure | Only general values are published. Uptime, domain names, IPs and error messages stay internal, and details can be switched off. |

## Measures in the code

- **No shell, ever.**
  - External commands run in list form with absolute paths; `run_cmd` refuses relative paths.
  - They get a clean environment (fixed `PATH`, `LC_ALL=C`, nothing inherited) and stdin from
    `/dev/null`.
- **Timeouts.**
  - A timeout kills the command's whole process group, so a hanging command never blocks the cron
    job.
  - Every check has a hard 120-second limit.
  - A lock prevents overlapping runs.
- **Files.**
  - `config.json` (API token), `state.json` (heartbeat URLs) and `csrf.secret` are mode 0600,
    inside directories with mode 0700.
  - The log is mode 0600 and contains no line breaks from external data, so entries cannot be
    forged.
  - Writes are atomic and durable: a temporary file opened with `O_EXCL|O_NOFOLLOW`, then `fsync`,
    `rename` and a directory `fsync`. A backup copy is kept.
- **No secrets in the process list.** The token is sent in a header. When the curl fallback is
  needed, it goes through a 0600 config file, never through argv.
- **Bounded input.**
  - Request bodies are limited to 1 MB.
  - Text fields are stripped of control characters and limited in length.
  - Only known item IDs are accepted, and numeric values are clamped.
  - `api_base` and `status_page_id` are re-validated on every load.
- **Minimal access to customer data.**
  - Only root-owned files are read: `/proc`, cPanel logs and the certificates under
    `/var/cpanel/ssl`.
  - Nothing in account home directories is read or executed.
  - Large logs are read from the end only.
- **Installer.**
  - Refuses a source tree with files that are not owned by root or that are group- or
    world-writable.
  - Fixes ownership and permissions of everything it installs, on upgrades too.

`t/03-security.t` covers these points automatically. It tests non-root access, CSRF, escaping, the
clean child environment, timeouts, log permissions, symlinks and API response validation.

## Remaining risks and recommendations

1. **Supply chain.** Anyone who can push to the repository you install from can run code as root on
   your servers through `install.sh`.
   - Use 2FA and branch protection.
   - Review `git log -p` before every `./install.sh`, or install a tagged release.
2. **Data sent to Better Stack.**
   - On an outage, the internal error details are sent to your own Better Stack team.
   - These can include customer domain names, for example for expiring certificates.
   - Better Stack acts as a processor for this data.
3. **Heartbeat URLs are secrets.** Anyone who knows one can fake a status. They are only stored in
   `state.json` (mode 0600) and in your Better Stack account.
4. **Blacklist check.** The server IP is looked up with the blacklist operators. This is inherent to
   such a check.
5. **Public status page.** The server name, partition names and service names are public. Choose a
   neutral server name if you don't want to show the hostname.
6. **WHM setting.** Keep *Security Tokens* enabled in Tweak Settings. The plugin has its own CSRF
   token, but the `cpsess` token protects the rest of WHM.
