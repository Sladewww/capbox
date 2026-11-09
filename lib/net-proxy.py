#!/usr/bin/env python3
# CapBox host-side allowlist HTTP proxy + guest-netns TCP↔UNIX bridge.
# Never executed inside untrusted recipe files; CapBox launches it explicitly.
from __future__ import annotations

import argparse
import fcntl
import ipaddress
import os
import select
import socket
import sys
import threading
from typing import Any, Dict, Iterable, List, Optional, Tuple
import json
import hashlib
import re
import ssl
import subprocess
import tempfile
import time

BUF = 65536
BRIDGE_PORT_DEFAULT = 18787
PLACEHOLDER_RE = re.compile(rb"capbox-sec-[0-9a-f]{32}")


def enter_network_namespace(child: int, command: List[str]) -> None:
    # --disable-userns gives the guest a nested user namespace. Its network
    # namespace can belong to the parent, so /proc/PID/ns/user is not authoritative.
    # NS_GET_USERNS from linux/nsfs.h returns the network namespace's actual owner.
    net_fd = os.open(f"/proc/{child}/ns/net", os.O_RDONLY)
    owner_fd = fcntl.ioctl(net_fd, 0xB701)
    os.set_inheritable(net_fd, True)
    os.set_inheritable(owner_fd, True)
    os.execvp("nsenter", ["nsenter", f"--user=/proc/self/fd/{owner_fd}",
                         f"--net=/proc/self/fd/{net_fd}", "--preserve-credentials",
                         "--", *command])


def _norm_host(h: str) -> str:
    h = (h or "").strip().lower().rstrip(".")
    if h.startswith("[") and h.endswith("]"):
        h = h[1:-1]
    return h


def parse_allowlist(raw: str) -> List[str]:
    out: List[str] = []
    for part in (raw or "").split(","):
        p = part.strip()
        if p:
            out.append(p)
    return out


def _parse_rule(raw: str) -> Tuple[str, Optional[int], bool]:
    """Return (host pattern, explicit port or None, any_port).

    No port means 80 and 443 only. ``:*`` means any port.
    ``*.example.com`` matches subdomains, not the apex.
    """
    raw = (raw or "").strip()
    if raw.startswith("["):
        end = raw.find("]")
        if end > 0:
            host = raw[1:end]
            rest = raw[end + 1 :]
            if rest == ":*":
                return _norm_host(host), None, True
            if rest.startswith(":") and rest[1:].isdigit():
                return _norm_host(host), int(rest[1:]), False
            return _norm_host(host), None, False
    if raw.endswith(":*"):
        return _norm_host(raw[:-2]), None, True
    if ":" in raw:
        host, maybe_port = raw.rsplit(":", 1)
        # unbracketed IPv6 has multiple colons; only split a single trailing :port
        if maybe_port.isdigit() and host.count(":") == 0:
            return _norm_host(host), int(maybe_port), False
    return _norm_host(raw), None, False


def _port_ok(port: Optional[int], rule_port: Optional[int], any_port: bool) -> bool:
    if port is None:
        return True
    if any_port:
        return True
    if rule_port is None:
        return port in (80, 443)
    return port == rule_port


def _host_pattern_match(host: str, pattern: str) -> bool:
    pattern = _norm_host(pattern)
    if pattern.startswith("*."):
        base = pattern[2:]
        # 拒绝 "*.com"：后缀至少再含一个点
        if "." not in base or not base:
            return False
        return host.endswith("." + base)
    return host == pattern


def _ip_for_policy(ip: "ipaddress._BaseAddress") -> "ipaddress._BaseAddress":
    mapped = getattr(ip, "ipv4_mapped", None)
    if mapped is not None:
        return mapped
    return ip


def _ip_forbidden(ip: "ipaddress._BaseAddress") -> bool:
    # is_global is false for RFC1918, loopback, link-local, multicast,
    # reserved, unspecified, and 100.64.0.0/10 (CGNAT / cloud metadata).
    # is_private alone does not cover that CGNAT range on Python 3.13+.
    return not bool(_ip_for_policy(ip).is_global)


def _explicit_ip_allowed(ip: "ipaddress._BaseAddress", allow: Iterable[str]) -> bool:
    for raw in allow:
        host, _port, _any = _parse_rule(raw)
        if not host:
            continue
        try:
            if "/" in host:
                if ip in ipaddress.ip_network(host, strict=False):
                    return True
            elif ip == ipaddress.ip_address(host):
                return True
        except ValueError:
            continue
    return False


