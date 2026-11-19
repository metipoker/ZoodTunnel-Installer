# ZoodTunnel Installer

Public installer and prebuilt AMD64/ARM64 binaries for ZoodTunnel.

The Rust source remains in the private development repository during pre-release testing.

```bash
installer=$(mktemp) && curl -fsSL https://github.com/metipoker/ZoodTunnel-Installer/releases/download/reverse-preview-v1/install.sh -o "$installer" && sudo bash "$installer"
```

## Connection methods

**Create tunnel** shows the hostname, the local IPv4, and the interface and
gateway selected by the server's IPv4 routing table. Choose **TUN** for
IPv4 routing or **Service forwarding** for TCP and UDP ports. Use the same
tunnel name, carrier port, connection method, and direction on both servers:

| Method | Carrier port on the target server |
| --- | --- |
| Automatic | UDP and TCP. Tries QUIC first and switches to TCP/TLS when QUIC fails. |
| Custom → QUIC | UDP |
| Custom → TLS over TCP | TCP |

Automatic mode requires an updated core on both servers and supports TCP and UDP
service forwarding. New flows can use the fallback after it connects. Existing
flows may need to reconnect. Reverse service forwarding uses Custom QUIC and
listens for the carrier on the Iran server. Enter the other server's public
IPv4 address on each end. The service ports still listen on the Iran server.

The performance profile sets the connection limit, queue size, and idle
timeout. QUIC exposes its initial UDP payload MTU. TUN exposes its interface
MTU and defaults to `10.77.0.1/30` outside Iran and `10.77.0.2/30` in Iran.
Service forwarding accepts individual ports, mappings like `443=8443`, and
equal-length ranges like `1000-1010=2000-2010`.
