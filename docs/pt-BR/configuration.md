# Configuração

**Português** | [English](../en/configuration.md)

A Gaia funciona sem nenhum arquivo de configuração: os padrões são seguros e o que for específico da
máquina (conta, chaves, portas) pode vir pela linha de comando ou ser perguntado no terminal.

Para servidores repetidos, use um `gaia.conf`:

```bash
cp gaia.conf.example gaia.conf
chmod 600 gaia.conf        # a Gaia avisa se outros usuários puderem alterar o arquivo
sudo ./bootstrap.sh        # ./gaia.conf é usado automaticamente
sudo ./bootstrap.sh --config /caminho/outro.conf
```

O arquivo é lido pelo Bash como `CHAVE=valor`. **Nunca** coloque chaves privadas nele: só chaves
públicas.

## Precedência

1. linha de comando (`--admin-user`, `--allow`, `--modules`...);
2. `gaia.conf`;
3. variáveis de ambiente `GAIA_*` (ex.: `sudo GAIA_TIMEZONE=UTC ./bootstrap.sh`);
4. padrões.

Todos os valores são validados antes de qualquer etapa rodar; um valor inválido encerra a execução
com uma mensagem dizendo o formato esperado.

## Referência

A lista completa, com comentários, está em [`gaia.conf.example`](../../gaia.conf.example). Resumo:

| Grupo | Chaves |
|-------|--------|
| Módulos | `GAIA_MODULES` |
| Conta administradora | `GAIA_ADMIN_USER`, `GAIA_ADMIN_SSH_KEYS`, `GAIA_ADMIN_GITHUB_KEYS`, `GAIA_ADMIN_IMPORT_KEYS`, `GAIA_ADMIN_SHELL`, `GAIA_ADMIN_SUDO_NOPASSWD` |
| Sistema | `GAIA_HOSTNAME`, `GAIA_TIMEZONE`, `GAIA_NTP_PACKAGE`, `GAIA_MIN_DISK_GB`, `GAIA_REQUIRE_SYSTEMD`, `GAIA_CHECK_INTERNET`, `GAIA_APT_FULL_UPGRADE`, `GAIA_APT_UPDATE_MAX_AGE`, `GAIA_EXTRA_PACKAGES`, `GAIA_SWAP_SIZE`, `GAIA_SWAP_FILE`, `GAIA_SWAPPINESS`, `GAIA_DIRS` |
| SSH | `GAIA_SSH_PORT`, `GAIA_SSH_PERMIT_ROOT_LOGIN`, `GAIA_SSH_PASSWORD_AUTH`, `GAIA_SSH_ALLOW_USERS`, `GAIA_SSH_MODERN_CRYPTO`, `GAIA_SSH_MAX_AUTH_TRIES`, `GAIA_SSH_LOGIN_GRACE_TIME`, `GAIA_SSH_CLIENT_ALIVE_INTERVAL`, `GAIA_SSH_TCP_FORWARDING`, `GAIA_SSH_AGENT_FORWARDING`, `GAIA_SSH_DROPIN` |
| Firewall e fail2ban | `GAIA_FIREWALL_ALLOW`, `GAIA_SSH_RATE_LIMIT`, `GAIA_FAIL2BAN_BANTIME`, `GAIA_FAIL2BAN_FINDTIME`, `GAIA_FAIL2BAN_MAXRETRY`, `GAIA_FAIL2BAN_BACKEND`, `GAIA_FAIL2BAN_IGNOREIP` |
| Serviços expostos | `GAIA_DISABLE_UNUSED_SERVICES`, `GAIA_DISABLE_SERVICES`, `GAIA_MTA_LOCAL_ONLY` |
| Kernel, logs, AppArmor | `GAIA_SYSCTL`, `GAIA_SYSCTL_EXTRA`, `GAIA_JOURNALD`, `GAIA_JOURNALD_MAX_USE`, `GAIA_APPARMOR` |
| Atualizações | `GAIA_AUTO_REBOOT`, `GAIA_AUTO_REBOOT_TIME` |
| Auditoria | `GAIA_AUDIT` |
| Módulo docker | `GAIA_DOCKER_LOG_MAX_SIZE`, `GAIA_DOCKER_LOG_MAX_FILE`, `GAIA_DOCKER_DATA_ROOT`, `GAIA_DOCKER_ADD_ADMIN_TO_GROUP`, `GAIA_DOCKER_UFW`, `GAIA_DOCKER_PUBLISH`, `GAIA_DOCKER_LOCALHOST_ONLY`, `GAIA_DOCKER_SMOKE_TEST` |
| Módulo caddy | `GAIA_CADDY_SITES`, `GAIA_CADDY_EMAIL`, `GAIA_CADDY_BLOCK_PATHS` |
| Execução | `GAIA_EXTRA_STEPS_DIR`, `GAIA_LOG_DIR`, `GAIA_DEBUG` |

## Exemplos

### Servidor web com Docker e HTTPS

```bash
GAIA_MODULES="docker caddy"
GAIA_ADMIN_USER="deploy"
GAIA_ADMIN_GITHUB_KEYS="sua-conta-no-github"
GAIA_HOSTNAME="web-01.example.com"
GAIA_TIMEZONE="America/Sao_Paulo"
GAIA_SWAP_SIZE="2G"
GAIA_DOCKER_LOCALHOST_ONLY=1      # containers só no loopback; o Caddy expõe
GAIA_CADDY_SITES="app.example.com=127.0.0.1:8080"
GAIA_CADDY_EMAIL="ops@example.com"
GAIA_DIRS="/srv/apps:@admin:@admin:0755 /srv/backups:@admin:@admin:0750"
```

### Bastion (só SSH, porta alternativa)

```bash
GAIA_MODULES="none"
GAIA_ADMIN_USER="ops"
GAIA_ADMIN_SSH_KEYS="ssh-ed25519 AAAA... ops@notebook"
GAIA_SSH_PORT=2222
GAIA_SSH_TCP_FORWARDING="yes"     # o bastion encaminha conexões
GAIA_FAIL2BAN_MAXRETRY=3
```

### Mais de um usuário no SSH

```bash
GAIA_SSH_ALLOW_USERS="@admin deploy backup"   # vazio = sem linha AllowUsers
```

## Variáveis de ambiente úteis

| Variável | Uso |
|----------|-----|
| `GAIA_DEBUG=1` | mostra as linhas de debug também na tela |
| `GAIA_ROOT` | raiz alternativa (usada pelos testes; não use em servidores) |
| `GAIA_CONTAINER=0/1` | força a detecção de container |