def host_allowed(host: str, allow: Iterable[str], port: Optional[int] = None) -> bool:
    host = _norm_host(host)
    if not host:
        return False
    if host.count(":") == 1 and not host.startswith("[") and port is None:
        maybe_host, maybe_port = host.rsplit(":", 1)
        if maybe_port.isdigit():
            host = maybe_host
            port = int(maybe_port)
    rules = list(allow)
    try:
        ip = ipaddress.ip_address(host)
    except ValueError:
        ip = None
    if ip is not None:
        if _ip_forbidden(ip) and not _explicit_ip_allowed(ip, rules):
            return False
        for raw in rules:
            pat, rule_port, any_port = _parse_rule(raw)
            if not _port_ok(port, rule_port, any_port):
                continue
            try:
                if "/" in pat and ip in ipaddress.ip_network(pat, strict=False):
                    return True
                if ip == ipaddress.ip_address(pat):
                    return True
            except ValueError:
                continue
        return False
    for raw in rules:
        pat, rule_port, any_port = _parse_rule(raw)
        if not pat or "/" in pat:
            continue
        try:
            ipaddress.ip_address(pat)
            continue
        except ValueError:
            pass
        if not _port_ok(port, rule_port, any_port):
            continue
        if _host_pattern_match(host, pat):
            return True
    return False


def _dial(host: str, port: int, allow: Iterable[str]) -> socket.socket:
    """Connect after the allowlist check. Names that resolve only to
    loopback / link-local / private / metadata addresses are refused
    unless that address is itself on the allowlist.
    """
    host = _norm_host(host)
    try:
        ipaddress.ip_address(host)
        literal = True
    except ValueError:
        literal = False
    if not host_allowed(host, allow, port):
        raise OSError(f"blocked {host}:{port}")
    if literal:
        return socket.create_connection((host, port), timeout=20)
    try:
        infos = socket.getaddrinfo(host, port, type=socket.SOCK_STREAM)
    except socket.gaierror as exc:
        raise OSError(str(exc)) from exc
    last = "no address"
    for _fam, _type, _proto, _canon, sockaddr in infos:
        ip_s = sockaddr[0].split("%", 1)[0]
        try:
            ip = ipaddress.ip_address(ip_s)
        except ValueError:
            continue
        if _ip_forbidden(ip) and not host_allowed(ip_s, allow, port):
            last = f"blocked resolved {ip_s}"
            continue
        try:
            return socket.create_connection((ip_s, sockaddr[1]), timeout=20)
        except OSError as exc:
            last = str(exc)
    raise OSError(last)


def _split_hostport(authority: str, default_port: int) -> Tuple[str, int]:
    authority = authority.strip()
    if authority.startswith("["):
        # [ipv6]:port
        end = authority.find("]")
        if end < 0:
            return _norm_host(authority), default_port
        host = authority[1:end]
        rest = authority[end + 1 :]
        if rest.startswith(":") and rest[1:].isdigit():
            return _norm_host(host), int(rest[1:])
        return _norm_host(host), default_port
    if authority.count(":") == 1:
        h, p = authority.rsplit(":", 1)
        if p.isdigit():
            return _norm_host(h), int(p)
    return _norm_host(authority), default_port


def _relay(a: socket.socket, b: socket.socket) -> None:
    try:
        while True:
            r, _, _ = select.select([a, b], [], [], 60)
            if not r:
                break
            for s in r:
                other = b if s is a else a
                data = s.recv(BUF)
                if not data:
                    return
                other.sendall(data)
    except OSError:
        return
    finally:
        for s in (a, b):
            try:
                s.shutdown(socket.SHUT_RDWR)
            except OSError:
                pass
            try:
                s.close()
            except OSError:
                pass


def _read_headers(conn: socket.socket) -> bytes:
    buf = b""
    while b"\r\n\r\n" not in buf and len(buf) < 65536:
        chunk = conn.recv(4096)
        if not chunk:
            break
        buf += chunk
    return buf




def load_inject_map(path: Optional[str]) -> Dict[str, Any]:
    if not path:
        return {"entries": []}
    # Host-only 0600 file; never bind into the guest.
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW)
    with os.fdopen(fd, encoding="utf-8") as fh:
        st = os.fstat(fh.fileno())
        if not stat_is_reg(st.st_mode) or (st.st_mode & 0o077):
            raise OSError("inject map must be a regular file mode 0600")
        data = json.load(fh)
    if not isinstance(data, dict):
        raise OSError("invalid inject map")
    data.setdefault("entries", [])
    return data


