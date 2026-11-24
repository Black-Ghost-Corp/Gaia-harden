# Testes

**Português** | [English](../en/testing.md)

A Gaia tem três camadas de teste. As duas primeiras rodam no CI a cada PR.

## 1. Unitários (bats)

```bash
scripts/test.sh bats                          # todos, em container (bats 1.11 fixo)
scripts/test.sh bats /code/tests/15-ssh.bats  # um arquivo
```

Cada teste roda a Gaia **inteira** (`bootstrap.sh`) contra uma raiz falsa (`GAIA_ROOT`) com um
sistema simulado:

- `tests/test_helper.bash` cria a raiz (Ubuntu 24.04 recém-instalado, `sshd_config` padrão, `ufw`
  desligado...) e põe no `PATH` simuladores para os comandos que alteram ou consultam o sistema
  (`apt-get`, `systemctl`, `useradd`, `ufw`, `sshd`, `curl`, `lynis`, `docker`...);
- `tests/fakes/fake-system.bash` implementa os simuladores; o estado (usuários, pacotes, unidades,
  regras do ufw) fica em arquivos, e cada chamada é registrada em `calls.log`;
- asserções úteis: `assert_called`, `refute_called`, `assert_no_mutation` (nenhuma chamada que
  altera), `assert_status etapa status`, `force_failure comando código`.

Nenhum teste toca a máquina onde roda.

## 2. shellcheck

```bash
scripts/test.sh shellcheck
```

## 3. Integração (containers)

```bash
scripts/test.sh integration                 # Ubuntu 22.04/24.04/26.04, Debian 12/13
scripts/test.sh integration debian:13
```

`tests/integration/run.sh` roda a Gaia **de verdade** num container descartável (apt, usuários,
sudoers, `sshd -t`/`-T`, `ufw` com `NET_ADMIN`, fail2ban). Como containers não têm systemd,
`systemctl`, `timedatectl` e `hostnamectl` são substituídos por versões mínimas. O script confere:

1. o `--dry-run` não altera nada;
2. a primeira execução termina sem falhas;
3. a segunda execução não altera nada;
4. o resultado: conta no `sudo`, chave instalada, root e senha desligados no SSH efetivo,
   `AllowUsers`, `ufw` ativo com `LIMIT` no SSH, fail2ban válido, fuso horário, arquivos de
   configuração.

## Testando numa VM (recomendado antes de produção)

Kernel, AppArmor, swap, systemd e reload do SSH só são exercitados de verdade numa máquina completa.
Use uma VM descartável (Multipass, VirtualBox, uma VPS de teste):

```bash
# Ubuntu com Multipass
multipass launch 24.04 --name gaia-test
multipass transfer -r . gaia-test:/home/ubuntu/gaia   # ou git clone dentro da VM
multipass shell gaia-test

cd ~/gaia
sudo ./bootstrap.sh --dry-run --admin-user ubuntu --github-keys sua-conta
sudo ./bootstrap.sh --yes --admin-user ubuntu --github-keys sua-conta --modules docker
sudo ./bootstrap.sh --yes --admin-user ubuntu --github-keys sua-conta --modules docker   # deve mostrar tudo "ok"
```

Antes de fechar a sessão, abra outra e confirme que consegue entrar com a chave. Se algo der
errado, o console da VM continua disponível.
