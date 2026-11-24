# Testing

[Português](../pt-BR/testing.md) | **English**

Gaia has three test layers. The first two run in CI on every PR.

## 1. Unit tests (bats)

```bash
scripts/test.sh bats                          # all of them, in a container (pinned bats 1.11)
scripts/test.sh bats /code/tests/15-ssh.bats  # a single file
```

Each test runs the **whole** of Gaia (`bootstrap.sh`) against a fake root (`GAIA_ROOT`) with a
simulated system:

- `tests/test_helper.bash` creates the root (a freshly installed Ubuntu 24.04, default
  `sshd_config`, `ufw` off...) and puts simulators on the `PATH` for the commands that change or
  query the system (`apt-get`, `systemctl`, `useradd`, `ufw`, `sshd`, `curl`, `lynis`, `docker`...);
- `tests/fakes/fake-system.bash` implements the simulators; the state (users, packages, units, ufw
  rules) lives in files, and every call is recorded in `calls.log`;
- useful assertions: `assert_called`, `refute_called`, `assert_no_mutation` (no call that changes
  anything), `assert_status step status`, `force_failure command code`.

No test touches the machine it runs on.

## 2. shellcheck

```bash
scripts/test.sh shellcheck
```

## 3. Integration (containers)

```bash
scripts/test.sh integration                 # Ubuntu 22.04/24.04/26.04, Debian 12/13
scripts/test.sh integration debian:13
```

`tests/integration/run.sh` runs Gaia **for real** inside a throwaway container (apt, users, sudoers,
`sshd -t`/`-T`, `ufw` with `NET_ADMIN`, fail2ban). Since containers have no systemd, `systemctl`,
`timedatectl` and `hostnamectl` are replaced by minimal stand-ins. The script checks that:

1. `--dry-run` changes nothing;
2. the first run finishes without failures;
3. the second run changes nothing;
4. the result is right: account in `sudo`, key installed, root and passwords off in the effective SSH
   configuration, `AllowUsers`, `ufw` active with `LIMIT` on SSH, valid fail2ban, time zone,
   configuration files.

## Testing on a VM (recommended before production)

Kernel, AppArmor, swap, systemd and the SSH reload are only exercised for real on a full machine. Use
a throwaway VM (Multipass, VirtualBox, a test VPS):

```bash
# Ubuntu with Multipass
multipass launch 24.04 --name gaia-test
multipass transfer -r . gaia-test:/home/ubuntu/gaia   # or git clone inside the VM
multipass shell gaia-test

cd ~/gaia
sudo ./bootstrap.sh --dry-run --admin-user ubuntu --github-keys your-account
sudo ./bootstrap.sh --yes --admin-user ubuntu --github-keys your-account --modules docker
sudo ./bootstrap.sh --yes --admin-user ubuntu --github-keys your-account --modules docker   # should show everything "ok"
```

Before closing the session, open another one and confirm you can log in with the key. If anything
goes wrong, the VM console is still available.