def stat_is_reg(mode: int) -> bool:
    return (mode & 0o170000) == 0o100000


def _domain_match(host: str, pattern: str) -> bool:
    host = _norm_host(host)
    pattern = _norm_host(pattern)
    if pattern.startswith("*."):
        base = pattern[2:]
        return ("." in base) and host.endswith("." + base) and host != base
    return host == pattern


def _resolve_entry_value(entry: Dict[str, Any], cache: Dict[str, Tuple[str, float]]) -> str:
    name = entry.get("name", "")
    if entry.get("command"):
        now = time.time()
        hit = cache.get(name)
        refresh = float(entry.get("refresh_seconds") or 0)
        if hit and (refresh <= 0 or now - hit[1] < refresh):
            return hit[0]
        proc = subprocess.run(
            ["/bin/bash", "-c", entry["command"]],
            capture_output=True, text=True, timeout=30,
            env={k: os.environ[k] for k in ("PATH", "HOME", "LANG", "XDG_RUNTIME_DIR") if k in os.environ},
        )
        if proc.returncode != 0 or not proc.stdout.strip():
            raise OSError(f"credential command failed for {name}")
        value = proc.stdout.strip()
        if refresh > 0:
            cache[name] = (value, now)
        return value
    value = entry.get("value")
    if not value:
        raise OSError(f"credential missing value for {name}")
    return str(value)


def rewrite_headers_for_credentials(
    header_lines: List[str],
    host: str,
    inject: Dict[str, Any],
    cache: Dict[str, Tuple[str, float]],
    log: bool,
) -> Tuple[List[str], Optional[str]]:
    """Replace placeholders in request headers when host is authorized. Header-only.

    The placeholder token is replaced with the raw secret value. Agents typically
    already wrap env values (e.g. Authorization: Bearer $KEY); we do not re-apply
    format strings during substitution. format is reserved for future whole-header
    injection. Bodies and query strings are never rewritten.
    """
    if not inject.get("entries"):
        return header_lines, None
    blob = "\r\n".join(header_lines)
    if "capbox-sec-" not in blob:
        return header_lines, None
    by_token: Dict[str, Dict[str, Any]] = {}
    for entry in inject["entries"]:
        for token in (entry.get("placeholders") or {}).values():
            by_token[str(token)] = entry
    rebuilt: List[str] = []
    for line in header_lines:
        if ":" not in line:
            rebuilt.append(line)
            continue
        name, value = line.split(":", 1)
        new_value = value
        for token, entry in by_token.items():
            if token not in new_value:
                continue
            domains = entry.get("domains") or []
            if not any(_domain_match(host, d) for d in domains):
                msg = (
                    "凭据未绑定到该主机: placeholder used for unauthorized host %s (secret=%s). "
                    "把该 host 加入密钥 domains 与 CAPBOX_NET_ALLOW，或改用已绑定域名。"
                    % (host, entry.get("name"))
                )
                if log:
                    print(f"capbox-net CRED_DENY {msg}", file=sys.stderr)
                return header_lines, msg
            secret = _resolve_entry_value(entry, cache)
            new_value = new_value.replace(token, secret)
        rebuilt.append(f"{name.strip()}: {new_value.lstrip()}")
    return rebuilt, None


