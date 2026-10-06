#!/usr/bin/env python3
"""Manual7 remote-control client for Linux/macOS using only the Python stdlib."""

from __future__ import annotations

import argparse
import json
import os
import socket
import subprocess
import sys
import time
import urllib.error
import urllib.request
from pathlib import Path
from typing import Any


DEFAULT_URL = "http://127.0.0.1:17837"


class RemoteError(RuntimeError):
    def __init__(self, status: int, body: Any):
        self.status = status
        self.body = body
        message = body.get("error") if isinstance(body, dict) else str(body)
        super().__init__(f"HTTP {status}: {message or 'erro remoto'}")


def parse_value(text: str) -> Any:
    lowered = text.lower()
    if lowered == "true":
        return True
    if lowered == "false":
        return False
    if lowered == "null":
        return None
    try:
        return json.loads(text)
    except json.JSONDecodeError:
        return text


def request(base_url: str, pin: str | None, method: str, path: str,
            body: dict[str, Any] | None = None, timeout: float = 15) -> dict[str, Any]:
    payload = None if body is None else json.dumps(body).encode("utf-8")
    headers = {"Accept": "application/json"}
    if payload is not None:
        headers["Content-Type"] = "application/json"
    if pin:
        headers["X-Manual7-PIN"] = pin
    req = urllib.request.Request(base_url.rstrip("/") + path, data=payload,
                                 headers=headers, method=method)
    try:
        with urllib.request.urlopen(req, timeout=timeout) as response:
            data = response.read()
            return json.loads(data) if data else {}
    except urllib.error.HTTPError as exc:
        raw = exc.read()
        try:
            parsed = json.loads(raw) if raw else {}
        except json.JSONDecodeError:
            parsed = raw.decode("utf-8", errors="replace")
        raise RemoteError(exc.code, parsed) from exc


def print_json(value: Any) -> None:
    print(json.dumps(value, ensure_ascii=False, indent=2, sort_keys=True))


def command(base_url: str, pin: str, name: str, **values: Any) -> dict[str, Any]:
    return request(base_url, pin, "POST", "/v1/command", {"command": name, **values})


def choose_ssh_port(host: str, requested: int | None, timeout: float = 1.5) -> int:
    """Returns an explicit port or probes the two Procursus launchd sockets."""
    if requested is not None:
        if requested < 1 or requested > 65535:
            raise ValueError("a porta SSH deve estar entre 1 e 65535")
        return requested
    failures = []
    for port in (22, 2222):
        try:
            with socket.create_connection((host, port), timeout=timeout):
                return port
        except OSError as exc:
            failures.append(f"{port}: {exc}")
    raise OSError(f"OpenSSH não respondeu em {host} nas portas 22 ou 2222 ({'; '.join(failures)})")


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="Controle remoto do Manual7 por túnel SSH.")
    parser.add_argument("--url", default=os.environ.get("MANUAL7_URL", DEFAULT_URL))
    parser.add_argument("--pin", default=os.environ.get("MANUAL7_PIN"),
                        help="PIN mostrado no M7; também pode usar MANUAL7_PIN.")
    sub = parser.add_subparsers(dest="subcommand", required=True)
    sub.add_parser("ping", help="Verifica se o servidor M7 está acessível.")
    sub.add_parser("state", help="Exibe controles e estado atual.")
    diagnostic = sub.add_parser("diagnostic", help="Obtém o relatório completo.")
    diagnostic.add_argument("--output", type=Path)
    sub.add_parser("capture", help="Aciona o disparador conforme o modo atual.")
    sub.add_parser("photo", help="Fotografa; requer modo Foto.")
    record = sub.add_parser("record", help="Inicia, para ou alterna a gravação.")
    record.add_argument("action", choices=("start", "stop", "toggle"))
    setting = sub.add_parser("set", help="Altera um controle do M7.")
    setting.add_argument("control")
    setting.add_argument("value")
    retry = sub.add_parser("retry", help="Repete uma gravação pendente no Fotos.")
    retry.add_argument("kind", choices=("photo", "videos"))
    sub.add_parser("close", help="Fecha o painel M7 após responder.")
    watch = sub.add_parser("watch", help="Atualiza o estado continuamente.")
    watch.add_argument("--interval", type=float, default=1.0)
    tunnel = sub.add_parser("tunnel", help="Abre o encaminhamento SSH para o iPhone.")
    tunnel.add_argument("host", help="IP ou nome do iPhone.")
    tunnel.add_argument("--user", default="mobile")
    tunnel.add_argument("--ssh-port", type=int,
                        help="Porta SSH explícita; sem esta opção, testa 22 e 2222.")
    tunnel.add_argument("--local-port", type=int, default=17837)
    return parser


def main(argv: list[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    if args.subcommand == "tunnel":
        try:
            ssh_port = choose_ssh_port(args.host, args.ssh_port)
        except (OSError, ValueError) as exc:
            print(f"Manual7: {exc}", file=sys.stderr)
            return 1
        target = f"{args.user}@{args.host}"
        forwarding = f"{args.local_port}:127.0.0.1:17837"
        print(f"Abrindo http://127.0.0.1:{args.local_port} → {target}:17837 via SSH {ssh_port}",
              file=sys.stderr)
        return subprocess.call(["ssh", "-p", str(ssh_port), "-N", "-L", forwarding,
                                "-o", "ExitOnForwardFailure=yes", target])
    if args.subcommand != "ping" and not args.pin:
        print("Informe --pin ou defina MANUAL7_PIN com o PIN mostrado no iPhone.", file=sys.stderr)
        return 2
    try:
        if args.subcommand == "ping":
            result = request(args.url, None, "GET", "/v1/ping")
        elif args.subcommand == "state":
            result = request(args.url, args.pin, "GET", "/v1/state")
        elif args.subcommand == "diagnostic":
            result = request(args.url, args.pin, "GET", "/v1/diagnostic", timeout=30)
            if args.output:
                args.output.write_text(json.dumps(result, ensure_ascii=False, indent=2) + "\n",
                                       encoding="utf-8")
                print(args.output)
                return 0
        elif args.subcommand == "capture":
            result = command(args.url, args.pin, "capture")
        elif args.subcommand == "photo":
            result = command(args.url, args.pin, "photo.capture")
        elif args.subcommand == "record":
            result = command(args.url, args.pin, f"record.{args.action}")
        elif args.subcommand == "set":
            result = command(args.url, args.pin, "set", control=args.control,
                             value=parse_value(args.value))
        elif args.subcommand == "retry":
            result = command(args.url, args.pin, f"{args.kind}.retry")
        elif args.subcommand == "close":
            result = command(args.url, args.pin, "close")
        elif args.subcommand == "watch":
            while True:
                result = request(args.url, args.pin, "GET", "/v1/state")
                print("\033[2J\033[H", end="")
                print_json(result)
                time.sleep(max(.2, args.interval))
        else:
            raise AssertionError(args.subcommand)
        print_json(result)
        return 0
    except KeyboardInterrupt:
        return 130
    except (RemoteError, OSError, urllib.error.URLError, json.JSONDecodeError) as exc:
        print(f"Manual7: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
