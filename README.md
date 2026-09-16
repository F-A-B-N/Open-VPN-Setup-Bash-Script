# OpenVPN 443 Auto Installer

A hardened, idempotent bash script that installs and configures an OpenVPN server on TCP/443, optimized for AWS EC2 but compatible with any Debian or Ubuntu host.

The script handles package installation, PKI generation, server configuration, NAT/firewall rules, service startup, and client `.ovpn` generation in a single run. It is designed to be safe to re-run and to avoid common pitfalls found in typical "one-liner" OpenVPN installers.

---

## Features

- Automatic public IP detection using AWS IMDSv2, with multiple fallbacks (`api.ipify.org`, `ifconfig.me`, local interface).
- Automatic WAN interface detection, so NAT rules work on EC2 (`ens5`), VirtualBox (`enp0s3`), and traditional hosts (`eth0`).
- Modern cryptography: ECDH P-384, AES-256-GCM, CHACHA20-POLY1305, SHA512, TLS 1.2 minimum.
- Control-channel encryption via `tls-crypt` instead of the older `tls-auth`.
- Privilege dropping (`user nobody`, `group nogroup`) after initialization.
- Certificate revocation support through `crl-verify` and generated CRLs.
- Idempotent: re-running the script will not regenerate the CA or duplicate firewall rules.
- Persistent iptables rules via `netfilter-persistent`.
- Client DNS leak protection with `block-outside-dns`.
- DHCP pool persistence via `ifconfig-pool-persist`.
- Built-in service health check that dumps `journalctl` output on failure.
- Generates a ready-to-use `.ovpn` file with embedded CA, client certificate, client key, and `tls-crypt` key.

---

## Requirements

- Root access (run with `sudo`).
- A Debian or Ubuntu based system. Tested on:
  - Ubuntu 20.04, 22.04, 24.04
  - Debian 11, 12
- `curl`, `bash`, and standard coreutils.
- An inbound firewall or cloud Security Group rule allowing the chosen port and protocol (default: TCP/443).

---

## Installation

Download the script and run it as root:

```bash
sudo bash openvpn-install.sh
```

Or, if you have saved it to a file:

```bash
chmod +x openvpn-install.sh
sudo ./openvpn-install.sh
```

The script will:

1. Detect the public IP and default network interface.
2. Install `openvpn`, `easy-rsa`, `iptables`, `iptables-persistent`, and `curl`.
3. Initialize a PKI at `/root/openvpn-ca` (skipped if it already exists).
4. Generate the CA, server certificate, client certificate, CRL, and `tls-crypt` key.
5. Write `/etc/openvpn/server.conf`.
6. Enable IP forwarding and configure NAT masquerading.
7. Enable and start `openvpn@server`.
8. Produce a client configuration at `/root/client-configs/client.ovpn`.

---

## Configuration

The script accepts several environment variables to override defaults:

| Variable    | Default   | Description                       |
|-------------|-----------|-----------------------------------|
| `VPN_USER`  | `client`  | Name of the first client          |
| `PORT`      | `443`     | Port the server listens on        |
| `PROTO`     | `tcp`     | Protocol (`tcp` or `udp`)         |

Example:

```bash
sudo VPN_USER=alice PORT=443 PROTO=tcp ./openvpn-install.sh
```

---

## Client Configuration

After a successful run, the client profile is written to:

```
/root/client-configs/client.ovpn
```

This file embeds the CA certificate, client certificate, client key, and `tls-crypt` key. Transfer it to the client machine using `scp`:

```bash
scp root@SERVER_IP:/root/client-configs/client.ovpn .
```

Then import it into any OpenVPN-compatible client:

- OpenVPN Connect (Windows, macOS, iOS, Android)
- OpenVPN GUI (Windows)
- Tunnelblick (macOS)
- `openvpn` command-line client (Linux)

---

## Post-Installation Notes

### Cloud Firewall

If you are running this on AWS, GCP, Azure, or any other cloud provider, you must open the configured port and protocol in the provider's firewall or Security Group. The script cannot do this for you.

For AWS EC2:

1. Open the EC2 console.
2. Select the instance.
3. Open the Security tab and edit the inbound rules.
4. Add a rule allowing TCP/443 (or your custom port) from `0.0.0.0/0`.

### Backups

Back up the entire PKI directory:

```
/root/openvpn-ca
```

If you lose the CA certificate or its private key, you will not be able to issue or revoke client certificates, and existing clients will eventually need to be re-provisioned.

