# JSON report (`--report-json`)

[Português](../pt-BR/report.md) | **English**

With `--report-json FILE`, Gaia writes a machine-readable report at the end of the run: made for
automation, CI, server inventories and AI agents (see
[Using with AI agents](../../README.en.md#using-with-ai-agents)).

```bash
sudo ./bootstrap.sh --yes --report-json /root/gaia-report.json
sudo jq '{result, lynis, exposed: .ports.exposed_after, reboot_required}' /root/gaia-report.json
```

- It is written by **every run that gets to run steps**: real, `--dry-run` or failed
  (`"result": "failed"`). Usage errors (invalid option, rejected configuration) stop earlier, with
  exit code 2 and no report.
- The directory must exist; the file is created with mode 600 and replaced atomically.
- Warnings and errors come from the log lines, with secrets already masked.

## Format (`"schema": "gaia-report/1"`)

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

| Field | Meaning |
|-------|---------|
| `result` | `success` or `failed` (a step failed; the following ones are `skipped`) |
| `steps[].status` | `done`, `ok`, `skipped`, `failed`, `would change` (dry-run), `not selected` |
| `steps[].kind` | `base`, `module` or `custom` |
| `ports.*[].exposure` | same classification as the port audit (see [steps](steps.md#summary)) |
| `ports.closed` | sockets listening at the start and no longer listening at the end |
| `ports.exposed_after` | sockets reachable from the internet without a firewall rule at the end (`null` in dry-run) |
| `lynis` | hardening index before/after this run; `null` when the audit did not run |

New fields may be added in later versions without changing `schema`; an incompatible change moves to
`gaia-report/2`.
