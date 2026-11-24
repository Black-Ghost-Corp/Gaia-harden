# Contribuindo com a Gaia

**Português** | [English](CONTRIBUTING.en.md)

Obrigado pelo interesse! Este guia explica como propor mudanças de um jeito que facilite a revisão.

## Antes de começar

- Para correções pequenas (typo, mensagem, teste), abra o PR direto.
- Para algo maior (novo módulo, nova etapa, mudança de comportamento padrão), abra antes uma
  [issue](https://github.com/Black-Ghost-Corp/Gaia-Bootstrapper/issues) descrevendo o problema e a
  proposta. Mudanças de padrão afetam todo servidor que roda a Gaia, então discutimos primeiro.
- Vulnerabilidades **não** vão em issues públicas: veja [SECURITY.md](SECURITY.md).
- Ao participar, você concorda com o [código de conduta](CODE_OF_CONDUCT.md).

## Ambiente

`scripts/test.sh` roda tudo em containers com versões fixas, então basta ter Docker:

```bash
scripts/test.sh                              # bats + shellcheck
scripts/test.sh bats /code/tests/15-ssh.bats # um arquivo só
scripts/test.sh integration ubuntu:24.04     # execução real num container descartável
```

Sem Docker, instale Bash 5, [bats-core](https://github.com/bats-core/bats-core) com `bats-support` e
`bats-assert`, [shellcheck](https://www.shellcheck.net/) 0.10+ e `jq`, e rode
`BATS_LIB_PATH=<pasta das bibliotecas> bats tests`.

## Regras do código

1. **Inglês** em código, comentários, logs e mensagens de erro. A documentação tem versões em
   português e inglês: atualize as duas.
2. **Toda mudança no sistema passa pelos helpers** (`gaia_run`, `gaia_ensure_file`,
   `gaia_ensure_dir`, `gaia_ufw_ensure`...). É isso que garante o `--dry-run`, o log e o status da
   etapa. Nunca escreva direto em `/etc` nem chame comandos que alteram o sistema fora deles.
3. **Idempotência.** Rodar duas vezes seguidas: a segunda não pode alterar nada (status `ok`).
   Todo teste de etapa nova cobre isso.
4. **Validar antes de trocar.** Arquivos que podem quebrar acesso ou serviços (sshd, sudoers, ufw,
   proxy) usam `gaia_ensure_checked_file` ou um validador, com rollback.
5. **Seguro por padrão, configurável.** Novos comportamentos que fecham algo vêm ligados; o que pode
   surpreender o usuário vem com variável `GAIA_*` documentada em `gaia.conf.example`, validada em
   `lib/config.sh`.
6. **Sem dependências novas** no servidor além do que vem nos pacotes oficiais da distribuição.
7. Cabeçalho `# gaia-description:` em cada etapa e módulo (aparece no `--list-steps` e no log).

## Testes

- Testes unitários ficam em `tests/NN-nome.bats` e rodam a Gaia contra uma raiz falsa com comandos
  simulados em `tests/fakes/fake-system.bash`. Se a sua etapa chama um comando novo do sistema,
  acrescente um simulador lá e o nome em `FAKE_COMMANDS` (`tests/test_helper.bash`).
- Cubra: máquina nova, segunda execução sem mudanças, `--dry-run` sem mutações e os casos de erro.
- Mudanças em instalação de pacotes ou serviços reais merecem também uma verificação em
  `tests/integration/run.sh`.

## Pull requests

- Um assunto por PR, com descrição do problema, da solução e de como foi testado.
- Commits no formato [Conventional Commits](https://www.conventionalcommits.org/) (`feat:`,
  `fix:`, `docs:`, `test:`...).
- O CI (bats, shellcheck e integração) precisa passar.
- Atualize o `CHANGELOG.md` na seção `Unreleased`.

Ao enviar uma contribuição, você concorda em licenciá-la sob a [Licença Apache 2.0](LICENSE).
