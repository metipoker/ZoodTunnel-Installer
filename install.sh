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

prepare_server(){
  [[ $(uname -s) == Linux ]] || die 'ZoodTunnel requires Linux'
  local target family="" os manager certs pkg i
  local -a commands packages missing=()
  target=$(arch)
  [[ -r /etc/os-release ]] || die 'Missing /etc/os-release'
  . /etc/os-release
  for os in ${ID:-} ${ID_LIKE:-}; do
    case "$os" in
      debian|ubuntu) family=deb; break ;;
      rhel|fedora|centos|rocky|almalinux|amzn) family=rpm; break ;;
    esac
  done
  [[ -n $family ]] || die "Unsupported distribution: ${PRETTY_NAME:-unknown}"
  [[ -d /run/systemd/system ]] || die 'Boot the server with systemd before installing'
  printf 'Preparing %s (%s)\n' "${PRETTY_NAME:-$ID}" "$target"
  commands=(curl tar gzip openssl python3 ip groupadd useradd sha256sum awk systemctl journalctl xargs cmp)
  if [[ $family == deb ]]; then
    packages=(curl tar gzip openssl python3 iproute2 passwd passwd coreutils mawk systemd systemd findutils diffutils)
    certs=/etc/ssl/certs/ca-certificates.crt
    manager=apt-get
  else
    packages=(curl tar gzip openssl python3 iproute shadow-utils shadow-utils coreutils gawk systemd systemd findutils diffutils)
    certs=/etc/pki/tls/certs/ca-bundle.crt
    if command -v dnf >/dev/null; then manager=dnf; else manager=yum; fi
  fi
  for i in "${!commands[@]}"; do
    if ! command -v "${commands[i]}" >/dev/null; then
      pkg=${packages[i]}
      [[ " ${missing[*]} " == *" $pkg "* ]] || missing+=("$pkg")
    fi
  done
  [[ -s $certs ]] || missing+=(ca-certificates)
  if (( ${#missing[@]} )); then
    need "$manager"
    if [[ $manager == apt-get ]]; then
      apt-get update
      DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends "${missing[@]}"
    else
      "$manager" install -y "${missing[@]}"
    fi
  fi
  for i in "${commands[@]}"; do need "$i"; done
  [[ -s $certs ]] || die 'System CA bundle unavailable'
}

bootstrap_menu(){
  prepare_server
  if ! zoodtunneld --help >/dev/null 2>&1 || ! zoodtunnelctl --help >/dev/null 2>&1 ||
     ! systemctl cat zoodtunnel@.service >/dev/null 2>&1; then
    install_github
  fi
  zoodtunneld --help >/dev/null && zoodtunnelctl --help >/dev/null || die 'Core verification failed'
  systemctl cat zoodtunnel@.service >/dev/null || die 'Missing systemd service template'
  menu
}

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
  for binary in zoodtunneld zoodtunnelctl; do
    "$release_dir/$binary" --help >/dev/null || die "Core cannot run on this server. Install the static musl package for $(uname -m)."
  done
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
  local unit="$source_dir/zoodtunnel@.service"
  [[ -f $unit ]] || unit="$SCRIPT_DIR/zoodtunnel@.service"
  install -m 0644 "$unit" "$release_dir/"
  activate "$release_dir"; echo "Local build installed."
}

install_github()(
  need curl; need tar; need sha256sum
  local target archive sums release_dir version
  target="$(arch)"; version="${ZOODTUNNEL_VERSION:-nightly}"
  local tmp
  tmp=$(mktemp -d); trap 'rm -rf -- "$tmp"' EXIT
  archive="$tmp/release.tar.gz"; sums="$tmp/SHA256SUMS"
  local base="https://github.com/$REPO/releases"; [[ $version == latest ]] && base+="/latest/download" || base+="/download/$version"
  curl -fsSL --retry 3 "$base/SHA256SUMS" -o "$sums"
  local portable="${target%-gnu}-musl" digest
  if awk -v f="zoodtunnel-$portable.tar.gz" '$2==f {found=1} END {exit !found}' "$sums"; then target="$portable"; fi
  digest="$(awk -v f="zoodtunnel-$target.tar.gz" '$2==f {print $1}' "$sums")"
  [[ $digest =~ ^[[:xdigit:]]{64}$ ]] || die "Release checksum unavailable for $target"
  curl -fsSL --retry 3 "$base/zoodtunnel-$target.tar.gz" -o "$archive"
  printf '%s  %s\n' "$digest" "$archive" | sha256sum -c -
  layout; release_dir=$(mktemp -d "$INSTALL_ROOT/releases/$target.XXXXXXXX"); chmod 0755 "$release_dir"
  tar -xzf "$archive" -C "$release_dir"; [[ -f $release_dir/zoodtunnel@.service ]] || die "Release missing service template"
  activate "$release_dir"
  systemctl list-units --state=active --plain 'zoodtunnel@*.service' --no-legend 2>/dev/null |
    awk '$1 ~ /^zoodtunnel@.+\.service$/ {print $1}' | xargs -r systemctl restart
  echo "GitHub release installed from $REPO."
)

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
  systemctl list-units --state=active --plain 'zoodtunnel@*.service' --no-legend 2>/dev/null |
    awk '$1 ~ /^zoodtunnel@.+\.service$/ {print $1}' | xargs -r systemctl restart
  echo "Rolled back to $old"
}

