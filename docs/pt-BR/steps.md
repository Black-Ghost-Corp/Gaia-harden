# Etapas

**Português** | [English](../en/steps.md)

A Gaia roda as etapas na ordem abaixo. `./bootstrap.sh --list-steps` mostra a lista real (incluindo
módulos e etapas próprias). Use `--only` e `--skip` para escolher quais rodam; nomes desconhecidos
são recusados.

Ordem completa: etapas base numeradas abaixo de 90 → módulos escolhidos → etapas próprias
(`steps.d/`) → etapas base numeradas a partir de 90 (`audit-after`, `summary`).

Toda etapa termina com um status: `done`, `ok`, `skipped`, `failed`, `would change` (dry-run) ou
`not selected` (módulo não escolhido). Se uma etapa falha, as seguintes são puladas e a execução
termina com código diferente de zero.

## preflight

Não altera nada. Confere: execução como root, Bash 5, sistema suportado (Ubuntu 22.04/24.04/26.04,
Debian 12/13), systemd como init (`GAIA_REQUIRE_SYSTEMD`), espaço livre em `/` (`GAIA_MIN_DISK_GB`) e
acesso HTTPS aos espelhos do apt e — só se forem usados — aos repositórios do Docker e do Caddy e ao
GitHub (`GAIA_CHECK_INTERNET`). Avisa quando roda dentro de um container. Registra os sockets que
escutam (`ss -tulpn`) para comparar no fim.

## audit-before

