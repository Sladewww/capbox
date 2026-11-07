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
from typing import Iterable, List, Optional, Tuple

BUF = 65536
BRIDGE_PORT_DEFAULT = 18787


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



def handle_client(conn: socket.socket, allow: List[str], log: bool) -> None:
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
            t = threading.Thread(target=handle_client, args=(conn, allow, args.log), daemon=True)
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
