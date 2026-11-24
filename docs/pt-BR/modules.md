# Módulos

**Português** | [English](../en/modules.md)

Módulos são software opcional que a Gaia instala **já configurado com segurança**. Eles rodam depois
das etapas base e antes das etapas próprias. Escolha com:

```bash
sudo ./bootstrap.sh --modules docker,caddy   # ou "all" / "none"
```

ou `GAIA_MODULES="docker caddy"` no `gaia.conf`. Sem nenhuma escolha e com terminal disponível, a
Gaia mostra um menu. Módulos não escolhidos aparecem com status `not selected`.

## docker

Instala Docker Engine, CLI, containerd, buildx e compose do **repositório oficial** do Docker.

O que o módulo garante (cada parte só age se precisar):

1. **Pacotes conflitantes removidos** (`docker.io`, `docker-compose`, `podman-docker`, `containerd`,
   `runc`...), mantendo os dados em `/var/lib/docker`.
2. **Repositório verificado**: a chave GPG é baixada por HTTPS e comparada com a impressão digital
   oficial (`9DC8 5822 9FC7 DD38 854A E2D8 8D81 803C 0EBF CD88`) antes de entrar no apt.
3. **`/etc/docker/daemon.json` mesclado** com `jq` (chaves que você já tinha são mantidas): rotação
   de logs (`GAIA_DOCKER_LOG_MAX_SIZE`, `GAIA_DOCKER_LOG_MAX_FILE`), `live-restore`, `data-root`
   opcional (`GAIA_DOCKER_DATA_ROOT`; dados antigos **não** são movidos) e, com
   `GAIA_DOCKER_LOCALHOST_ONLY=1`, `"ip": "127.0.0.1"` — portas publicadas sem IP passam a escutar só
   no loopback. Um `daemon.json` inválido faz a etapa falhar sem ser sobrescrito.
4. **Grupo `docker`** para a conta administradora (`GAIA_DOCKER_ADD_ADMIN_TO_GROUP`), com aviso: esse
   grupo equivale a root.
5. **`ufw` valendo para containers** (`GAIA_DOCKER_UFW=1`, veja abaixo).
6. Serviço habilitado e um teste `docker run --rm hello-world` (`GAIA_DOCKER_SMOKE_TEST`).

### Docker e ufw

O Docker escreve regras próprias de iptables para as portas publicadas (`-p 8080:80`), e elas são
avaliadas **antes** das regras do `ufw`. Resultado: o firewall nega tudo, mas o container está aberto
para a internet.

O módulo acrescenta ao `/etc/ufw/after.rules` um bloco delimitado por
`# BEGIN GAIA DOCKER-USER` / `# END GAIA DOCKER-USER` que faz a cadeia `DOCKER-USER` passar pelas
regras de encaminhamento do `ufw` (a mesma abordagem do projeto
[ufw-docker](https://github.com/chaifeng/ufw-docker)):

- tráfego de redes privadas (10/8, 172.16/12, 192.168/16) e respostas continuam passando;
- conexões novas vindas da internet para containers são bloqueadas e registradas
  (`[UFW DOCKER BLOCK]`), **a menos** que exista uma regra `ufw route allow`;
- o arquivo é validado com `ufw reload`; se falhar, o anterior volta.

Para abrir uma porta de container para a internet, use a porta **do container** (em `-p 8080:80`, é a
80):

```bash
# gaia.conf
GAIA_DOCKER_PUBLISH="80/tcp 443/tcp"
# equivale a: ufw route allow proto tcp from any to any port 80
```

A auditoria de portas do `summary` mostra `docker, filtered by ufw route rules` para portas filtradas
e `EXPOSED (Docker bypasses ufw)` quando o módulo não foi aplicado.

> [!TIP]
> Para aplicações atrás de um proxy reverso no próprio host (módulo `caddy`), publique as portas só no
> loopback (`-p 127.0.0.1:8080:8080`) ou use `GAIA_DOCKER_LOCALHOST_ONLY=1`.

## caddy

Instala o [Caddy](https://caddyserver.com/) do **repositório oficial** (chave conferida por impressão
digital `6576 0C51 EDEA 2017 CEA2 CA15 155B 6D79 CA56 EA34`) como serviço do host: ele escuta em 80 e
443, obtém e renova certificados (Let's Encrypt) e repassa para a aplicação, que fica em
`127.0.0.1`.

Configuração:

```bash
# "domínio=destino" separados por espaço; destino host:porta ou h2c://host:porta (gRPC sem TLS)
GAIA_CADDY_SITES="app.example.com=127.0.0.1:8080 api.example.com=127.0.0.1:9000"
GAIA_CADDY_EMAIL="ops@example.com"          # conta ACME (opcional)
GAIA_CADDY_BLOCK_PATHS="/internal/* /metrics" # respondem 403 em todos os sites
```

O `/etc/caddy/Caddyfile` gerado tem:

- o snippet `gaia_blocks` em todo site: os caminhos de `GAIA_CADDY_BLOCK_PATHS` respondem 403;
- o snippet `gaia_headers`: `Strict-Transport-Security`, `X-Content-Type-Options: nosniff`,
  `Referrer-Policy: strict-origin-when-cross-origin` e remoção do cabeçalho `Server`;
- `reverse_proxy` com `flush_interval -1` (server-sent events e streaming sem buffer);
- `import /etc/caddy/sites.d/*.caddy` para sites escritos à mão (use `import gaia_blocks` e
  `import gaia_headers` neles também).

O arquivo novo é validado com `caddy validate` **antes** de substituir o atual; se for recusado, o
atual fica e a etapa falha. Mudanças aplicam com `systemctl reload caddy` (sem derrubar conexões). O
módulo libera 80/tcp e 443/tcp no `ufw`.

> [!NOTE]
> O certificado só sai quando o DNS do domínio aponta para o servidor e as portas 80/443 também estão
> abertas no firewall do provedor. Acompanhe com `journalctl -u caddy -f`.

## Escrevendo um módulo novo

Um módulo é um arquivo `lib/modules/NN-nome.sh` com o cabeçalho `# gaia-description:` e uma função
`step_run`, no mesmo formato das etapas base. Ele é descoberto automaticamente e entra no menu, em
`--modules` e em `--list-steps`. Veja o [guia de contribuição](../../CONTRIBUTING.md) e o
[roadmap](../../README.md#roadmap) para os módulos planejados.
