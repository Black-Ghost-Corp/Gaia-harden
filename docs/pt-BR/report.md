# Relatório JSON (`--report-json`)

**Português** | [English](../en/report.md)

Com `--report-json ARQUIVO`, a Gaia grava no fim da execução um relatório legível por máquina:
ideal para automação, CI, inventário de servidores e agentes de IA (veja
[Usando com agentes de IA](../../README.md#usando-com-agentes-de-ia)).

```bash
sudo ./bootstrap.sh --yes --report-json /root/gaia-report.json
sudo jq '{result, lynis, exposed: .ports.exposed_after, reboot_required}' /root/gaia-report.json
```

- É gravado em **toda execução que chega a rodar etapas**: real, `--dry-run` ou com falha
  (`"result": "failed"`). Erros de uso (opção inválida, configuração recusada) encerram antes,
  com código 2, sem relatório.
- O diretório precisa existir; o arquivo é criado com permissão 600 e substituído de forma atômica.
- Avisos e erros vêm das linhas de log, com segredos já mascarados.

## Formato (`"schema": "gaia-report/1"`)

```json
{
  "schema": "gaia-report/1",
  "gaia_version": "0.1.0",
  "dry_run": false,
  "result": "success",
  "failures": 0,
  "started_at": "2026-11-24T16:00:00Z",
  "finished_at": "2026-11-24T16:14:02Z",
  "duration_s": 842.113,
  "system": {"os_id": "ubuntu", "os_version": "24.04", "os_codename": "noble", "arch": "amd64", "hostname": "web-01"},
  "config": {"admin_user": "ops", "ssh_port": 22, "modules": ["docker", "caddy"], "firewall_allow": ["80/tcp", "443/tcp"], "audit": true},
  "steps": [
    {"name": "preflight", "kind": "base", "status": "ok", "duration_s": 1.226},
    {"name": "docker", "kind": "module", "status": "done", "duration_s": 106.287}
  ],
  "ports": {
    "before": [{"proto": "tcp", "address": "0.0.0.0", "port": 22, "process": "sshd", "exposure": "EXPOSED (firewall inactive)", "exposed": true}],
    "after": [{"proto": "tcp", "address": "0.0.0.0", "port": 22, "process": "sshd", "exposure": "public, allowed by firewall", "exposed": false}],
    "closed": [],
    "exposed_after": 0
  },
  "lynis": {"before": 59, "after": 72, "gain": 13},
  "reboot_required": true,
  "warnings": [{"step": "summary", "message": "the system asks for a reboot; reboot after confirming access through the new session"}],
  "errors": [],
  "next_steps": ["open a NEW session and test: ssh -p 22 ops@203.0.113.10 (do NOT close this session before logging in through the new one)"],
  "log_file": "/var/log/gaia/gaia-20261124T160000Z.log"
}
```

| Campo | Significado |
|-------|-------------|
| `result` | `success` ou `failed` (alguma etapa falhou; as seguintes ficam `skipped`) |
| `steps[].status` | `done`, `ok`, `skipped`, `failed`, `would change` (dry-run), `not selected` |
| `steps[].kind` | `base`, `module` ou `custom` |
| `ports.*[].exposure` | mesma classificação da auditoria de portas (veja [etapas](steps.md#summary)) |
| `ports.closed` | sockets que escutavam no início e não escutam mais no fim |
| `ports.exposed_after` | sockets acessíveis da internet sem regra de firewall no fim (`null` no dry-run) |
| `lynis` | índice de hardening antes/depois desta execução; `null` se a auditoria não rodou |

Campos novos podem ser acrescentados em versões futuras sem mudar `schema`; uma mudança
incompatível troca para `gaia-report/2`.