def mint_mitm_cert(ca_key_path: str, ca_cert_path: str, host: str) -> Tuple[bytes, bytes]:
    from cryptography import x509
    from cryptography.hazmat.primitives import hashes, serialization
    from cryptography.hazmat.primitives.asymmetric import rsa
    from cryptography.x509.oid import NameOID, ExtendedKeyUsageOID
    import datetime as dt

    with open(ca_key_path, "rb") as fh:
        ca_key = serialization.load_pem_private_key(fh.read(), password=None)
    with open(ca_cert_path, "rb") as fh:
        ca_cert = x509.load_pem_x509_certificate(fh.read())
    key = rsa.generate_private_key(public_exponent=65537, key_size=2048)
    subject = x509.Name([x509.NameAttribute(NameOID.COMMON_NAME, host)])
    now = dt.datetime.now(dt.timezone.utc)
    try:
        import ipaddress
        san = [x509.IPAddress(ipaddress.ip_address(host))]
    except ValueError:
        san = [x509.DNSName(host)]
    cert = (
        x509.CertificateBuilder()
        .subject_name(subject)
        .issuer_name(ca_cert.subject)
        .public_key(key.public_key())
        .serial_number(x509.random_serial_number())
        .not_valid_before(now - dt.timedelta(minutes=5))
        .not_valid_after(now + dt.timedelta(days=1))
        .add_extension(x509.SubjectAlternativeName(san), critical=False)
        .add_extension(x509.ExtendedKeyUsage([ExtendedKeyUsageOID.SERVER_AUTH]), critical=False)
        .add_extension(x509.SubjectKeyIdentifier.from_public_key(key.public_key()), critical=False)
        .add_extension(x509.AuthorityKeyIdentifier.from_issuer_public_key(ca_key.public_key()), critical=False)
        .sign(ca_key, hashes.SHA256())
    )
    return (
        key.private_bytes(
            encoding=serialization.Encoding.PEM,
            format=serialization.PrivateFormat.TraditionalOpenSSL,
            encryption_algorithm=serialization.NoEncryption(),
        ),
        cert.public_bytes(serialization.Encoding.PEM),
    )


def host_needs_mitm(host: str, inject: Dict[str, Any]) -> bool:
    for entry in inject.get("entries") or []:
        if any(_domain_match(host, d) for d in (entry.get("domains") or [])):
            return True
    return False