# A random pairing key bootstraps the same trust anchor on both hosts.
# Each endpoint generates its own leaf private key. TLS still authenticates both peers.
pair_identity(){
  local dir=$1 role=$2 secret=$3 usage=serverAuth
  [[ $role == hub ]] || usage=clientAuth
  printf '%s' "$secret" | python3 -c '
import hashlib, hmac, sys
key = bytes.fromhex(sys.stdin.read())
seed = hmac.digest(key, b"ZoodTunnel pairing CA v1", hashlib.sha256)
sys.stdout.buffer.write(bytes.fromhex("302e020100300506032b657004220420") + seed)
' >"$dir/issuer.der"
  openssl pkey -inform DER -in "$dir/issuer.der" -out "$dir/issuer.key"
  openssl req -new -x509 -key "$dir/issuer.key" -subj /CN=ZoodTunnel-Pair-v1 -days 3650 -set_serial 1 \
    -addext 'basicConstraints=critical,CA:TRUE,pathlen:0' -addext 'keyUsage=critical,keyCertSign' -out "$dir/ca.crt"
  openssl genpkey -algorithm EC -pkeyopt ec_paramgen_curve:P-256 -out "$dir/leaf.key"
  openssl req -new -key "$dir/leaf.key" -subj "/CN=$role.local" -out "$dir/leaf.csr"
  printf 'basicConstraints=critical,CA:FALSE\nkeyUsage=critical,digitalSignature\nextendedKeyUsage=%s\nsubjectAltName=DNS:%s.local\n' "$usage" "$role" >"$dir/extensions"
  openssl x509 -req -in "$dir/leaf.csr" -CA "$dir/ca.crt" -CAkey "$dir/issuer.key" -days 825 -extfile "$dir/extensions" -out "$dir/leaf.crt"
  rm "$dir/issuer.der" "$dir/issuer.key" "$dir/leaf.csr" "$dir/extensions"
}