Instala o [Lynis](https://cisofy.com/lynis/) e roda `lynis audit system`, guardando o índice de
hardening e o relatório em `/var/lib/gaia/audit` (permissão 700). Desligue com `--no-audit` ou
`GAIA_AUDIT=0`. Uma falha do Lynis vira aviso, não falha da execução.

## packages

`apt-get update` (no máximo uma vez por `GAIA_APT_UPDATE_MAX_AGE` segundos), `full-upgrade` quando há
atualizações (`GAIA_APT_FULL_UPGRADE`) e os pacotes base, sem perguntas e sem recomendados:
`ca-certificates curl gnupg jq iproute2 ufw fail2ban python3-systemd unattended-upgrades sudo
openssh-server tzdata`, o cliente NTP (`chrony` ou `systemd-timesyncd`), `apparmor` e
`GAIA_EXTRA_PACKAGES`.

## time

Fuso horário (`GAIA_TIMEZONE`, padrão `UTC`) por `timedatectl` e sincronização NTP: `chrony` no
Debian e no Ubuntu 26.04, `systemd-timesyncd` nos demais (`GAIA_NTP_PACKAGE` muda isso).

## hostname

Só roda quando `GAIA_HOSTNAME` (ou `--hostname`) é informado. Aplica com `hostnamectl`, ajusta a
linha `127.0.1.1` do `/etc/hosts` (nome completo e curto) e grava
`/etc/cloud/cloud.cfg.d/99-gaia-hostname.cfg` com `preserve_hostname: true` para o cloud-init não
trocar o nome no próximo boot.

## admin-user

Cria (ou ajusta) a conta `GAIA_ADMIN_USER` com o shell `GAIA_ADMIN_SHELL`, no grupo `sudo`, e
instala as chaves públicas em `~/.ssh/authorized_keys` (700/600). Origem das chaves:

1. `GAIA_ADMIN_SSH_KEYS` / `--ssh-key`;
2. `GAIA_ADMIN_GITHUB_KEYS` / `--github-keys` (`https://github.com/<usuário>.keys`);
3. com `GAIA_ADMIN_IMPORT_KEYS=auto` e nenhuma das anteriores: as chaves de `/root/.ssh/authorized_keys`
   e do usuário do `sudo` (opções como o prefixo `command="echo Please login as..."` das imagens de
   nuvem são removidas).

Sem nenhuma chave válida a etapa falha — a Gaia não desliga o login por senha deixando você sem
acesso. Com `GAIA_ADMIN_SUDO_NOPASSWD=1` grava `/etc/sudoers.d/90-gaia-<usuário>` validado com
`visudo -c`.

## ssh

Escreve o drop-in `GAIA_SSH_DROPIN` (padrão `/etc/ssh/sshd_config.d/00-gaia.conf`, lido antes dos
demais) com:

```text
Port 22                          # GAIA_SSH_PORT
PermitRootLogin no               # GAIA_SSH_PERMIT_ROOT_LOGIN
PasswordAuthentication no        # GAIA_SSH_PASSWORD_AUTH
KbdInteractiveAuthentication no
PubkeyAuthentication yes
PermitEmptyPasswords no
HostbasedAuthentication no
IgnoreRhosts yes
PermitUserEnvironment no
MaxAuthTries 3                   # GAIA_SSH_MAX_AUTH_TRIES
LoginGraceTime 30                # GAIA_SSH_LOGIN_GRACE_TIME
ClientAliveInterval 300          # GAIA_SSH_CLIENT_ALIVE_INTERVAL
ClientAliveCountMax 2
AllowTcpForwarding local         # GAIA_SSH_TCP_FORWARDING
AllowAgentForwarding no          # GAIA_SSH_AGENT_FORWARDING
X11Forwarding no
LogLevel VERBOSE
AllowUsers <admin>               # GAIA_SSH_ALLOW_USERS
KexAlgorithms / Ciphers / MACs   # GAIA_SSH_MODERN_CRYPTO
```

Com `GAIA_SSH_MODERN_CRYPTO=1` ficam só algoritmos modernos — troca de chaves pós-quântica híbrida
(`mlkem768x25519-sha256`, `sntrup761x25519-sha512`) e `curve25519`, cifras AEAD/CTR e MACs
encrypt-then-MAC — filtrados pelo que o OpenSSH instalado suporta (`ssh -Q`).

Proteções contra ficar trancado para fora:

- o arquivo é validado com `sshd -t` antes de entrar;
- depois, `sshd -T` confere que os valores **efetivos** são os esperados (outro arquivo em
  `sshd_config.d` poderia sobrescrever); se não forem, o drop-in anterior volta;
- `AllowUsers` avisa quando deixa de fora usuários que têm `authorized_keys`;
- ao trocar a porta, a nova é liberada no `ufw` (com `limit`) **antes** do reload; no Ubuntu 24.04+
  o `ssh.socket` é reiniciado para escutar na nova porta;
- o serviço recebe `reload`, nunca `restart`: sua sessão atual continua.

## firewall

`ufw` com entrada negada e saída liberada por padrão, SSH liberado com `limit` (bloqueia mais de 6
conexões em 30 s de um mesmo IP; `GAIA_SSH_RATE_LIMIT=0` usa `allow`), depois as regras de
`GAIA_FIREWALL_ALLOW` / `--allow` (`porta/proto`, `início:fim/proto`), e só então `ufw enable`. Ao
trocar a porta do SSH, a regra antiga fica e um aviso pede para removê-la depois de testar a nova.

## fail2ban

`/etc/fail2ban/jail.d/gaia.local` com o jail `sshd` na porta configurada (`GAIA_FAIL2BAN_*`: bantime,
findtime, maxretry, backend, ignoreip), validado com `fail2ban-client -t` (com rollback) e aplicado
com `reload`.

## auto-updates

`unattended-upgrades` só com a origem de **segurança** da distribuição (as origens padrão são
limpas com `#clear`) e reboot automático desligado (`GAIA_AUTO_REBOOT=1` e
`GAIA_AUTO_REBOOT_TIME` ligam).

## sysctl

`/etc/sysctl.d/90-gaia-hardening.conf`, aplicado com `sysctl -e -q -p` (chaves que o kernel não
conhece são ignoradas):

- rede: `rp_filter` (anti-spoofing), sem `accept_redirects`/`secure_redirects`/`send_redirects`,
  sem source routing, `log_martians`, ignora broadcasts ICMP e erros ICMP falsos, `tcp_syncookies`,
  `tcp_rfc1337`;
- kernel: `kptr_restrict=2`, `dmesg_restrict=1`, `yama.ptrace_scope=1`,
  `unprivileged_bpf_disabled=1`, `bpf_jit_harden=2`, `randomize_va_space=2`, `sysrq=0`;
- sistema de arquivos: `protected_hardlinks/symlinks`, `protected_fifos/regular=2`,
  `suid_dumpable=0`.

O encaminhamento de IP **não** é alterado (o Docker precisa dele). `GAIA_SYSCTL_EXTRA` acrescenta
chaves (`chave=valor`). Pulada em containers; desligue com `GAIA_SYSCTL=0`.

## journald

`/etc/systemd/journald.conf.d/90-gaia.conf`: armazenamento persistente, comprimido e limitado a
`GAIA_JOURNALD_MAX_USE` (padrão 500M). Reinicia o `systemd-journald` só quando o arquivo muda.

## apparmor

Garante o serviço `apparmor` ativo e mostra quantos perfis estão carregados e em modo enforce. Se o
AppArmor está desligado no kernel, avisa e pula. Pulada em containers; `GAIA_APPARMOR=0` desliga.

## swap

Só com `GAIA_SWAP_SIZE` / `--swap` (ex.: `2G`). Cria `GAIA_SWAP_FILE` (600), ativa, registra no
`/etc/fstab` e grava `vm.swappiness` (`GAIA_SWAPPINESS`, padrão 10). Uma máquina que já tem swap não
é alterada. Pulada em containers.

## services

- Desliga (`systemctl disable --now`) `rpcbind`, `avahi-daemon` e `cups`, só quando estão
  habilitados ou rodando (`GAIA_DISABLE_UNUSED_SERVICES=0` mantém). `GAIA_DISABLE_SERVICES`
  acrescenta unidades.
- Servidor de e-mail local (`GAIA_MTA_LOCAL_ONLY=1`): `postfix` com `inet_interfaces=loopback-only`
  e `exim4` com `dc_local_interfaces='127.0.0.1 ; ::1'`.

## directories

Cria os diretórios de `GAIA_DIRS` (`caminho:dono:grupo:modo`, `@admin` = conta administradora) e
corrige dono e modo quando divergem.

## audit-after

Roda o Lynis de novo e mostra `Lynis hardening index: antes -> depois (+ganho)`, guardando o
histórico em `/var/lib/gaia/audit/history`.

## summary

Lista os sockets que escutam agora e a exposição de cada um:

| Exposição | Significado |
|-----------|-------------|
| `local only` | escuta só no loopback |
| `public, allowed by firewall` | aberto de propósito (regra no `ufw`) |
| `blocked by firewall` | escuta em todas as interfaces, mas o `ufw` bloqueia |
| `docker, filtered by ufw route rules` | porta de container filtrada pelo módulo `docker` |
| `EXPOSED (Docker bypasses ufw)` | porta de container aberta para a internet apesar do `ufw` |
| `EXPOSED (firewall inactive)` | escuta para fora com o firewall desligado |

Mostra também o que deixou de escutar desde o `preflight` e os próximos passos: testar o SSH numa
**nova** sessão, conferir o `sudo`, reiniciar se o sistema pedir.
