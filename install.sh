#!/usr/bin/env bash
set -Eeuo pipefail

REPO="${ZOODTUNNEL_REPO:-metipoker/ZoodTunnel-Installer}"
INSTALL_ROOT=/opt/zoodtunnel
CURRENT="$INSTALL_ROOT/current"
PREVIOUS="$INSTALL_ROOT/previous"
PROFILE_DIR=/etc/zoodtunnel/profiles
PKI_DIR=/etc/zoodtunnel/pki
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

die(){ echo "ERROR: $*" >&2; exit 1; }
need(){ command -v "$1" >/dev/null 2>&1 || die "Missing command: $1"; }
ask(){ local prompt=$1 default=${2:-}; read -r -p "$prompt [$default]: " REPLY; printf '%s' "${REPLY:-$default}"; }
arch(){ case "$(uname -m)" in x86_64|amd64) echo x86_64-unknown-linux-gnu;; aarch64|arm64) echo aarch64-unknown-linux-gnu;; *) die "Unsupported architecture: $(uname -m)";; esac; }

layout(){
  getent group zoodtunnel >/dev/null || groupadd --system zoodtunnel
  id zoodtunnel >/dev/null 2>&1 || useradd --system --gid zoodtunnel --home-dir /var/lib/zoodtunnel --shell /usr/sbin/nologin zoodtunnel
  install -d -m 0750 -o root -g zoodtunnel "$PROFILE_DIR" "$PKI_DIR"
  install -d -m 0750 -o zoodtunnel -g zoodtunnel /var/lib/zoodtunnel /run/zoodtunnel
  install -d -m 0755 "$INSTALL_ROOT/releases"
}

activate(){
  local release_dir=$1 old=""
  [[ -x "$release_dir/zoodtunneld" && -x "$release_dir/zoodtunnelctl" ]] || die "Release binaries are missing"
  [[ ! -L $CURRENT ]] || old="$(readlink -f "$CURRENT")"
  [[ -z $old ]] || ln -sfn "$old" "$PREVIOUS"
  ln -sfn "$release_dir" "$CURRENT"
  ln -sfn "$CURRENT/zoodtunneld" /usr/local/bin/zoodtunneld
  ln -sfn "$CURRENT/zoodtunnelctl" /usr/local/bin/zoodtunnelctl
  [[ ! -f "$release_dir/zoodtunnel@.service" ]] || install -m 0644 "$release_dir/zoodtunnel@.service" /etc/systemd/system/zoodtunnel@.service
  systemctl daemon-reload
}

install_local(){
  local source_dir=${1:?local binary directory required} release_dir
  layout; release_dir="$INSTALL_ROOT/releases/local-$(date +%Y%m%d%H%M%S)"; install -d -m 0755 "$release_dir"
  install -m 0755 "$source_dir/zoodtunneld" "$source_dir/zoodtunnelctl" "$release_dir/"
  install -m 0644 "$SCRIPT_DIR/zoodtunnel@.service" "$release_dir/"
  activate "$release_dir"; echo "Local build installed."
}

install_github(){
  need curl; need tar; need sha256sum
  local target archive sums release_dir version
  target="$(arch)"; version="${ZOODTUNNEL_VERSION:-nightly}"
  archive="$(mktemp)"; sums="$(mktemp)"
  local base="https://github.com/$REPO/releases"; [[ $version == latest ]] && base+="/latest/download" || base+="/download/$version"
  curl -fL --retry 3 "$base/zoodtunnel-$target.tar.gz" -o "$archive"
  curl -fL --retry 3 "$base/SHA256SUMS" -o "$sums"
  grep "zoodtunnel-$target.tar.gz" "$sums" | sed "s#zoodtunnel-$target.tar.gz#$(basename "$archive")#" | (cd "$(dirname "$archive")" && sha256sum -c -)
  layout; release_dir="$INSTALL_ROOT/releases/$(date +%Y%m%d%H%M%S)-$target"; install -d -m 0755 "$release_dir"
  tar -xzf "$archive" -C "$release_dir"; rm -f "$archive" "$sums"; activate "$release_dir"
  systemctl list-unit-files 'zoodtunnel@*.service' --no-legend 2>/dev/null |
    awk '$1 ~ /^zoodtunnel@.+\.service$/ {print $1}' | xargs -r systemctl restart
  echo "GitHub release installed from $REPO."
}