---

## Managing Clients

### Add a new client

```bash
cd /root/openvpn-ca
export EASYRSA_BATCH=1
export EASYRSA_ALGO=ec
export EASYRSA_CURVE=secp384r1
export EASYRSA_DIGEST=sha512
./easyrsa gen-req bob nopass
./easyrsa sign-req client bob
```

Then rebuild a `.ovpn` file using the same template the installer uses, substituting the client name.

### Revoke a client

```bash
cd /root/openvpn-ca
export EASYRSA_BATCH=1
./easyrsa revoke bob
./easyrsa gen-crl
cp pki/crl.pem /etc/openvpn/keys/crl.pem
chmod 600 /etc/openvpn/keys/crl.pem
systemctl restart openvpn@server
```

Clients listed in the CRL will be rejected on their next connection attempt.

---

## File Locations

| Path                              | Purpose                              |
|-----------------------------------|--------------------------------------|
| `/etc/openvpn/server.conf`        | OpenVPN server configuration         |
| `/etc/openvpn/keys/`              | Server certificates, keys, CRL       |
| `/root/openvpn-ca/`               | Easy-RSA PKI (CA, issued certs)      |
| `/root/client-configs/`           | Generated `.ovpn` client profiles    |
| `/var/log/openvpn.log`            | Runtime log                          |
| `/var/log/openvpn-status.log`     | Current connection status            |
| `/var/log/ovpn-ipp.txt`           | Persistent client IP assignments     |
| `/etc/iptables/rules.v4`          | Persisted NAT and forwarding rules   |
| `/etc/sysctl.d/99-openvpn.conf`   | IP forwarding setting                |

---

## Verifying the Server

Check service status:

```bash
systemctl status openvpn@server
```

Follow the log:

```bash
tail -f /var/log/openvpn.log
```

Inspect connected clients:

```bash
cat /var/log/openvpn-status.log
```

Confirm NAT rules are present:

```bash
iptables -t nat -L POSTROUTING -n -v
```

Confirm IP forwarding is enabled:

```bash
sysctl net.ipv4.ip_forward
```

Expected output:

```
net.ipv4.ip_forward = 1
```

---

## Troubleshooting

### Service fails to start

Run:

```bash
journalctl -u openvpn@server --no-pager -n 50
```

Common causes:

- Missing files in `/etc/openvpn/keys/`.
- Port already in use (`ss -tlnp | grep 443`).
- Malformed `server.conf`.

### Client connects but has no internet

Verify the following:

1. `net.ipv4.ip_forward` is `1`.
2. The NAT rule references the correct WAN interface.
3. The cloud Security Group permits outbound traffic.
4. On the client, DNS is being pushed correctly (`dhcp-option DNS`).

Check the NAT rule:

```bash
iptables -t nat -L POSTROUTING -n -v
```

If the interface name is wrong, delete the rule and add a corrected one.

### Client cannot connect

- Confirm the port is open in the cloud firewall.
- Confirm the server is listening: `ss -tlnp | grep 443`.
- Try switching to UDP: re-run with `PROTO=udp`.
- Verify the client `.ovpn` matches the server's crypto settings.

### TLS handshake errors

Ensure the client `.ovpn` contains the same `tls-crypt` key as the server. If the server's `ta.key` was regenerated, all client profiles must be updated.

---

## Security Notes

- The default configuration uses ECDH P-384, AES-256-GCM, and SHA512. Older clients that do not support these algorithms will be rejected.
- The server drops privileges to `nobody:nogroup` after initialization.
- `tls-crypt` encrypts the control channel, hiding the TLS handshake from passive observers and making port scanning less effective.
- The CRL is regenerated on demand and read by the server without requiring a full restart in most cases; a restart is still recommended after revocation.
- Client profiles contain private keys. Store them securely and delete them from the server once delivered if they are no longer needed.

---

## Uninstalling

To remove OpenVPN and its configuration:

```bash
systemctl stop openvpn@server
systemctl disable openvpn@server

apt-get remove --purge -y openvpn easy-rsa iptables-persistent

rm -rf /etc/openvpn
rm -rf /root/openvpn-ca
rm -rf /root/client-configs
rm -f /etc/sysctl.d/99-openvpn.conf
rm -f /etc/iptables/rules.v4

sysctl --system
```

The PKI at `/root/openvpn-ca` is intentionally removed only if you delete it manually. If you plan to reinstall later, back it up first.

---

## License

MIT
