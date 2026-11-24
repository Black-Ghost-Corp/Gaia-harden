# Política de segurança

**Português** | [English](SECURITY.en.md)

A Gaia configura a segurança de servidores; uma falha nela pode deixar muitas máquinas expostas.
Levamos relatos a sério e agradecemos a quem os faz de forma responsável.

## Versões suportadas

| Versão | Suporte |
|--------|---------|
| última release `0.x` | :white_check_mark: |
| anteriores | :x: |

## Como relatar

**Não abra issues, discussões nem PRs públicos para vulnerabilidades.**

Use o [relato privado de vulnerabilidades do GitHub](https://github.com/Black-Ghost-Corp/Gaia-Bootstrapper/security/advisories/new)
e inclua, se possível:

- a versão (`./bootstrap.sh --version`) e o sistema (`/etc/os-release`);
- o que acontece e o impacto (ex.: porta exposta, configuração que permite login por senha);
- passos para reproduzir e a saída relevante do log (`/var/log/gaia/`), **sem segredos**.

## O que esperar

- Confirmação de recebimento em até **3 dias úteis**.
- Avaliação inicial e plano de correção em até **10 dias úteis**.
- Correção publicada numa release, com aviso de segurança (GHSA) e crédito a quem relatou, se
  desejar.

## Escopo

Dentro do escopo: o código deste repositório (`bootstrap.sh`, `lib/`, `install.sh`, `scripts/`) e
as configurações que ele gera. Fora do escopo: vulnerabilidades nos pacotes de terceiros que a Gaia
instala (OpenSSH, Docker, Caddy, etc.) — relate-as aos respectivos projetos.
