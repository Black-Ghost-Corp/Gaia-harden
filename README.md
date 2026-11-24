# Gaia Harden

[![CI](https://github.com/Black-Ghost-Corp/gaia-harden/actions/workflows/ci.yml/badge.svg)](https://github.com/Black-Ghost-Corp/gaia-harden/actions/workflows/ci.yml)
[![Licença](https://img.shields.io/badge/licen%C3%A7a-Apache%202.0-blue.svg)](LICENSE)
[![Release](https://img.shields.io/github/v/release/Black-Ghost-Corp/gaia-harden?include_prereleases&sort=semver)](https://github.com/Black-Ghost-Corp/gaia-harden/releases)
![Plataformas](https://img.shields.io/badge/Ubuntu-22.04%20%7C%2024.04%20%7C%2026.04-E95420?logo=ubuntu&logoColor=white)
![Plataformas](https://img.shields.io/badge/Debian-12%20%7C%2013-A81D33?logo=debian&logoColor=white)

**Português** | [English](README.en.md)

Gaia transforma um servidor Ubuntu ou Debian recém-criado (VPS, máquina dedicada ou VM) em um host
endurecido com **um único comando**: conta administradora com chave SSH, SSH blindado, firewall
fechando tudo o que não precisa estar aberto, fail2ban, atualizações de segurança automáticas,
hardening de kernel e rede, auditoria de segurança antes e depois — e, se você quiser, software
como Docker e Caddy **já instalados de forma segura**.

É Bash puro, sem agentes nem dependências externas, idempotente (rodar de novo não muda nada que já
esteja certo) e com `--dry-run` para ver tudo o que seria alterado antes de alterar.

```bash
git clone https://github.com/Black-Ghost-Corp/gaia-harden.git
cd gaia-harden
sudo ./bootstrap.sh --dry-run   # mostra o que mudaria, sem mudar nada
sudo ./bootstrap.sh             # aplica
```

> [!IMPORTANT]
> Gaia desliga o login de root e por senha no SSH. Ela só faz isso depois de garantir que a conta
> administradora tem uma chave pública válida, e o resumo final pede para você testar o acesso numa
> **nova** sessão antes de fechar a atual. Leia a seção [Antes de rodar](#antes-de-rodar).

## Sumário

- [Por que Gaia](#por-que-gaia)
- [O que ela faz](#o-que-ela-faz)
- [Antes de rodar](#antes-de-rodar)
- [Início rápido](#início-rápido)
- [Usando com agentes de IA](#usando-com-agentes-de-ia)
- [Módulos](#módulos)
- [Configuração](#configuração)
- [Como funciona](#como-funciona)
- [Etapas próprias](#etapas-próprias)
- [Compatibilidade](#compatibilidade)
- [Desenvolvimento e testes](#desenvolvimento-e-testes)
- [Roadmap](#roadmap)
- [Contribuindo](#contribuindo)
- [Segurança](#segurança)
- [Licença](#licença)

## Por que Gaia

Todo servidor novo exposto na internet recebe tentativas de login em minutos. O checklist para
deixá-lo minimamente seguro é sempre o mesmo e fácil de errar à mão: um `AllowUsers` esquecido, um
firewall ligado antes de liberar o SSH, um container do Docker publicando uma porta que o `ufw`
nunca vê.

Gaia codifica esse checklist de forma **verificável**:

- **Seguro por padrão.** Nada de login de root, nada de senha no SSH, firewall negando entrada.
- **Sem se trancar para fora.** A configuração do SSH é validada com `sshd -t` e conferida com
  `sshd -T` antes de valer; se algo não bate, ela é revertida. O firewall libera o SSH antes de ligar.
- **Transparente.** Cada ação vira uma linha de log (`[gaia][nível][step=x] mensagem chave=valor`);
  segredos são mascarados; o `--dry-run` mostra exatamente o que mudaria.
- **Mensurável.** O [Lynis](https://cisofy.com/lynis/) roda antes e depois e mostra o ganho no
  índice de hardening (ex.: `Lynis hardening index: 58 -> 81 (+23)`). As portas que escutam são
  auditadas no início e no fim, indicando o que está exposto à internet.
- **Idempotente.** Rodar de novo só corrige o que saiu do lugar.

## O que ela faz

| # | Etapa | O que garante |
|---|-------|---------------|
| 1 | `preflight` | root, sistema suportado, espaço em disco, acesso aos repositórios, systemd; registra o que está escutando (não altera nada) |
| 2 | `audit-before` | auditoria Lynis inicial (índice de hardening de referência) |
| 3 | `packages` | `apt update`, `full-upgrade` (configurável) e pacotes base |
| 4 | `time` | fuso horário e sincronização NTP |
| 5 | `hostname` | nome do host em `hostnamectl`, `/etc/hosts` e preservado pelo cloud-init |
| 6 | `admin-user` | conta administradora no grupo `sudo`, com chaves SSH (literais, do GitHub ou importadas do provedor) |
| 7 | `ssh` | drop-in com root e senha desligados, criptografia moderna, `AllowUsers`, `MaxAuthTries`, `LoginGraceTime`; validado e com rollback |
| 8 | `firewall` | `ufw` negando entrada, SSH com `limit` (anti-flood) liberado antes de ligar, regras extras |
| 9 | `fail2ban` | jail `sshd` na porta configurada |
| 10 | `auto-updates` | `unattended-upgrades` só com atualizações de segurança; reboot automático opcional |
| 11 | `sysctl` | anti-spoofing, sem redirects, SYN cookies, informações do kernel restritas |
| 12 | `journald` | journal persistente, comprimido e com limite de disco |
| 13 | `apparmor` | AppArmor ativo e carregando perfis |
| 14 | `swap` | arquivo de swap opcional para VPS pequenas, com swappiness baixa |
| 15 | `services` | desliga serviços de rede raramente necessários (rpcbind, avahi, cups) e prende o servidor de e-mail local no loopback |
| 16 | `directories` | diretórios com dono e permissão (ex.: `/srv/apps`) |
| — | módulos | software opcional já endurecido (veja [Módulos](#módulos)) |
| — | etapas próprias | seus scripts em `steps.d/` |
| 19 | `audit-after` | auditoria Lynis final, comparada com a inicial |
| 20 | `summary` | o que escuta agora, o que foi fechado e os próximos passos |

Detalhes de cada etapa: [docs/pt-BR/steps.md](docs/pt-BR/steps.md).

## Antes de rodar

1. **Tenha uma chave SSH pública** para a conta administradora. Gaia aceita qualquer uma destas
   fontes, nesta ordem:
   - `--ssh-key "ssh-ed25519 AAAA... voce@notebook"` (ou `GAIA_ADMIN_SSH_KEYS` no `gaia.conf`);
   - `--github-keys seu-usuario` (importa `https://github.com/seu-usuario.keys`);
   - as chaves que o provedor da VPS já colocou em `/root/.ssh/authorized_keys` (importadas
     automaticamente quando nenhuma outra foi informada).
2. **Mantenha a sessão atual aberta** até conseguir entrar pela nova conta numa segunda sessão.
3. **Libere no firewall do provedor** (security group, cloud firewall) as mesmas portas que você
   liberar no Gaia, como 80/443 para um site.
4. Rode primeiro com `--dry-run`.

## Início rápido

### Pelo repositório (recomendado)

```bash
git clone https://github.com/Black-Ghost-Corp/gaia-harden.git
cd gaia-harden

# Interativo: pergunta a conta administradora e os módulos.
sudo ./bootstrap.sh

# Não interativo: tudo pela linha de comando.
sudo ./bootstrap.sh --yes \
  --admin-user alice \
  --github-keys alice \
  --modules docker,caddy \
  --allow 80/tcp,443/tcp \
  --hostname web-01.example.com \
  --timezone America/Sao_Paulo \
  --swap 2G
```

### Pelo instalador de release

A partir da primeira release publicada, o instalador baixa a versão, confere o SHA-256 (e a
assinatura Ed25519, quando a release é assinada) **antes** de executar qualquer coisa:

```bash
curl -fsSL https://github.com/Black-Ghost-Corp/gaia-harden/releases/latest/download/install.sh | sudo bash
# com opções:
curl -fsSL https://github.com/Black-Ghost-Corp/gaia-harden/releases/latest/download/install.sh \
  | sudo bash -s -- --modules docker --admin-user alice --yes
```

A release fica em `/opt/gaia/releases/<versão>` (com o link `/opt/gaia/current`), e um
`/opt/gaia/gaia.conf` é usado automaticamente quando existe.

### Opções

```text
--modules LIST       módulos opcionais, separados por vírgula (ex.: docker,caddy; "none" ou "all")
--admin-user NAME    conta administradora (padrão: o usuário que rodou o sudo)
--ssh-key KEY        chave pública da conta administradora (repetível)
--github-keys USER   importa chaves de https://github.com/USER.keys (repetível)
--ssh-port PORT      porta do SSH (padrão 22)
--allow RULES        regras extras de entrada no firewall (ex.: 80/tcp,443/tcp)
--hostname NAME      nome do host
--timezone TZ        fuso horário (padrão UTC)
--swap SIZE          cria um arquivo de swap (ex.: 2G)
--no-audit           não roda a auditoria Lynis
--config FILE        arquivo de configuração (padrão: gaia.conf ao lado do bootstrap.sh, se existir)
--dry-run            mostra o que cada etapa mudaria, sem mudar nada
--report-json FILE   grava um relatório da execução em JSON (veja docs/pt-BR/report.md)
--only LIST          roda só estas etapas
--skip LIST          pula estas etapas
--list-steps         lista as etapas
--yes, -y            não pergunta nada
```

## Usando com agentes de IA

A Gaia vem com uma skill, `/gaia`, para agentes de IA (Claude Code, Codex, Cursor e outros). Você
diz `/gaia root@203.0.113.10` e o agente conduz tudo com segurança:
- pergunta só o necessário: conta administradora, chave pública, módulos e portas;
- roda o **dry-run** e mostra o que vai mudar;
- só aplica depois do seu "sim", mantendo a conexão atual aberta como rede de segurança;
- **testa o login numa sessão nova** antes de dar o trabalho por encerrado;
- termina com um resumo do [relatório JSON](docs/pt-BR/report.md): portas expostas, ganho no Lynis,
  reboot pendente e próximos passos.

O agente nunca pede senhas nem chaves privadas: o SSH usa o seu próprio `ssh-agent`.

### Instalação com um prompt

Cole no seu agente:

```text
Instale a skill "gaia" do Gaia Harden para mim. Antes de copiar qualquer coisa, me mostre o plano
e os caminhos que vai usar.
1. Baixe o repositório: git clone --depth 1 https://github.com/Black-Ghost-Corp/gaia-harden.git
   numa pasta temporária.
2. Copie a pasta skills/gaia (SKILL.md e scripts/) para a pasta de skills do agente:
   - Claude Code: ~/.claude/skills/gaia/ (todos os projetos). Pergunte se prefiro
     .claude/skills/gaia/ só neste projeto.
   - Outros agentes: o equivalente de vocês; se não houver, guarde a pasta e use o AGENTS.md do
     repositório como instrução.
3. Deixe scripts/gaia-remote.sh executável, liste os arquivos copiados e mostre as primeiras
   linhas do SKILL.md.
4. Apague a pasta temporária.
5. Explique como usar: /gaia usuario@servidor [--modules docker,caddy].
Não me peça senhas, tokens nem chaves privadas em nenhum momento.
```

### Instalação manual

```bash
git clone --depth 1 https://github.com/Black-Ghost-Corp/gaia-harden.git /tmp/gaia-harden
mkdir -p ~/.claude/skills
cp -r /tmp/gaia-harden/skills/gaia ~/.claude/skills/gaia
chmod +x ~/.claude/skills/gaia/scripts/gaia-remote.sh
rm -rf /tmp/gaia-harden
```

Em outros agentes, copie `skills/gaia/` para a pasta de skills ou de instruções dele, ou aponte o
agente para o [AGENTS.md](AGENTS.md). O script `skills/gaia/scripts/gaia-remote.sh` também funciona
sozinho, sem agente (`gaia-remote.sh --help`).

## Módulos

Módulos instalam software **já configurado com segurança**. Escolha com `--modules`, com
`GAIA_MODULES` no `gaia.conf` ou pelo menu interativo.

| Módulo | O que instala | Segurança aplicada |
|--------|---------------|--------------------|
| `docker` | Docker Engine, compose e buildx do repositório oficial | chave GPG conferida por impressão digital; rotação de logs e `live-restore`; **portas publicadas por containers passam a respeitar o `ufw`** (cadeia `DOCKER-USER`), abertas só com `GAIA_DOCKER_PUBLISH`; opção de publicar só em `127.0.0.1`; aviso de que o grupo `docker` equivale a root |
| `caddy` | Caddy (proxy reverso com HTTPS automático) do repositório oficial | chave conferida; `Caddyfile` validado com `caddy validate` antes de trocar; HSTS, `nosniff`, `Referrer-Policy`, sem cabeçalho `Server`; caminhos internos bloqueados com 403; reload sem derrubar conexões |

> [!NOTE]
> Por padrão o Docker insere regras próprias no iptables e **ignora o `ufw`**: um
> `docker run -p 5432:5432` fica aberto para a internet mesmo com o firewall "negando tudo". O módulo
> `docker` corrige isso, e a auditoria de portas no fim marca esses casos como `EXPOSED`.

Detalhes: [docs/pt-BR/modules.md](docs/pt-BR/modules.md).

## Configuração

Tudo é opcional. Para uso recorrente (várias máquinas iguais), copie o exemplo e ajuste:

```bash
cp gaia.conf.example gaia.conf
chmod 600 gaia.conf
sudo ./bootstrap.sh            # usa ./gaia.conf automaticamente
```

Precedência: **linha de comando > `gaia.conf` > variáveis de ambiente > padrões**. Valores inválidos
são recusados antes de qualquer etapa rodar. Todas as chaves estão documentadas em
[`gaia.conf.example`](gaia.conf.example) e em [docs/pt-BR/configuration.md](docs/pt-BR/configuration.md).

## Como funciona

- **Etapas idempotentes.** Cada etapa termina com um status: `done` (alterou), `ok` (já estava
  certo), `skipped`, `failed`, `would change` (no dry-run) ou `not selected` (módulo não escolhido).
- **Arquivos validados antes de entrar.** Configurações críticas (sshd, sudoers, fail2ban, regras do
  ufw, Caddyfile) são escritas num temporário, validadas pela própria ferramenta e só então trocadas;
  se a validação falha, o arquivo anterior fica.
- **Repositórios de terceiros conferidos.** Chaves GPG são baixadas por HTTPS e comparadas com a
  impressão digital esperada antes de qualquer `apt`.
- **Logs.** Saída na tela e em `/var/log/gaia/gaia-<data>.log` (permissão 700), com segredos
  mascarados. Uma trava impede duas execuções simultâneas.

## Etapas próprias

Coloque scripts executáveis em `steps.d/` (ou em `GAIA_EXTRA_STEPS_DIR`). Eles rodam depois dos
módulos, recebem a configuração e seguem o mesmo contrato de log, dry-run e status:

```bash
#!/usr/bin/env bash
# gaia-description: cria a rede docker da aplicação
source "$GAIA_LIB_DIR/common.sh"
gaia_step_mode

docker network inspect app >/dev/null 2>&1 || gaia_run docker network create app
```

Guia completo: [docs/pt-BR/custom-steps.md](docs/pt-BR/custom-steps.md).

## Compatibilidade

| Sistema | Versões | Arquiteturas |
|---------|---------|--------------|
| Ubuntu Server | 22.04 LTS, 24.04 LTS, 26.04 LTS | amd64, arm64 |
| Debian | 12 (bookworm), 13 (trixie) | amd64, arm64 |

Requer Bash 5, systemd e acesso root. Dentro de containers as etapas de kernel, swap e AppArmor são
puladas (pertencem ao host).

## Desenvolvimento e testes

```bash
scripts/test.sh               # bats (unitários com sistema falso) + shellcheck
scripts/test.sh integration   # execução real em containers Ubuntu/Debian descartáveis
```

Os testes unitários rodam a Gaia inteira contra uma raiz falsa (`GAIA_ROOT`) com comandos do
sistema substituídos por simuladores, sem tocar a máquina. Veja
[docs/pt-BR/testing.md](docs/pt-BR/testing.md) para testar numa VM.

## Roadmap

Próximos passos, em ordem aproximada de prioridade. Sugestões e PRs são bem-vindos: abra uma
[issue](https://github.com/Black-Ghost-Corp/gaia-harden/issues) para discutir antes de
começar algo grande.

**Curto prazo**

- [ ] Primeira release assinada (Ed25519) e instalador publicado nas releases do GitHub
- [x] Relatório final em JSON (`--report-json`); falta a versão em Markdown para anexar a auditorias
- [x] Skill `/gaia` para agentes de IA; próximo: servidor MCP
- [ ] `auditd` com regras base e `AIDE` (integridade de arquivos)
- [ ] Modo `--check`: só verifica a conformidade e sai com código diferente de zero se algo divergir
- [ ] Perfis prontos (`--profile web`, `--profile docker-host`, `--profile bastion`)

**Novos módulos**

- [ ] Proxies reversos: Nginx e Traefik endurecidos
- [ ] Containers: Podman e Docker rootless; k3s com configuração CIS
- [ ] Bancos de dados: PostgreSQL, MariaDB, Redis e MongoDB presos no loopback, com autenticação
      forte e backups
- [ ] Acesso privado: Tailscale e WireGuard (SSH só pela VPN)
- [ ] Defesa ativa: CrowdSec como alternativa/complemento ao fail2ban
- [ ] Observabilidade: node_exporter, Netdata e Uptime Kuma atrás do proxy, sem portas públicas
- [ ] Backups: restic ou borg com agendamento e verificação
- [ ] Runtimes: Node.js, Python e Go por gerenciadores de versão
- [ ] Runners de CI auto-hospedados isolados
- [ ] Alertas (e-mail, Telegram, Slack) para login, ban e atualização pendente

**Plataformas**

- [ ] Família RHEL (Rocky, AlmaLinux) com `firewalld` e SELinux
- [ ] Imagens de nuvem: cloud-init `user-data` pronto para os principais provedores
- [ ] Mirror próprio de downloads como alternativa ao GitHub

## Contribuindo

Contribuições são muito bem-vindas! Leia o [guia de contribuição](CONTRIBUTING.md) e o
[código de conduta](CODE_OF_CONDUCT.md). Em resumo: o código e os logs são em inglês, cada mudança
vem com testes bats e passa no `shellcheck`, e nada que mude o sistema pode fugir do `--dry-run`.

## Segurança

Encontrou uma vulnerabilidade? **Não abra uma issue pública.** Siga a
[política de segurança](SECURITY.md) e use o
[relato privado do GitHub](https://github.com/Black-Ghost-Corp/gaia-harden/security/advisories/new).

## Licença

Copyright © 2026 Black Ghost Corporation. Distribuído sob a [Licença Apache 2.0](LICENSE). Veja também o arquivo [NOTICE](NOTICE).

Gaia altera configurações de segurança do servidor. Ela é fornecida "no estado em que se encontra",
sem garantias; revise o `--dry-run` e teste numa máquina descartável antes de usar em produção.