make_pki(){
  need openssl
  local server_name=$1 profile=$2 bundle="/root/zoodtunnel-$profile-edge-pki.tar.gz" tmp
  tmp="$(mktemp -d)"; umask 077
  openssl req -x509 -newkey rsa:3072 -nodes -days 3650 -sha256 -keyout "$PKI_DIR/ca.key" -out "$PKI_DIR/ca.crt" -subj "/CN=ZoodTunnel $profile CA" >/dev/null 2>&1
  openssl req -new -newkey rsa:2048 -nodes -keyout "$PKI_DIR/hub.key" -out "$tmp/hub.csr" -subj "/CN=$server_name" >/dev/null 2>&1
  printf 'basicConstraints=critical,CA:FALSE\nkeyUsage=critical,digitalSignature,keyEncipherment\nextendedKeyUsage=serverAuth\nsubjectAltName=DNS:%s\n' "$server_name" >"$tmp/hub.ext"
  openssl x509 -req -in "$tmp/hub.csr" -CA "$PKI_DIR/ca.crt" -CAkey "$PKI_DIR/ca.key" -CAcreateserial -out "$PKI_DIR/hub.crt" -days 825 -sha256 -extfile "$tmp/hub.ext" >/dev/null 2>&1
  openssl req -new -newkey rsa:2048 -nodes -keyout "$tmp/edge.key" -out "$tmp/edge.csr" -subj "/CN=$profile-edge" >/dev/null 2>&1
  printf 'basicConstraints=critical,CA:FALSE\nkeyUsage=critical,digitalSignature,keyEncipherment\nextendedKeyUsage=clientAuth\n' >"$tmp/edge.ext"
  openssl x509 -req -in "$tmp/edge.csr" -CA "$PKI_DIR/ca.crt" -CAkey "$PKI_DIR/ca.key" -CAcreateserial -out "$tmp/edge.crt" -days 825 -sha256 -extfile "$tmp/edge.ext" >/dev/null 2>&1
  cp "$PKI_DIR/ca.crt" "$tmp/ca.crt"
  [[ ! -f "$PKI_DIR/$profile.forwards" ]] || cp "$PKI_DIR/$profile.forwards" "$tmp/forwards.map"
  tar -czf "$bundle" -C "$tmp" edge.crt edge.key ca.crt $([[ -f "$tmp/forwards.map" ]] && printf '%s' forwards.map)
  rm -rf "$tmp"
  chmod 0640 "$PKI_DIR/ca.crt" "$PKI_DIR/hub.crt"; chmod 0600 "$PKI_DIR/ca.key" "$PKI_DIR/hub.key"; chgrp zoodtunnel "$PKI_DIR/ca.crt" "$PKI_DIR/hub.crt" "$PKI_DIR/hub.key"
  echo "Edge PKI bundle: $bundle"
}

