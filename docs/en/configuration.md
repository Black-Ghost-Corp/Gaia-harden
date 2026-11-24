# Configuration

[Português](../pt-BR/configuration.md) | **English**

Gaia works without any configuration file: the defaults are secure, and what is specific to the
machine (account, keys, ports) can come from the command line or be asked in the terminal.

For repeated servers, use a `gaia.conf`:

```bash
cp gaia.conf.example gaia.conf
chmod 600 gaia.conf        # Gaia warns when other users can change the file
sudo ./bootstrap.sh        # ./gaia.conf is picked up automatically
sudo ./bootstrap.sh --config /path/other.conf
```

The file is read by Bash as `KEY=value`. **Never** put private keys in it: public keys only.

## Precedence

1. command line (`--admin-user`, `--allow`, `--modules`...);
2. `gaia.conf`;
3. `GAIA_*` environment variables (e.g. `sudo GAIA_TIMEZONE=UTC ./bootstrap.sh`);
4. defaults.

Every value is validated before any step runs; an invalid value stops the run with a message
describing the expected format.

## Reference

The full list, with comments, is in [`gaia.conf.example`](../../gaia.conf.example). Summary:

| Group | Keys |
|-------|------|
| Modules | `GAIA_MODULES` |
| Administrator account | `GAIA_ADMIN_USER`, `GAIA_ADMIN_SSH_KEYS`, `GAIA_ADMIN_GITHUB_KEYS`, `GAIA_ADMIN_IMPORT_KEYS`, `GAIA_ADMIN_SHELL`, `GAIA_ADMIN_SUDO_NOPASSWD` |
| System | `GAIA_HOSTNAME`, `GAIA_TIMEZONE`, `GAIA_NTP_PACKAGE`, `GAIA_MIN_DISK_GB`, `GAIA_REQUIRE_SYSTEMD`, `GAIA_CHECK_INTERNET`, `GAIA_APT_FULL_UPGRADE`, `GAIA_APT_UPDATE_MAX_AGE`, `GAIA_EXTRA_PACKAGES`, `GAIA_SWAP_SIZE`, `GAIA_SWAP_FILE`, `GAIA_SWAPPINESS`, `GAIA_DIRS` |
| SSH | `GAIA_SSH_PORT`, `GAIA_SSH_PERMIT_ROOT_LOGIN`, `GAIA_SSH_PASSWORD_AUTH`, `GAIA_SSH_ALLOW_USERS`, `GAIA_SSH_MODERN_CRYPTO`, `GAIA_SSH_MAX_AUTH_TRIES`, `GAIA_SSH_LOGIN_GRACE_TIME`, `GAIA_SSH_CLIENT_ALIVE_INTERVAL`, `GAIA_SSH_TCP_FORWARDING`, `GAIA_SSH_AGENT_FORWARDING`, `GAIA_SSH_DROPIN` |
| Firewall and fail2ban | `GAIA_FIREWALL_ALLOW`, `GAIA_SSH_RATE_LIMIT`, `GAIA_FAIL2BAN_BANTIME`, `GAIA_FAIL2BAN_FINDTIME`, `GAIA_FAIL2BAN_MAXRETRY`, `GAIA_FAIL2BAN_BACKEND`, `GAIA_FAIL2BAN_IGNOREIP` |
| Exposed services | `GAIA_DISABLE_UNUSED_SERVICES`, `GAIA_DISABLE_SERVICES`, `GAIA_MTA_LOCAL_ONLY` |
| Kernel, logs, AppArmor | `GAIA_SYSCTL`, `GAIA_SYSCTL_EXTRA`, `GAIA_JOURNALD`, `GAIA_JOURNALD_MAX_USE`, `GAIA_APPARMOR` |
| Updates | `GAIA_AUTO_REBOOT`, `GAIA_AUTO_REBOOT_TIME` |
| Audit | `GAIA_AUDIT`, `GAIA_TIPS` |
| docker module | `GAIA_DOCKER_LOG_MAX_SIZE`, `GAIA_DOCKER_LOG_MAX_FILE`, `GAIA_DOCKER_DATA_ROOT`, `GAIA_DOCKER_ADD_ADMIN_TO_GROUP`, `GAIA_DOCKER_UFW`, `GAIA_DOCKER_PUBLISH`, `GAIA_DOCKER_LOCALHOST_ONLY`, `GAIA_DOCKER_SMOKE_TEST` |
| caddy module | `GAIA_CADDY_SITES`, `GAIA_CADDY_EMAIL`, `GAIA_CADDY_BLOCK_PATHS` |
| Runtime | `GAIA_EXTRA_STEPS_DIR`, `GAIA_LOG_DIR`, `GAIA_DEBUG` |

## Examples

### Web server with Docker and HTTPS

```bash
GAIA_MODULES="docker caddy"
GAIA_ADMIN_USER="deploy"
GAIA_ADMIN_GITHUB_KEYS="your-github-account"
GAIA_HOSTNAME="web-01.example.com"
GAIA_TIMEZONE="Europe/Berlin"
GAIA_SWAP_SIZE="2G"
GAIA_DOCKER_LOCALHOST_ONLY=1      # containers on loopback only; Caddy exposes them
GAIA_CADDY_SITES="app.example.com=127.0.0.1:8080"
GAIA_CADDY_EMAIL="ops@example.com"
GAIA_DIRS="/srv/apps:@admin:@admin:0755 /srv/backups:@admin:@admin:0750"
```

### Bastion (SSH only, alternate port)

```bash
GAIA_MODULES="none"
GAIA_ADMIN_USER="ops"
GAIA_ADMIN_SSH_KEYS="ssh-ed25519 AAAA... ops@laptop"
GAIA_SSH_PORT=2222
GAIA_SSH_TCP_FORWARDING="yes"     # the bastion forwards connections
GAIA_FAIL2BAN_MAXRETRY=3
```

### More than one SSH user

```bash
GAIA_SSH_ALLOW_USERS="@admin deploy backup"   # empty = no AllowUsers line
```

## Useful environment variables

| Variable | Use |
|----------|-----|
| `GAIA_DEBUG=1` | also shows debug lines on screen |
| `GAIA_ROOT` | alternate root (used by the tests; do not use on servers) |
| `GAIA_CONTAINER=0/1` | forces container detection |