quick_setup()(
  set +x
  umask 077
  local role=$1 profile=paired secret peer="" port ports item public target proto listen tmp cfg identity
  need openssl; need python3
  if ! zoodtunneld --help >/dev/null 2>&1 || ! zoodtunnelctl --help >/dev/null 2>&1; then install_github; fi
  port="$(ask 'Carrier UDP port (same on both servers)' 4433)"
  [[ $port =~ ^[1-9][0-9]{0,4}$ && $port -le 65535 ]] || die 'Invalid carrier port'
  listen="0.0.0.0:$port"
  if [[ $role == edge ]]; then
    peer="$(ask 'Target server IPv4 address')"
    python3 -c 'import ipaddress,sys; ipaddress.IPv4Address(sys.argv[1])' "$peer" || die 'Invalid address'
    listen=127.0.0.1:0
  fi
  ports="$(ask 'Ports on both servers (8080,8880 or public=target)' 8080)"
  [[ $ports =~ ^[0-9=]+(,[0-9=]+)*$ ]] || die 'Invalid ports'
  local prompt='Pairing key from target server'
  [[ $role != hub ]] || prompt='Pairing key (Enter to generate)'
  read -rs -p "$prompt: " secret
  echo
  if [[ $role == hub && -z $secret ]]; then
    secret="$(openssl rand -hex 32)"
    printf 'Pairing key for the listener server: %s\n' "$secret" >/dev/tty
  fi
  [[ $secret =~ ^[[:xdigit:]]{64}$ ]] || die 'Expected a 32-byte hex pairing key'
  layout
  cfg="$PROFILE_DIR/$profile.toml"
  identity="$PKI_DIR/$profile-pair"
  if [[ -e $identity ]]; then identity="$PKI_DIR/$profile-pair-$(openssl rand -hex 8)"; fi
  [[ ! -e $cfg ]] || die 'Paired profile already exists'
  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' EXIT
  pair_identity "$tmp" "$role" "$secret"
  unset secret
  {
    printf 'profile = "%s"\nmode = "%s"\ntransport = "quic"\nlisten = "%s"\n' "$profile" "$role" "$listen"
    if [[ $role == edge ]]; then printf 'peer = "%s:%s"\n' "$peer" "$port"; fi
    printf '[tls]\ncert_file = "%s/leaf.crt"\nkey_file = "%s/leaf.key"\nca_file = "%s/ca.crt"\n' "$identity" "$identity" "$identity"
    if [[ $role == edge ]]; then echo 'server_name = "hub.local"'; fi
    IFS=, read -ra mappings <<<"$ports"
    for item in "${mappings[@]}"; do
      public=${item%%=*}; target=${item##*=}
      [[ $item == "$public" || $item == "$public=$target" ]] || die 'Invalid mapping'
      for number in "$public" "$target"; do
        [[ $number =~ ^[1-9][0-9]{0,4}$ && $number -le 65535 ]] || die 'Invalid port'
      done
      for proto in tcp udp; do
        local bind=127.0.0.1:0
        [[ $role == hub ]] || bind="0.0.0.0:$public"
        printf '[[forwards]]\nname = "p%s-%s"\nprotocol = "%s"\nbind = "%s"\ntarget = "127.0.0.1:%s"\n' "$public" "$proto" "$proto" "$bind" "$target"
      done
    done
  } >"$tmp/profile.toml"
  mkdir -m 0750 "$identity" || die 'Pairing directory already exists'
  trap 'rm -rf "$tmp" "$identity"' EXIT
  chgrp zoodtunnel "$identity"
  install -m 0640 -g zoodtunnel "$tmp"/{ca.crt,leaf.crt,leaf.key} "$identity/"
  zoodtunneld --config "$tmp/profile.toml" --check
  install -m 0640 -g zoodtunnel "$tmp/profile.toml" "$cfg"
  trap 'rm -rf "$tmp"' EXIT
  systemctl enable --now "zoodtunnel@$profile"
)

edit_profile()(
  local cfg=$1 unit=$2 tmp backup
  tmp=$(mktemp "$PROFILE_DIR/.edit.XXXXXXXX") || return 1
  backup=$(mktemp "$PROFILE_DIR/.previous.XXXXXXXX") || { rm -f "$tmp"; return 1; }
  trap 'rm -f "$tmp" "$backup"' EXIT
  cp -p -- "$cfg" "$tmp" && cp -p -- "$cfg" "$backup" || return 1
  "${EDITOR:-vi}" "$tmp" || return 1
  cmp -s "$cfg" "$tmp" && return 0
  zoodtunneld --config "$tmp" --check || return 1
  chmod --reference="$cfg" "$tmp" && chown --reference="$cfg" "$tmp" || return 1
  mv -fT -- "$tmp" "$cfg" || return 1
  if systemctl is-active --quiet "$unit" && ! systemctl restart "$unit"; then
    mv -fT -- "$backup" "$cfg" && systemctl start "$unit"
    return 1
  fi
)

profile_actions(){
  local cfg=$1 name unit choice confirm
  name=${cfg##*/}; name=${name%.toml}; unit="zoodtunnel@$name.service"
  while [[ -f $cfg ]]; do
    printf '\nManage %s\n' "$name"
    printf '1  Status\n2  Start\n3  Stop\n4  Restart\n5  Live logs (Ctrl+C to return)\n6  Edit config\n7  Remove tunnel\n8  Enable at boot\n9  Disable at boot\n0  Back\n'
    read -rp 'Action: ' choice || return 0
    case "$choice" in
      1) systemctl --no-pager --full status "$unit" || : ;;
      2) systemctl start "$unit" || echo 'Start failed. Check logs.' ;;
      3) systemctl stop "$unit" || echo 'Stop failed.' ;;
      4) systemctl restart "$unit" || echo 'Restart failed. Check logs.' ;;
      5) (trap 'exit 0' INT; journalctl --no-pager -fu "$unit" -n 30) || : ;;
      6) edit_profile "$cfg" "$unit" || echo 'Edit or restart failed; check the output above.' ;;
      7) printf 'Stop and disable %s, then delete its profile on this server.\n' "$name"
         read -rp "Type $name to remove (Enter to cancel): " confirm || return 0
         [[ $confirm == "$name" ]] || continue
         systemctl stop "$unit" && systemctl disable "$unit" && rm -- "$cfg" && return 0
         echo 'Removal incomplete. Check the output above.' ;;
      8) systemctl enable "$unit" || echo 'Enable failed.' ;;
      9) systemctl disable "$unit" || echo 'Disable failed.' ;;
      0) return 0 ;;
      *) echo 'Choose 0 to 9.' ;;
    esac
  done
}

