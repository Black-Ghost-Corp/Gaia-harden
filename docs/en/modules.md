# Modules

[Português](../pt-BR/modules.md) | **English**

Modules are optional software that Gaia installs **already configured securely**. They run after the
base steps and before custom steps. Choose them with:

```bash
sudo ./bootstrap.sh --modules docker,caddy   # or "all" / "none"
```

or `GAIA_MODULES="docker caddy"` in `gaia.conf`. With no choice and a terminal available, Gaia shows
a menu. Modules not chosen show the `not selected` status.

## docker

Installs Docker Engine, CLI, containerd, buildx and compose from Docker's **official repository**.

What the module guarantees (each part acts only if needed):

1. **Conflicting packages removed** (`docker.io`, `docker-compose`, `podman-docker`, `containerd`,
   `runc`...), keeping the data in `/var/lib/docker`.
2. **Verified repository**: the GPG key is downloaded over HTTPS and compared with the official
   fingerprint (`9DC8 5822 9FC7 DD38 854A E2D8 8D81 803C 0EBF CD88`) before it reaches apt.
3. **`/etc/docker/daemon.json` merged** with `jq` (keys you already had are kept): log rotation
   (`GAIA_DOCKER_LOG_MAX_SIZE`, `GAIA_DOCKER_LOG_MAX_FILE`), `live-restore`, optional `data-root`
   (`GAIA_DOCKER_DATA_ROOT`; old data is **not** moved) and, with `GAIA_DOCKER_LOCALHOST_ONLY=1`,
   `"ip": "127.0.0.1"` — ports published without an IP listen on loopback only. An invalid
   `daemon.json` makes the step fail without being overwritten.
4. **`docker` group** for the administrator account (`GAIA_DOCKER_ADD_ADMIN_TO_GROUP`), with a
   warning: that group is root-equivalent.
5. **`ufw` applied to containers** (`GAIA_DOCKER_UFW=1`, see below).
6. Service enabled and a `docker run --rm hello-world` smoke test (`GAIA_DOCKER_SMOKE_TEST`).

### Docker and ufw

Docker writes its own iptables rules for published ports (`-p 8080:80`), and they are evaluated
**before** the `ufw` rules. The result: the firewall denies everything, yet the container is open to
the internet.

The module appends to `/etc/ufw/after.rules` a block delimited by `# BEGIN GAIA DOCKER-USER` /
`# END GAIA DOCKER-USER` that sends the `DOCKER-USER` chain through the `ufw` forwarding rules (the
same approach as the [ufw-docker](https://github.com/chaifeng/ufw-docker) project):

- traffic from private networks (10/8, 172.16/12, 192.168/16) and replies keep flowing;
- new connections from the internet to containers are blocked and logged (`[UFW DOCKER BLOCK]`),
  **unless** there is a `ufw route allow` rule;
- the file is validated with `ufw reload`; if that fails, the previous one is restored.

To open a container port to the internet, use the **container** port (in `-p 8080:80`, it is 80):

```bash
# gaia.conf
GAIA_DOCKER_PUBLISH="80/tcp 443/tcp"
# same as: ufw route allow proto tcp from any to any port 80
```

The `summary` port audit shows `docker, filtered by ufw route rules` for filtered ports and
`EXPOSED (Docker bypasses ufw)` when the module was not applied.

> [!TIP]
> For applications behind a reverse proxy on the same host (`caddy` module), publish ports on loopback
> only (`-p 127.0.0.1:8080:8080`) or use `GAIA_DOCKER_LOCALHOST_ONLY=1`.

## caddy

Installs [Caddy](https://caddyserver.com/) from the **official repository** (key checked against the
fingerprint `6576 0C51 EDEA 2017 CEA2 CA15 155B 6D79 CA56 EA34`) as a host service: it listens on 80
and 443, obtains and renews certificates (Let's Encrypt) and forwards to the application, which stays
on `127.0.0.1`.

Configuration:

```bash
# "domain=upstream" separated by spaces; upstream host:port or h2c://host:port (gRPC without TLS)
GAIA_CADDY_SITES="app.example.com=127.0.0.1:8080 api.example.com=127.0.0.1:9000"
GAIA_CADDY_EMAIL="ops@example.com"            # ACME account (optional)
GAIA_CADDY_BLOCK_PATHS="/internal/* /metrics" # answer 403 on every site
```

The generated `/etc/caddy/Caddyfile` has:

- the `gaia_blocks` snippet on every site: the `GAIA_CADDY_BLOCK_PATHS` paths answer 403;
- the `gaia_headers` snippet: `Strict-Transport-Security`, `X-Content-Type-Options: nosniff`,
  `Referrer-Policy: strict-origin-when-cross-origin` and no `Server` header;
- `reverse_proxy` with `flush_interval -1` (server-sent events and streaming without buffering);
- `import /etc/caddy/sites.d/*.caddy` for hand-written sites (use `import gaia_blocks` and
  `import gaia_headers` in them too).

The new file is validated with `caddy validate` **before** replacing the current one; if it is
rejected, the current one stays and the step fails. Changes are applied with `systemctl reload caddy`
(no dropped connections). The module allows 80/tcp and 443/tcp in `ufw`.

> [!NOTE]
> Certificates are only issued when the domain's DNS points to the server and ports 80/443 are also
> open in the provider's firewall. Follow along with `journalctl -u caddy -f`.

## Writing a new module

A module is a `lib/modules/NN-name.sh` file with a `# gaia-description:` header and a `step_run`
function, in the same format as the base steps. It is discovered automatically and shows up in the
menu, in `--modules` and in `--list-steps`. See the [contributing guide](../../CONTRIBUTING.en.md)
and the [roadmap](../../README.en.md#roadmap) for planned modules.