collect_forwards(){
  local profile=$1 map="$PKI_DIR/$profile.forwards" add name protocol public_port target_ip target_port
  : >"$map"; chmod 0640 "$map"; chgrp zoodtunnel "$map"
  while true; do
    add="$(ask 'Add a port forward? (yes/no)' no)"; [[ $add == yes || $add == y ]] || break
    name="$(ask 'Mapping name' service)"; protocol="$(ask 'Protocol (tcp/udp/both)' both)"
    public_port="$(ask 'Public/listener port' 443)"; target_ip="$(ask 'Target IP on this Hub' 127.0.0.1)"; target_port="$(ask 'Target service port' "$public_port")"
    [[ $name =~ ^[A-Za-z0-9_-]+$ ]] || die "Invalid mapping name"
    [[ $protocol == tcp || $protocol == udp || $protocol == both ]] || die "Invalid protocol"
    [[ $public_port =~ ^[0-9]+$ && $public_port -ge 1 && $public_port -le 65535 ]] || die "Invalid public port"
    [[ $target_port =~ ^[0-9]+$ && $target_port -ge 1 && $target_port -le 65535 ]] || die "Invalid target port"
    if [[ $protocol == tcp || $protocol == both ]]; then printf '%s|tcp|%s|%s|%s\n' "${name}-tcp" "$public_port" "$target_ip" "$target_port" >>"$map"; fi
    if [[ $protocol == udp || $protocol == both ]]; then printf '%s|udp|%s|%s|%s\n' "${name}-udp" "$public_port" "$target_ip" "$target_port" >>"$map"; fi
  done
}

append_hub_forwards(){
  local profile=$1 config=$2 name protocol public_port target_ip target_port
  [[ -s "$PKI_DIR/$profile.forwards" ]] || return 0
  while IFS='|' read -r name protocol public_port target_ip target_port; do
    tee -a "$config" >/dev/null <<EOF

[[forwards]]
name = "$name"
protocol = "$protocol"
bind = "127.0.0.1:0"
target = "$target_ip:$target_port"
EOF
  done <"$PKI_DIR/$profile.forwards"
}

append_edge_forwards(){
  local config=$1 map=$2 name protocol public_port target_ip target_port
  [[ -s $map ]] || return 0
  while IFS='|' read -r name protocol public_port target_ip target_port; do
    tee -a "$config" >/dev/null <<EOF

[[forwards]]
name = "$name"
protocol = "$protocol"
bind = "0.0.0.0:$public_port"
target = "$target_ip:$target_port"
EOF
  done <"$map"
}

create_hub(){
  layout
  local profile port transport server_name address
  profile="$(ask 'Profile name' game)"; port="$(ask 'Carrier port' 4433)"; transport="$(ask 'Transport (quic/tcp_tls)' quic)"; server_name="$(ask 'Hub TLS name' hub.local)"; address="$(ask 'Hub TUN address' 10.77.0.1/30)"
  [[ $profile =~ ^[A-Za-z0-9_-]+$ ]] || die "Invalid profile"; [[ $transport == quic || $transport == tcp_tls ]] || die "Invalid transport"
  collect_forwards "$profile"; make_pki "$server_name" "$profile"; install -m 0640 -o root -g zoodtunnel /dev/null "$PROFILE_DIR/$profile.toml"
  tee "$PROFILE_DIR/$profile.toml" >/dev/null <<EOF
profile = "$profile"
mode = "hub"
transport = "$transport"
listen = "0.0.0.0:$port"
health_listen = "127.0.0.1:9188"
[tls]
cert_file = "$PKI_DIR/hub.crt"
key_file = "$PKI_DIR/hub.key"
ca_file = "$PKI_DIR/ca.crt"
[limits]
max_connections = 20000
accept_queue = 4096
idle_timeout_secs = 90
rate_limit_bytes_per_sec = 0
[tun]
name = "ztun0"
address = "$address"
mtu = 1280
EOF
  append_hub_forwards "$profile" "$PROFILE_DIR/$profile.toml"
  zoodtunneld --config "$PROFILE_DIR/$profile.toml" --check; systemctl enable --now "zoodtunnel@$profile"
  echo "Target/Hub $profile active. Copy /root/zoodtunnel-$profile-edge-pki.tar.gz securely to the Listener/Edge server."
}

