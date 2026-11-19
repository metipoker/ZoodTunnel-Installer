#!/usr/bin/env bash
set -euo pipefail

source_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
work=$(mktemp -d)
daemon_pid=''
cleanup() {
  if [[ -n $daemon_pid ]]; then kill "$daemon_pid" 2>/dev/null || true; fi
  rm -rf -- "$work"
}
trap cleanup EXIT
# Run only on disposable hosts. The container uses its real distro packages
# and runs the daemon directly because PID 1 is Bash in that test.
case ${1:-} in
  container)
    mkdir -p /run/systemd/system "$work/bin"
    cat >"$work/bin/systemctl" <<'SH'
#!/bin/bash
case "$1" in
  cat) test -f "/etc/systemd/system/$2" ;;
  daemon-reload|list-units|enable) exit 0 ;;
  *) exit 1 ;;
esac
SH
    chmod +x "$work/bin/systemctl"
    export PATH="$work/bin:$PATH"
    ;;
  native) ;;
  *) echo 'Choose container or native' >&2; exit 2 ;;
esac

sed 's/^INSTALLER_RELEASE=nightly$/INSTALLER_RELEASE=reverse-preview-v2/' \
  "$source_dir/install.sh" > "$work/install.sh"
bash "$work/install.sh" <<<0 | tee "$work/install.log"
grep -F 'Core: Ready' "$work/install.log"
test "$(< /opt/zoodtunnel/current/.release-id)" = "metipoker/ZoodTunnel-Installer:$ZOODTUNNEL_VERSION"
first_release=$(readlink -f /opt/zoodtunnel/current)
bash "$work/install.sh" <<<0 >/dev/null
test "$(readlink -f /opt/zoodtunnel/current)" = "$first_release"

key=$(openssl rand -hex 32)
printf '1\n2\npaired\n1\n\n24443\n2\n1\n1\n1\n1320\n18080=8080\n%s\n0\n' "$key" |
  bash "$work/install.sh"
profile=/etc/zoodtunnel/profiles/paired.toml
grep -Fx 'quic_initial_mtu = 1320' "$profile"
grep -Fx 'target = "127.0.0.1:8080"' "$profile"
if [[ $1 == container ]]; then
  zoodtunneld --config "$profile" >"$work/daemon.log" 2>&1 &
  daemon_pid=$!
else
  systemctl is-active zoodtunnel@paired.service
fi
for attempt in {1..20}; do
  if curl -fsS --max-time 2 http://127.0.0.1:9188/readyz; then exit 0; fi
  sleep 0.5
done
if [[ $1 == container ]]; then cat "$work/daemon.log"; fi
exit 1