manage_profiles(){
  local cfg name choice state
  local -a profiles
  while true; do
    profiles=()
    printf '\nTunnels on this server\n'
    for cfg in "$PROFILE_DIR"/*.toml; do
      [[ -f $cfg && ! -L $cfg ]] || continue
      name=${cfg##*/}; name=${name%.toml}
      [[ $name =~ ^[A-Za-z0-9_-]{1,64}$ ]] || continue
      profiles+=("$cfg")
      state=$(systemctl is-active "zoodtunnel@$name.service") || state=${state:-unknown}
      printf '%d  %s  [%s]\n' "${#profiles[@]}" "$name" "$state"
    done
    if (( ${#profiles[@]} == 0 )); then echo 'No tunnels configured.'; return 0; fi
    echo '0  Back'
    read -rp 'Tunnel: ' choice || return 0
    [[ $choice != 0 ]] || return 0
    if [[ $choice =~ ^[1-9][0-9]{0,5}$ ]] && (( choice <= ${#profiles[@]} )); then
      profile_actions "${profiles[choice-1]}"
    else
      echo 'Choose a listed tunnel.'
    fi
  done
}

menu(){
  local choice role core count active title reset
  title=""; reset=""
  if [[ -t 1 && -z ${NO_COLOR:-} ]]; then title=$'\033[1;36m'; reset=$'\033[0m'; fi
  while true; do
    core="Not installed"
    if command -v zoodtunneld >/dev/null; then
      if zoodtunneld --help >/dev/null 2>&1; then core="Ready"; else core="Needs repair"; fi
    fi
    count=0
    for cfg in "$PROFILE_DIR"/*.toml; do if [[ -f $cfg ]]; then ((count+=1)); fi; done
    active="$(systemctl list-units --state=active --type=service --no-legend 'zoodtunnel@*.service' 2>/dev/null | awk 'END {print NR}')" || active="?"
    printf '\n%sZoodTunnel  /  Tunnel manager%s\n' "$title" "$reset"
    printf 'Core: %s   Profiles: %s   Active: %s\n\n' "$core" "$count" "$active"
    printf '  1  Create tunnel\n  2  Manage tunnels\n  3  Advanced options\n  0  Exit\n'
    read -rp 'Select [0-3]: ' choice || return 0
    case "$choice" in
      1) printf '\nWhich server is this?\n  1  Outside Iran (runs Xray or target service)\n  2  Iran (accepts user connections)\n  0  Back\n'
         read -rp 'Select [0-2]: ' role || return 0
         case "$role" in 1) quick_setup hub ;; 2) quick_setup edge ;; 0) continue ;; *) echo 'Choose 0, 1 or 2.' ;; esac ;;
      2) manage_profiles ;;
      3) advanced_menu ;;
      0) return 0 ;;
      *) echo 'Choose a number from 0 to 3.' ;;
    esac
  done
}

advanced_menu(){
  echo "ZoodTunnel installer / manager"; echo "1) Install or update from GitHub"; echo "2) Create Target/Hub profile (service side)"; echo "3) Create Listener/Edge profile (public-port side)"; echo "4) Show status"; echo "5) Roll back binary"; echo "0) Exit"
  read -r -p "Select: " choice
  case "$choice" in 1) install_github;; 2) create_hub;; 3) create_edge;; 4) systemctl --no-pager --full status 'zoodtunnel@*' || true;; 5) rollback;; 0) exit 0;; *) die "Invalid selection";; esac
}

[[ ${EUID:-$(id -u)} -eq 0 ]] || die "Run as root"
case ${1:-menu} in --local) [[ -n ${2:-} ]] || die "Usage: $0 --local DIR"; install_local "$2";; --github) install_github;; --hub) create_hub;; --edge) create_edge;; --rollback) rollback;; menu) bootstrap_menu;; *) die "Usage: $0 [menu|--github|--local DIR|--hub|--edge|--rollback]";; esac
