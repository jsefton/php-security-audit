# php-security-audit

Scripts to download onto a server and run. Each script is a single bash
file. `check-all.sh` runs every check in one go and summarises the result.

| Script | Purpose | Changes the server? |
| --- | --- | --- |
| [`scripts/check-all.sh`](scripts/check-all.sh) | Run every check below in read-only mode and print a summary | No |
| [`scripts/php-security-audit.sh`](scripts/php-security-audit.sh) | Audit APT-installed PHP versions against minimum patched versions | Only with `--upgrade` |
| [`scripts/php-upload-progress.sh`](scripts/php-upload-progress.sh) | Check `session.upload_progress.enabled` in every `php.ini` | Only with `--patch` |
| [`scripts/nginx-fastcgi-keep-conn.sh`](scripts/nginx-fastcgi-keep-conn.sh) | Check the loaded nginx configuration for `fastcgi_keep_conn` | No |

All scripts target Ubuntu/Debian and need Bash 4 or later.

## Quick start

```bash
curl -fsSL https://github.com/jsefton/php-security-audit/archive/refs/heads/main.tar.gz | tar -xz
cd php-security-audit-main/scripts
sudo apt-get update      # so the PHP audit sees the latest APT versions
sudo bash check-all.sh
```

Then fix what it reports, for example:

```bash
sudo bash php-security-audit.sh --upgrade
sudo bash php-upload-progress.sh --patch
```

## Download