def handle_client(conn: socket.socket, allow: List[str], log: bool, inject: Optional[Dict[str, Any]] = None, cache: Optional[Dict[str, Tuple[str, float]]] = None) -> None:
    inject = inject or {"entries": []}
    cache = cache if cache is not None else {}
    try:
        head = _read_headers(conn)
        if not head:
            conn.close()
            return
        try:
            header_blob, body = head.split(b"\r\n\r\n", 1)
            header_text = header_blob.decode("iso-8859-1", "replace")
        except Exception:
            conn.sendall(b"HTTP/1.1 400 Bad Request\r\nConnection: close\r\n\r\n")
            conn.close()
            return
        lines = header_text.split("\r\n")
        if not lines:
            conn.close()
            return
        parts = lines[0].split()
        if len(parts) < 2:
            conn.sendall(b"HTTP/1.1 400 Bad Request\r\nConnection: close\r\n\r\n")
            conn.close()
            return
        method, target = parts[0].upper(), parts[1]
        headers = {}
        for line in lines[1:]:
            if ":" in line:
                k, v = line.split(":", 1)
                headers[k.strip().lower()] = v.strip()

        if method == "CONNECT":
            host, port = _split_hostport(target, 443)
            if not host_allowed(host, allow, port):
                if log:
                    print(f"capbox-net DENY CONNECT {host}:{port}", file=sys.stderr)
                conn.sendall(b"HTTP/1.1 403 Forbidden\r\nConnection: close\r\n\r\n")
                conn.close()
                return
            if log:
                print(f"capbox-net ALLOW CONNECT {host}:{port}", file=sys.stderr)
            # Credential-bound hosts: TLS MITM so we can rewrite Authorization headers.
            if host_needs_mitm(host, inject) and inject.get("ca_key") and inject.get("ca_cert"):
                try:
                    upstream_tcp = _dial(host, port, allow)
                except OSError:
                    conn.sendall(b"HTTP/1.1 502 Bad Gateway\r\nConnection: close\r\n\r\n")
                    conn.close()
                    return
                conn.sendall(b"HTTP/1.1 200 Connection Established\r\n\r\n")
                try:
                    key_pem, cert_pem = mint_mitm_cert(inject["ca_key"], inject["ca_cert"], host)
                    ctx_client = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
                    ctx_client.minimum_version = ssl.TLSVersion.TLSv1_2
                    # Keep PEM files until after wrap_socket loads them into the context.
                    tmp = tempfile.mkdtemp(prefix="capbox-mitm-")
                    try:
                        kpath = os.path.join(tmp, "k.pem")
                        cpath = os.path.join(tmp, "c.pem")
                        with open(kpath, "wb") as fh:
                            fh.write(key_pem)
                        with open(cpath, "wb") as fh:
                            fh.write(cert_pem)
                        os.chmod(kpath, 0o600)
                        os.chmod(cpath, 0o600)
                        ctx_client.load_cert_chain(cpath, kpath)
                        client_tls = ctx_client.wrap_socket(conn, server_side=True)
                    finally:
                        try:
                            os.unlink(kpath)
                            os.unlink(cpath)
                            os.rmdir(tmp)
                        except OSError:
                            pass
                    ctx_up = ssl.create_default_context()
                    ctx_up.minimum_version = ssl.TLSVersion.TLSv1_2
                    upstream = ctx_up.wrap_socket(upstream_tcp, server_hostname=host)
                    # Read one HTTP request from guest, rewrite headers, forward.
                    req = _read_headers(client_tls)
                    if not req:
                        client_tls.close(); upstream.close(); return
                    header_blob, body = req.split(b"\r\n\r\n", 1)
                    lines = header_blob.decode("iso-8859-1", "replace").split("\r\n")
                    rebuilt, violation = rewrite_headers_for_credentials(lines, host, inject, cache, log)
                    if violation:
                        client_tls.sendall(b"HTTP/1.1 403 Forbidden\r\nConnection: close\r\n\r\n")
                        client_tls.close(); upstream.close(); return
                    # First line is request line; rebuild absolute-form-less request.
                    out = ("\r\n".join(rebuilt) + "\r\n\r\n").encode("iso-8859-1", "replace") + body
                    upstream.sendall(out)
                    _relay(client_tls, upstream)
                except Exception as exc:  # noqa: BLE001
                    if log:
                        print(f"capbox-net MITM error: {exc}", file=sys.stderr)
                    try:
                        conn.close()
                    except OSError:
                        pass
                return
            try:
                upstream = _dial(host, port, allow)
            except OSError:
                conn.sendall(b"HTTP/1.1 502 Bad Gateway\r\nConnection: close\r\n\r\n")
                conn.close()
                return
            conn.sendall(b"HTTP/1.1 200 Connection Established\r\n\r\n")
            _relay(conn, upstream)
            return

        host_hdr = headers.get("host", "")
        default_port = 80
        if target.startswith("https://"):
            default_port = 443
        if target.startswith("http://") or target.startswith("https://"):
            rest = target.split("://", 1)[1]
            if "/" in rest:
                auth, path = rest.split("/", 1)
                target_path = "/" + path
            else:
                auth, target_path = rest, "/"
            host, port = _split_hostport(auth, default_port)
        else:
            host, port = _split_hostport(host_hdr, default_port)
            target_path = target
        if not host:
            conn.sendall(b"HTTP/1.1 400 Bad Request\r\nConnection: close\r\n\r\n")
            conn.close()
            return

        if not host_allowed(host, allow, port):
            if log:
                print(f"capbox-net DENY {method} {host}", file=sys.stderr)
            conn.sendall(b"HTTP/1.1 403 Forbidden\r\nConnection: close\r\n\r\n")
            conn.close()
            return
        if log:
            print(f"capbox-net ALLOW {method} {host}:{port}", file=sys.stderr)
        try:
            upstream = _dial(host, port, allow)
        except OSError:
            conn.sendall(b"HTTP/1.1 502 Bad Gateway\r\nConnection: close\r\n\r\n")
            conn.close()
            return

        skip = {"proxy-connection", "proxy-authorization", "connection", "keep-alive", "te", "transfer-encoding"}
        # Credential placeholder rewrite (header values only).
        rewritten, violation = rewrite_headers_for_credentials(lines, host, inject, cache, log)
        if violation:
            conn.sendall(b"HTTP/1.1 403 Forbidden\r\nConnection: close\r\n\r\n")
            conn.close()
            return
        lines = rewritten
        out_headers = []
        saw_host = False
        for line in lines[1:]:
            if not line or ":" not in line:
                continue
            k, v = line.split(":", 1)
            kl = k.strip().lower()
            if kl in skip:
                continue
            if kl == "host":
                saw_host = True
                out_headers.append(f"Host: {host_hdr or host}")
            else:
                out_headers.append(f"{k.strip()}: {v.strip()}")
        if not saw_host:
            out_headers.insert(0, f"Host: {host_hdr or host}")
        out_headers.append("Connection: close")
        req_bytes = (
            f"{method} {target_path} HTTP/1.1\r\n".encode("ascii", "replace")
            + ("\r\n".join(out_headers) + "\r\n\r\n").encode("iso-8859-1", "replace")
            + body
        )
        upstream.sendall(req_bytes)
        _relay(conn, upstream)
    except Exception as exc:  # noqa: BLE001
        try:
            conn.sendall(b"HTTP/1.1 500 Internal Server Error\r\nConnection: close\r\n\r\n")
        except OSError:
            pass
        try:
            conn.close()
        except OSError:
            pass
        if log:
            print(f"capbox-net error: {exc}", file=sys.stderr)


