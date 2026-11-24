# shellcheck shell=bash
# Copyright 2026 Black Ghost Corporation
# SPDX-License-Identifier: Apache-2.0
# gaia-description: kernel and network hardening via sysctl (anti-spoofing, no redirects, SYN cookies, restricted kernel info)
#
# Only settings that do not break a regular server. IP forwarding is NOT touched: Docker and VPNs
# need it.

GAIA_SYSCTL_FILE=/etc/sysctl.d/90-gaia-hardening.conf

sysctl__content() {
  cat <<'EOF'
# Managed by Gaia (sysctl step). Change gaia.conf (GAIA_SYSCTL_EXTRA) and run Gaia again.

# --- Network: anti-spoofing, no ICMP redirects or source routing ---
net.ipv4.conf.all.rp_filter = 1
net.ipv4.conf.default.rp_filter = 1
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.default.accept_redirects = 0
net.ipv4.conf.all.secure_redirects = 0
net.ipv4.conf.default.secure_redirects = 0
net.ipv6.conf.all.accept_redirects = 0
net.ipv6.conf.default.accept_redirects = 0
net.ipv4.conf.all.send_redirects = 0
net.ipv4.conf.default.send_redirects = 0
net.ipv4.conf.all.accept_source_route = 0
net.ipv4.conf.default.accept_source_route = 0
net.ipv6.conf.all.accept_source_route = 0
net.ipv6.conf.default.accept_source_route = 0
net.ipv4.conf.all.log_martians = 1
net.ipv4.conf.default.log_martians = 1
net.ipv4.icmp_echo_ignore_broadcasts = 1
net.ipv4.icmp_ignore_bogus_error_responses = 1

# --- Network: SYN flood and TIME-WAIT assassination protection ---
net.ipv4.tcp_syncookies = 1
net.ipv4.tcp_rfc1337 = 1

# --- Kernel: hide kernel pointers and logs from unprivileged users ---
kernel.kptr_restrict = 2
kernel.dmesg_restrict = 1
kernel.yama.ptrace_scope = 1
kernel.unprivileged_bpf_disabled = 1
net.core.bpf_jit_harden = 2
kernel.randomize_va_space = 2
kernel.sysrq = 0

# --- Filesystem: protected links and FIFOs, no core dumps of setuid programs ---
fs.protected_hardlinks = 1
fs.protected_symlinks = 1
fs.protected_fifos = 2
fs.protected_regular = 2
fs.suid_dumpable = 0
EOF
  local kv
  if [[ -n $GAIA_SYSCTL_EXTRA ]]; then
    printf '\n# --- GAIA_SYSCTL_EXTRA ---\n'
    for kv in $GAIA_SYSCTL_EXTRA; do printf '%s = %s\n' "${kv%%=*}" "${kv#*=}"; done
  fi
}

step_run() {
  [[ $GAIA_SYSCTL == 1 ]] || gaia_skip "kernel hardening disabled (GAIA_SYSCTL=0)"
  if gaia_in_container; then
    gaia_skip "running inside a container: kernel settings belong to the host"
  fi
  gaia_ensure_file "$GAIA_SYSCTL_FILE" 0644 "$(sysctl__content)"
  if ((!GAIA_CHANGED)); then
    gaia_info "kernel hardening already applied" "file=$GAIA_SYSCTL_FILE"
    return 0
  fi
  # -e: ignore keys this kernel does not have (e.g. yama on some builds) instead of failing.
  gaia_run sysctl -e -q -p "$(gaia_path "$GAIA_SYSCTL_FILE")"
  gaia_info "kernel hardening applied" "file=$GAIA_SYSCTL_FILE"
}