create_edge(){
  layout
  local profile peers transport server_name address bundle peer_array
  profile="$(ask 'Profile name' game)"; peers="$(ask 'Hub endpoints, comma separated' '203.0.113.10:4433')"; transport="$(ask 'Transport (quic/tcp_tls)' quic)"; server_name="$(ask 'Hub TLS name' hub.local)"; address="$(ask 'Edge TUN address' 10.77.0.2/30)"; bundle="$(ask 'Path to edge PKI bundle' "/root/zoodtunnel-$profile-edge-pki.tar.gz")"
  [[ -f $bundle ]] || die "PKI bundle not found"; tar -xzf "$bundle" -C "$PKI_DIR"; chmod 0640 "$PKI_DIR/ca.crt" "$PKI_DIR/edge.crt"; chmod 0600 "$PKI_DIR/edge.key"; chgrp zoodtunnel "$PKI_DIR"/*
  peer_array="$(printf '%s' "$peers" | awk -F, '{for(i=1;i<=NF;i++) printf "%s\"%s\"",(i==1?"":", "),$i}')"
  install -m 0640 -o root -g zoodtunnel /dev/null "$PROFILE_DIR/$profile.toml"
  tee "$PROFILE_DIR/$profile.toml" >/dev/null <<EOF
profile = "$profile"
mode = "edge"
transport = "$transport"
listen = "127.0.0.1:0"
peers = [$peer_array]
health_listen = "127.0.0.1:9188"
[tls]
cert_file = "$PKI_DIR/edge.crt"
key_file = "$PKI_DIR/edge.key"
ca_file = "$PKI_DIR/ca.crt"
server_name = "$server_name"
[limits]
max_connections = 20000
accept_queue = 4096
idle_timeout_secs = 90
rate_limit_bytes_per_sec = 0
[reconnect]
initial_secs = 1
max_secs = 30
[tun]
name = "ztun0"
address = "$address"
mtu = 1280
protect_peer_route = true
EOF
  append_edge_forwards "$PROFILE_DIR/$profile.toml" "$PKI_DIR/forwards.map"
  zoodtunneld --config "$PROFILE_DIR/$profile.toml" --check; systemctl enable --now "zoodtunnel@$profile"; echo "Edge $profile active."
}

rollback(){
  [[ -L $PREVIOUS ]] || die "No previous release"
  local old current; old="$(readlink -f "$PREVIOUS")"; current="$(readlink -f "$CURRENT")"; ln -sfn "$current" "$PREVIOUS"; ln -sfn "$old" "$CURRENT"
  ln -sfn "$CURRENT/zoodtunneld" /usr/local/bin/zoodtunneld; ln -sfn "$CURRENT/zoodtunnelctl" /usr/local/bin/zoodtunnelctl
  systemctl list-unit-files 'zoodtunnel@*.service' --no-legend 2>/dev/null |
    awk '$1 ~ /^zoodtunnel@.+\.service$/ {print $1}' | xargs -r systemctl restart
  echo "Rolled back to $old"
}

menu(){
  echo "ZoodTunnel installer / manager"; echo "1) Install or update from GitHub"; echo "2) Create Target/Hub profile (service side)"; echo "3) Create Listener/Edge profile (public-port side)"; echo "4) Show status"; echo "5) Roll back binary"; echo "0) Exit"
  read -r -p "Select: " choice
  case "$choice" in 1) install_github;; 2) create_hub;; 3) create_edge;; 4) systemctl --no-pager --full status 'zoodtunnel@*' || true;; 5) rollback;; 0) exit 0;; *) die "Invalid selection";; esac
}

[[ ${EUID:-$(id -u)} -eq 0 ]] || die "Run as root"
case ${1:-menu} in --local) [[ -n ${2:-} ]] || die "Usage: $0 --local DIR"; install_local "$2";; --github) install_github;; --hub) create_hub;; --edge) create_edge;; --rollback) rollback;; menu) menu;; *) die "Usage: $0 [menu|--github|--local DIR|--hub|--edge|--rollback]";; esac