def cmd_proxy(args: argparse.Namespace) -> int:
    allow = parse_allowlist(args.allow)
    if not allow:
        print("capbox-net: allowlist empty", file=sys.stderr)
        return 2
    inject = load_inject_map(getattr(args, "inject_map", None))
    cache: Dict[str, Tuple[str, float]] = {}
    sock_path = args.sock
    if os.path.exists(sock_path):
        os.unlink(sock_path)
    os.makedirs(os.path.dirname(sock_path) or ".", exist_ok=True)
    server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    server.bind(sock_path)
    os.chmod(sock_path, 0o600)
    server.listen(128)
    if args.ready:
        with open(args.ready, "w", encoding="utf-8") as fh:
            fh.write("ready\n")
    print(f"capbox-net proxy listening on unix:{sock_path} allow={','.join(allow)}", file=sys.stderr)
    try:
        while True:
            conn, _ = server.accept()
            t = threading.Thread(target=handle_client, args=(conn, allow, args.log, inject, cache), daemon=True)
            t.start()
    except KeyboardInterrupt:
        return 0
    finally:
        try:
            server.close()
        except OSError:
            pass
        try:
            os.unlink(sock_path)
        except OSError:
            pass


def cmd_bridge(args: argparse.Namespace) -> int:
    # Listen on TCP in current netns; forward to UNIX sock (host mount ns).
    host, port_s = args.listen.split(":", 1)
    port = int(port_s)
    # Bring-up of lo is done by CapBox shell before invoking bridge.
    server = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    server.bind((host, port))
    server.listen(128)
    if args.ready:
        with open(args.ready, "w", encoding="utf-8") as fh:
            fh.write("ready\n")
    print(f"capbox-net bridge {host}:{port} -> unix:{args.sock}", file=sys.stderr)

    def one(c: socket.socket) -> None:
        try:
            u = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            u.connect(args.sock)
            _relay(c, u)
        except OSError:
            try:
                c.close()
            except OSError:
                pass

    try:
        while True:
            c, _ = server.accept()
            threading.Thread(target=one, args=(c,), daemon=True).start()
    except KeyboardInterrupt:
        return 0


def cmd_check_allow(args: argparse.Namespace) -> int:
    allow = parse_allowlist(args.allow)
    host = args.host
    ok = host_allowed(host, allow)
    print("allow" if ok else "deny")
    return 0 if ok else 1


def main(argv: Optional[List[str]] = None) -> int:
    p = argparse.ArgumentParser(prog="capbox-net")
    sub = p.add_subparsers(dest="cmd", required=True)

    p_enter = sub.add_parser("enter-net")
    p_enter.add_argument("--child", required=True, type=int)
    p_enter.add_argument("command", nargs=argparse.REMAINDER)

    def enter(args: argparse.Namespace) -> int:
        cmd = args.command[1:] if args.command[:1] == ["--"] else args.command
        if args.child <= 0 or not cmd:
            p.error("enter-net needs a positive child PID and a command")
        enter_network_namespace(args.child, cmd)
        return 1

    p_enter.set_defaults(func=enter)

    p_proxy = sub.add_parser("proxy")
    p_proxy.add_argument("--sock", required=True)
    p_proxy.add_argument("--allow", required=True)
    p_proxy.add_argument("--ready")
    p_proxy.add_argument("--log", action="store_true")
    p_proxy.add_argument("--inject-map", help="host-only credential inject map (0600 JSON)")
    p_proxy.set_defaults(func=cmd_proxy)

    p_br = sub.add_parser("bridge")
    p_br.add_argument("--listen", default=f"127.0.0.1:{BRIDGE_PORT_DEFAULT}")
    p_br.add_argument("--sock", required=True)
    p_br.add_argument("--ready")
    p_br.set_defaults(func=cmd_bridge)

    p_ck = sub.add_parser("check-allow")
    p_ck.add_argument("--allow", required=True)
    p_ck.add_argument("--host", required=True)
    p_ck.set_defaults(func=cmd_check_allow)

    args = p.parse_args(argv)
    return int(args.func(args) or 0)


if __name__ == "__main__":
    sys.exit(main())