`check-all.sh` runs the other scripts from its own directory, so download
them all together (as in [Quick start](#quick-start)) or clone the
repository.

To fetch a single script:

```bash
curl -fsSLO https://raw.githubusercontent.com/jsefton/php-security-audit/main/scripts/php-security-audit.sh
# or
wget https://raw.githubusercontent.com/jsefton/php-security-audit/main/scripts/php-security-audit.sh
```

- Read a script before running it as root.
- Download the file rather than piping it into `bash`. The confirmation
  prompts in `--upgrade` and `--patch` read from standard input, which a
  pipe would take over.
- If the repository is private, these URLs will not work without
  authentication; clone the repository or use `gh` instead.

## Exit codes

Every script uses the same exit codes, so they work in cron and monitoring.

| Code | Meaning |
| --- | --- |
| `0` | Nothing needs attention. |
| `2` | Review required: something is, or may be, impacted. |
| `1` | Error: bad arguments, a missing command, missing root, or the check could not run. A failing command (such as `apt-get`) can also stop a script with its own non-zero code. |

---

## check-all.sh

Runs each check script in read-only mode, one after another, showing each
script's full output, then prints a summary:

```text
========== CHECK-ALL SUMMARY ==========
OK                php-security-audit.sh --check
REVIEW REQUIRED   php-upload-progress.sh --check
OK                nginx-fastcgi-keep-conn.sh --check

1 check(s) require review.
```

```bash
sudo bash check-all.sh
```

Run it as root: the nginx check needs root to read the full nginx
configuration and reports an error without it. The script prints a warning
if it is not run as root.

| Result | Meaning |
| --- | --- |
| `OK` | The check exited `0`. |
| `REVIEW REQUIRED` | The check exited `2`. |
| `ERROR (exit N)` | The check exited with any other code. |
| `MISSING` | The script is not in the same directory as `check-all.sh`. |

Exit code: `1` if any check errored or is missing (the results are
incomplete), otherwise `2` if any check requires review, otherwise `0`.

`check-all.sh` does not run `apt-get update`. For a scheduled check,
refresh APT first. For example, a weekly root crontab entry that logs the
result:

```cron
0 6 * * 1 apt-get update -qq && bash /opt/scripts/check-all.sh > /var/log/server-checks.log 2>&1
```

---

## php-security-audit.sh

Checks every PHP branch installed through APT (for example `8.3`, `8.4`)
against a list of minimum patched versions, reports whether a fix is
available in the server's configured APT repositories and, if asked,
upgrades the installed PHP packages.

### Requirements

- PHP installed from APT (the distribution packages or a repository such
  as `ppa:ondrej/php` / `packages.sury.org`)
- `dpkg-query`, `dpkg`, `apt-cache`, `awk` and `sort` (present on standard
  installs)
- `apt-get` and root, for `--upgrade` only

### Usage

```bash
# Audit only (default). Root is not needed.
bash php-security-audit.sh
bash php-security-audit.sh --check

# Refresh APT, audit, preview and upgrade, with a confirmation prompt
sudo bash php-security-audit.sh --upgrade

# Same, without the prompt (for unattended runs)
sudo bash php-security-audit.sh --upgrade --yes
```

| Option | Description |
| --- | --- |
| `--check` | Audit installed APT PHP versions. Makes no changes. This is the default. |
| `--upgrade` | Run `apt-get update`, audit, show a simulated upgrade, ask to confirm, upgrade, then audit again. Requires root. |
| `--yes` | Skip the confirmation prompt. Valid only with `--upgrade`. |
| `--help`, `-h` | Show help. |

`--check` does not refresh APT metadata, so the "APT candidate" it reports
is only as recent as the server's last `apt-get update`. Run
`sudo apt-get update` first for an up-to-date view, or use `--upgrade`,
which refreshes before auditing.

### What `--upgrade` does

1. Runs `apt-get update`.
2. Prints the **BEFORE UPGRADE** report.
3. Prints an APT simulation (`apt-get -s install --only-upgrade ...`) of the
   PHP packages that would change.
4. Asks `Apply the PHP package upgrades shown above? [y/N]` (skipped with
   `--yes`). Any answer other than `y`/`yes` cancels without changes and
   exits `0`.
5. Runs `apt-get -y install --only-upgrade` on the installed PHP packages.
   Only packages that are already installed are upgraded; nothing new is
   installed apart from any dependencies APT requires.
6. Prints the **AFTER UPGRADE** report.

After an upgrade, restart or reload PHP-FPM / Apache as your setup needs,
check service health and run your application's smoke tests.

### Packages it looks at

Only installed packages matching these names are audited and upgraded:

- `phpX.Y` and `phpX.Y-*` (runtime and extensions, e.g. `php8.3-fpm`,
  `php8.3-mysql`)
- `php-*` (meta packages and other PHP packages, e.g. `php-common`)
- `libapache2-mod-phpX.Y` (Apache module)
- `libphpX.Y-embed` (embed SAPI)

Each branch is represented by `phpX.Y-common` when it is installed,
otherwise by the first matching package for that branch. That package's
installed version and APT candidate are what the report shows.

It does **not** check PHP in Docker images, PHP compiled from source,
binaries installed outside APT, or other language runtimes.

### Reading the report

Example output (illustrative):

```text
========== PHP SECURITY AUDIT ==========
Installed APT-managed PHP packages: 14

PHP 8.3    | POTENTIALLY IMPACTED        | FIX AVAILABLE in configured APT repositories
  Representative package: php8.3-common
  Installed APT version:  8.3.30-1+ubuntu24.04.1+deb.sury.org+1
  Fixed upstream version: 8.3.37
  APT candidate:          8.3.37-1+ubuntu24.04.1+deb.sury.org+1

Summary: 1 branch(es) require review.
```

The first line for each branch shows its **status** and **availability**.

| Status | Meaning | Needs review |
| --- | --- | --- |
| `PATCHED (upstream)` | Installed upstream version is at or above the fixed version. | No |
| `PATCHED (vendor backport)` | Below the fixed upstream version, but the full package version is at or above a verified vendor backport in `FIXED_VENDOR_PACKAGE`. | No |
| `BACKPORT VERIFIED (EOL branch)` | The branch has no upstream fix (end of life), but a verified vendor backport is installed. Still counted for review because the branch is unsupported upstream. | Yes |
| `POTENTIALLY IMPACTED` | Below the fixed version and no verified backport. | Yes |
| `EOL / FIX STATUS UNKNOWN` | The branch is not in `FIXED_UPSTREAM` (e.g. PHP 7.4, 8.1) and has no verified backport. | Yes |

| Availability | Meaning |
| --- | --- |
| `FIX AVAILABLE in configured APT repositories` | A newer package is available and it would be classed as patched. |
| `Update available; security fix NOT verified` | A newer package is available but it would not be classed as patched. |
| `No newer version in configured APT repositories` | The installed version is the newest APT offers. |
| `No APT candidate` | APT has no installable version of the package (e.g. its repository was removed). |

If no versioned PHP runtime packages are installed through APT, the report
says so and the run counts as needing review.

#### Vendor backports

Ubuntu and Debian often fix security issues without changing the upstream
version number. For example, Ubuntu 24.04's `8.3.6-0ubuntu0.24.04.N`
packages stay on PHP 8.3.6 while receiving patches. The script compares
upstream versions (epoch and Debian revision removed), so a patched
distribution package like this shows as `POTENTIALLY IMPACTED` until you
record its fixed package version in `FIXED_VENDOR_PACKAGE`.

### Configuration

The version tables are at the top of the script. Edit them when a new
advisory is published.

```bash
# Minimum fixed UPSTREAM versions
declare -A FIXED_UPSTREAM=(
  [8.2]="8.2.36"
  [8.3]="8.3.37"
  [8.4]="8.4.28"
  [8.5]="8.5.13"
  [8.6]="8.6.0"
)

# VERIFIED vendor-backported minimum APT package versions
declare -A FIXED_VENDOR_PACKAGE=(
  # [8.3]="8.3.6-0ubuntu0.24.04.N"
)
```

- **`FIXED_UPSTREAM`**: the first upstream PHP release in each branch that
  contains the fix. The current values are dated 19 Nov 2026. Leave a
  branch out if it has no upstream fix; it is then reported as
  `EOL / FIX STATUS UNKNOWN`.
- **`FIXED_VENDOR_PACKAGE`**: the full `dpkg` package version (as shown by
  `dpkg-query -W php8.3-common` or `apt-cache policy`, not `php -v`) that
  your OS vendor's security advisory lists as fixed. Add an entry only
  after checking that advisory for this specific issue.

---

## php-upload-progress.sh

Reports whether `session.upload_progress.enabled` is on for every PHP
version and SAPI (`fpm`, `apache2`, `cli`, `cgi`, ...) under
`/etc/php/<version>/<sapi>/php.ini`, and with `--patch` sets it to `0` in
each `php.ini` that leaves it enabled.

### Usage

```bash
# Check only (default). Root is not needed.
bash php-upload-progress.sh

# Preview, confirm, patch php.ini and reload PHP-FPM / Apache
sudo bash php-upload-progress.sh --patch

# Same, without the prompt
sudo bash php-upload-progress.sh --patch --yes

# Patch but leave reloading to you
sudo bash php-upload-progress.sh --patch --no-reload
```

| Option | Description |
| --- | --- |
| `--check` | Report the setting for every `php.ini`. Makes no changes. This is the default. |
| `--patch` | Set `session.upload_progress.enabled = 0` where `php.ini` leaves it enabled, then reload affected services. Requires root. |
| `--yes` | Skip the confirmation prompt. Valid only with `--patch`. |
| `--no-reload` | Do not reload services after patching. Valid only with `--patch`. |
| `--help`, `-h` | Show help. |

### How the value is worked out

For each `php.ini` the script reads the file and then
`conf.d/*.ini` in name order, the same order PHP uses; the last setting
wins. **If the directive is not set anywhere, PHP's default is `1`
(enabled)**, and the stock `php.ini` only has it commented out, so most
servers report `ENABLED` until patched.

| Status | Meaning | Needs review |
| --- | --- | --- |
| `DISABLED` | The effective value is off (`0`, `Off`, `No`, `False`, empty). | No |
| `ENABLED` | Enabled by `php.ini` or by PHP's default. `--patch` fixes this. | Yes |
| `ENABLED (conf.d)` | A file in `conf.d/` enables it, overriding `php.ini`. `--patch` does **not** change `conf.d` files; edit the file shown. | Yes |

For PHP-FPM it also lists `php_value` / `php_admin_value` / `php_flag` /
`php_admin_flag` overrides in `php-fpm.conf` and `pool.d/*.conf`. These
apply to one pool and take precedence over `php.ini`. An override that
enables the setting counts for review; `--patch` does not change pool
files.

Not checked: `php_flag` / `php_value` in Apache configuration or
`.htaccess`, `.user.ini` files, and PHP outside `/etc/php` (Docker, custom
builds). If no `php.ini` is found under `/etc/php`, the run counts as
needing review.

### What `--patch` does

1. Prints the **BEFORE PATCH** report.
2. For each `php.ini` with status `ENABLED`, shows a diff of the change:
   - an existing `session.upload_progress.enabled = ...` line is changed
     to `session.upload_progress.enabled = 0`;
   - otherwise the new line is added after the commented-out
     `;session.upload_progress.enabled = On`, or after the `[Session]`
     header, or at the end of the file under a new `[Session]` header.
3. Lists the services it will reload: `phpX.Y-fpm` for `fpm`, and
   `apache2` for `apache2`. CLI and CGI need no reload.
4. Asks `Apply the php.ini changes shown above? [y/N]` (skipped with
   `--yes`). Cancelling makes no changes and exits `2`.
5. Saves a backup next to each file (`php.ini.bak-YYYYMMDDHHMMSS`), then
   replaces the file, keeping its owner and permissions.
6. Reloads each running service after a config test (`php-fpmX.Y -t`,
   `apache2ctl configtest`). A service that is not running is skipped. If
   a test fails, that service is not reloaded.
7. Prints the **AFTER PATCH** report.

The run exits `2` if anything still needs review afterwards, including a
service that was not reloaded (`--no-reload`, a failed config test or a
failed reload): the new value only takes effect once the service reloads.

To undo, copy the backup over `php.ini` and reload the service.

`php.ini` is a managed configuration file on Debian/Ubuntu. After this
change, a later PHP package upgrade that ships a new default `php.ini` may
ask whether to keep your version: keep it, or the setting is lost.

---

## nginx-fastcgi-keep-conn.sh

Searches the configuration nginx actually loads for `fastcgi_keep_conn`.
It is the equivalent of:

```bash
sudo nginx -T 2>/dev/null | grep -n 'fastcgi_keep_conn'
```

but traces each match back to its file and line and classifies it.

```bash
sudo bash nginx-fastcgi-keep-conn.sh
```

Requires root, because `nginx -T` must read every included file
(certificates and keys included) to dump the configuration.

Example output (illustrative):

```text
========== NGINX fastcgi_keep_conn CHECK ==========
Matches in nginx -T output (dump line | file:line: text):
  [comment]     88 | /etc/nginx/sites-enabled/app.conf:14: # fastcgi_keep_conn on;
  [ON]          91 | /etc/nginx/snippets/fastcgi-php.conf:13: fastcgi_keep_conn on;

Result: IMPACTED. fastcgi_keep_conn is on in 1 place(s).
```

| Match | Meaning |
| --- | --- |
| `[ON]` | An active `fastcgi_keep_conn on;`. The server is reported as **IMPACTED**. |
| `[off]` | An active `fastcgi_keep_conn off;`. |
| `[comment]` | Only appears in a comment. |
| `[UNCLEAR]` | Mentions the directive but could not be classified (for example, split over several lines). Check it by hand; counts for review. |

If there are no matches, the result is **NOT IMPACTED**: nginx's default
for `fastcgi_keep_conn` is `off`.

Exit codes: `0` when not impacted or when nginx is not installed; `2` when
impacted or unclear; `1` when not run as root or when `nginx -T` fails
(for example, because of a configuration error).

---

## Adding a script

1. Put the script in `scripts/` as a single self-contained bash file.
2. If it checks something, make the default mode read-only, accept
   `--check`, and use the [exit codes](#exit-codes) above. Add it to the
   `CHECKS` list at the top of `check-all.sh`.
3. Add a row to the table at the top of this README and a section
   describing its options and output.
