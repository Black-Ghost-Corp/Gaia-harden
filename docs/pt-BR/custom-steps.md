# Etapas próprias

**Português** | [English](../en/custom-steps.md)

Etapas próprias deixam você acrescentar o que é específico do seu ambiente (redes Docker, usuários
de aplicação, cron de backup, agentes de monitoramento) sem modificar a Gaia, com o mesmo log,
dry-run e status das etapas base.

## Onde ficam

Todo arquivo **executável** `*.sh` em `steps.d/` (ao lado do `bootstrap.sh`) ou em
`GAIA_EXTRA_STEPS_DIR`. Eles rodam em ordem lexical, **depois dos módulos** e antes de `audit-after`
e `summary`. O nome da etapa é `custom:` + o nome do arquivo sem o prefixo numérico e sem `.sh`:
`steps.d/10-app-network.sh` vira `custom:app-network`.

```bash
sudo ./bootstrap.sh --list-steps
sudo ./bootstrap.sh --only custom:app-network
sudo ./bootstrap.sh --skip custom:app-network
```

Um arquivo sem permissão de execução é pulado com aviso.

## Modelo

```bash
#!/usr/bin/env bash
# gaia-description: rede docker "app" e diretório de dados da aplicação
# shellcheck source=/dev/null
source "$GAIA_LIB_DIR/common.sh"
gaia_step_mode

if docker network inspect app >/dev/null 2>&1; then
  gaia_info "docker network already exists" "network=app"
else
  gaia_run docker network create app
fi

gaia_ensure_dir /srv/app/data 0750 "$GAIA_ADMIN_USER:$GAIA_ADMIN_USER"
```

- `# gaia-description:` aparece no `--list-steps` e no log.
- `gaia_step_mode` liga `set -Eeuo pipefail` e o trap de erro: um comando que falha encerra a etapa
  com arquivo e linha no log.
- Toda a configuração chega como variáveis `GAIA_*` exportadas (`GAIA_ADMIN_USER`, `GAIA_SSH_PORT`,
  `GAIA_DRY_RUN`, `GAIA_MODULES`...). Variáveis próprias também podem ir no `gaia.conf`, desde que
  comecem com `GAIA_`.

## Helpers

| Helper | O que faz |
|--------|-----------|
| `gaia_info`, `gaia_warn`, `gaia_error`, `gaia_debug` `"mensagem" chave=valor...` | log no formato da Gaia, com segredos mascarados |
| `gaia_run comando args...` | executa um comando que **altera** o sistema; no dry-run só diz o que faria; marca a etapa como alterada |
| `gaia_ensure_file caminho modo conteúdo [sensível] [validador]` | garante o conteúdo e o modo de um arquivo, mostrando o diff |
| `gaia_ensure_checked_file caminho modo conteúdo descrição comando...` | igual, mas roda `comando` depois de trocar e volta o arquivo anterior se falhar |
| `gaia_ensure_dir caminho modo [dono:grupo]` | garante um diretório |
| `gaia_ensure_owner caminho dono:grupo` | garante o dono |
| `gaia_ufw_ensure regra...` | acrescenta uma regra do `ufw` se ainda não existir (ex.: `allow 8443/tcp`) |
| `gaia_apt_install pacote...` | instala pacotes que faltam |
| `gaia_package_installed pacote` | testa se um pacote está instalado |
| `gaia_is_dry_run` | verdadeiro no `--dry-run` |
| `gaia_skip "motivo"` | encerra a etapa com status `skipped` |
| `gaia_fail "mensagem"` | encerra a etapa com status `failed` |
| `gaia_path /etc/x` | caminho real considerando `GAIA_ROOT` (testes) |

## Regras

1. **Nada que altera o sistema fora dos helpers.** Comandos de leitura (`docker network inspect`,
   `getent`, `grep`) podem rodar direto; os que alteram passam por `gaia_run` ou `gaia_ensure_*`.
   É isso que mantém o `--dry-run` confiável.
2. **Idempotência:** verifique antes de agir. Na segunda execução o status deve ser `ok`.
3. **Sem segredos no código.** Leia-os de arquivos com permissão 600 fora do repositório.

## Status

| Situação | Status |
|----------|--------|
| algum `gaia_run`/`gaia_ensure_*` alterou algo | `done` (`would change` no dry-run) |
| nada precisou mudar | `ok` |
| `gaia_skip` | `skipped` |
| saída diferente de zero | `failed` (as etapas seguintes são puladas) |
