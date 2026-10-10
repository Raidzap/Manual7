#!/usr/bin/env python3
"""Pair a Linux computer with Manual7 by one-use QR and open its SSH tunnel."""

from __future__ import annotations

import argparse
import dataclasses
import http.server
import ipaddress
import json
import os
import re
import secrets
import shutil
import socket
import subprocess
import sys
import time
import urllib.parse
from pathlib import Path, PurePosixPath
from typing import Any

API_SOCKET = "/var/tmp/Manual7-api.sock"
WEBCAM_SOCKET = "/var/tmp/Manual7-webcam.sock"
API_BRIDGE_PORT = 27839
WEBCAM_BRIDGE_PORT = 27840
PAIR_PATH = "/v1/pair"
MAX_BODY = 16 * 1024


class PairingError(RuntimeError):
    pass


@dataclasses.dataclass
class PairingState:
    token: str
    result: dict[str, Any] | None = None
    peer_ip: str = ""
    rejected: int = 0


def private_ipv4(value: str) -> str:
    try:
        address = ipaddress.ip_address(value)
    except ValueError as exc:
        raise argparse.ArgumentTypeError("use um endereço IPv4 válido") from exc
    networks = (
        ipaddress.ip_network("10.0.0.0/8"),
        ipaddress.ip_network("172.16.0.0/12"),
        ipaddress.ip_network("192.168.0.0/16"),
        ipaddress.ip_network("169.254.0.0/16"),
    )
    if address.version != 4 or not any(address in network for network in networks):
        raise argparse.ArgumentTypeError("use o IPv4 privado deste notebook na rede do iPhone")
    return str(address)


def discover_local_ipv4() -> str:
    candidates: list[str] = []
    probe = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    try:
        probe.connect(("192.0.2.1", 9))
        candidates.append(probe.getsockname()[0])
    except OSError:
        pass
    finally:
        probe.close()
    try:
        candidates.extend(socket.gethostbyname_ex(socket.gethostname())[2])
    except OSError:
        pass
    for candidate in candidates:
        try:
            return private_ipv4(candidate)
        except argparse.ArgumentTypeError:
            continue
    raise PairingError("Não encontrei o IPv4 da rede local. Use --listen-host 192.168.x.x.")


def build_pairing_uri(callback: str, token: str, name: str) -> str:
    clean_name = " ".join(name.split())[:64] or "Notebook Linux"
    query = urllib.parse.urlencode({"callback": callback, "token": token, "name": clean_name})
    return f"manual7://pair?{query}"


def validate_socket_path(value: Any, role: str) -> str:
    long_name = "Manual7-api.sock" if role == "api" else "Manual7-webcam.sock"
    short_name = "m7a" if role == "api" else "m7w"
    if not isinstance(value, str) or not value.startswith("/") or ":" in value:
        raise PairingError(f"socket {role} precisa ser um caminho absoluto sem dois-pontos")
    if any(ord(character) < 32 for character in value) or len(value.encode()) >= 104:
        raise PairingError(f"caminho do socket {role} é inválido")
    path = PurePosixPath(value)
    if path.name not in (long_name, short_name) or ".." in path.parts:
        raise PairingError(f"nome do socket {role} é inválido")
    allowed = (
        f"/var/tmp/{long_name}", f"/tmp/{long_name}", f"/private/var/tmp/{long_name}",
        f"/var/tmp/{short_name}", f"/tmp/{short_name}", f"/private/var/tmp/{short_name}",
    )
    escaped = re.escape(short_name)
    container = re.fullmatch(
        rf"/(?:private/)?var/mobile/Containers/Data/Application/[A-Za-z0-9-]+/tmp/{escaped}",
        value,
    )
    if value not in allowed and not container:
        raise PairingError(f"socket {role} fora dos diretórios permitidos")
    return value


def validate_result(value: Any) -> dict[str, Any]:
    if not isinstance(value, dict):
        raise PairingError("resposta JSON precisa ser um objeto")
    pin = value.get("pin")
    if not isinstance(pin, str) or len(pin) != 6 or not pin.isdigit():
        raise PairingError("PIN recebido é inválido")
    ports = value.get("availableSSHPorts")
    if not isinstance(ports, list):
        raise PairingError("lista de portas SSH ausente")
    clean_ports = [port for port in ports if isinstance(port, int) and 1 <= port <= 65535]
    preferred = value.get("preferredSSHPort")
    if not isinstance(preferred, int) or preferred not in clean_ports:
        preferred = clean_ports[0] if clean_ports else 0
    if not preferred:
        raise PairingError("o M7 não encontrou o servidor OpenSSH ativo nas portas 22/2222")
    api_socket = validate_socket_path(value.get("apiSocket"), "api")
    webcam_socket = validate_socket_path(value.get("webcamSocket"), "webcam")
    api_bridge_port = value.get("apiBridgePort")
    webcam_bridge_port = value.get("webcamBridgePort")
    if api_bridge_port != API_BRIDGE_PORT or webcam_bridge_port != WEBCAM_BRIDGE_PORT:
        raise PairingError("as portas TCP do bridge não correspondem ao Manual7 0.7.5")
    if PurePosixPath(api_socket).parent != PurePosixPath(webcam_socket).parent:
        raise PairingError("os sockets da API e webcam precisam usar o mesmo diretório")
    return {**value, "preferredSSHPort": preferred, "availableSSHPorts": clean_ports,
            "apiSocket": api_socket, "webcamSocket": webcam_socket,
            "apiBridgePort": api_bridge_port, "webcamBridgePort": webcam_bridge_port}


def handler_for(state: PairingState) -> type[http.server.BaseHTTPRequestHandler]:
    class PairingHandler(http.server.BaseHTTPRequestHandler):
        server_version = "Manual7Pair/0.7"

        def log_message(self, _format: str, *_args: object) -> None:
            return

        def reply(self, status: int, body: dict[str, Any]) -> None:
            payload = json.dumps(body, separators=(",", ":")).encode()
            self.send_response(status)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(payload)))
            self.send_header("Connection", "close")
            self.end_headers()
            self.wfile.write(payload)

        def do_POST(self) -> None:  # noqa: N802 - BaseHTTPRequestHandler API
            if self.path != PAIR_PATH:
                state.rejected += 1
                self.reply(404, {"ok": False, "error": "endpoint desconhecido"})
                return
            if state.result is not None:
                state.rejected += 1
                self.reply(409, {"ok": False, "error": "QR já utilizado"})
                return
            if self.headers.get_content_type() != "application/json":
                state.rejected += 1
                self.reply(415, {"ok": False, "error": "Content-Type precisa ser application/json"})
                return
            supplied = self.headers.get("X-Manual7-Pairing", "")
            if not secrets.compare_digest(supplied, state.token):
                state.rejected += 1
                self.reply(403, {"ok": False, "error": "token inválido"})
                return
            try:
                length = int(self.headers.get("Content-Length", "0"))
            except ValueError:
                length = 0
            if length <= 0 or length > MAX_BODY:
                state.rejected += 1
                self.reply(413, {"ok": False, "error": "corpo inválido"})
                return
            try:
                decoded = json.loads(self.rfile.read(length))
                result = validate_result(decoded)
            except (json.JSONDecodeError, UnicodeDecodeError, PairingError) as exc:
                state.rejected += 1
                self.reply(400, {"ok": False, "error": str(exc)})
                return
            state.peer_ip = self.client_address[0]
            state.result = result
            self.reply(200, {"ok": True, "message": "Notebook reconhecido"})

    return PairingHandler


def render_qr(payload: str, output: Path | None) -> None:
    executable = shutil.which("qrencode")
    if not executable:
        raise PairingError("qrencode não está instalado. No Debian/Ubuntu: sudo apt install qrencode")
    # Feed the one-use token over stdin so it is not visible in the process list.
    subprocess.run([executable, "-t", "ANSIUTF8", "-m", "1"],
                   input=payload, text=True, check=True)
    if output:
        subprocess.run([executable, "-o", str(output), "-s", "8", "-m", "2"],
                       input=payload, text=True, check=True)
        print(f"QR salvo em {output}")


def wait_for_pairing(server: http.server.HTTPServer, state: PairingState, timeout: float) -> dict[str, Any]:
    deadline = time.monotonic() + timeout
    while state.result is None:
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            raise PairingError(f"Nenhum iPhone pareou em {int(timeout)} segundos.")
        server.timeout = min(0.5, remaining)
        server.handle_request()
    return state.result


def ssh_command(peer_ip: str, result: dict[str, Any], args: argparse.Namespace) -> list[str]:
    port = args.ssh_port or int(result["preferredSSHPort"])
    return [
        "ssh", "-N", "-p", str(port),
        "-o", "ExitOnForwardFailure=yes",
        "-o", "StrictHostKeyChecking=accept-new",
        "-L", f"127.0.0.1:{args.local_port}:127.0.0.1:{result['apiBridgePort']}",
        "-L", f"127.0.0.1:{args.webcam_local_port}:127.0.0.1:{result['webcamBridgePort']}",
        f"{args.user}@{peer_ip}",
    ]


def parser() -> argparse.ArgumentParser:
    result = argparse.ArgumentParser(description="Pareia Manual7 por QR e abre os túneis SSH da API/webcam.")
    result.add_argument("--listen-host", type=private_ipv4, help="IPv4 deste notebook visível pelo iPhone")
    result.add_argument("--listen-port", type=int, default=0, help="porta temporária do callback (padrão: automática)")
    result.add_argument("--timeout", type=float, default=90, help="validade do QR em segundos")
    result.add_argument("--name", default=socket.gethostname(), help="nome exibido no M7")
    result.add_argument("--output", type=Path, help="também salva o QR em PNG")
    result.add_argument("--user", default="mobile", help="usuário SSH do iPhone")
    result.add_argument("--ssh-port", type=int, choices=range(1, 65536), metavar="PORT")
    result.add_argument("--local-port", type=int, default=17837)
    result.add_argument("--webcam-local-port", type=int, default=17838)
    result.add_argument("--no-tunnel", action="store_true", help="valida o retorno sem iniciar SSH")
    return result


def main(argv: list[str] | None = None) -> int:
    args = parser().parse_args(argv)
    if not (1 <= args.local_port <= 65535 and 1 <= args.webcam_local_port <= 65535):
        raise PairingError("as portas locais precisam estar entre 1 e 65535")
    if args.local_port == args.webcam_local_port:
        raise PairingError("a API e a webcam precisam usar portas locais diferentes")
    if args.listen_port < 0 or args.listen_port > 65535 or args.timeout < 5 or args.timeout > 600:
        raise PairingError("use porta válida e timeout entre 5 e 600 segundos")
    host = args.listen_host or discover_local_ipv4()
    token = secrets.token_urlsafe(32)
    state = PairingState(token=token)
    server = http.server.HTTPServer((host, args.listen_port), handler_for(state))
    try:
        callback = f"http://{host}:{server.server_port}{PAIR_PATH}"
        payload = build_pairing_uri(callback, token, args.name)
        print("\nNo iPhone, abra M7 e toque em Conexão → Ler QR do PC:\n")
        render_qr(payload, args.output)
        print(f"\nAguardando por até {int(args.timeout)} segundos em {host}:{server.server_port}…")
        result = wait_for_pairing(server, state, args.timeout)
    finally:
        server.server_close()
        state.token = ""
        token = ""
        if "payload" in locals():
            payload = ""
    print(f"\nM7 reconhecido em {state.peer_ip}; SSH {result['preferredSSHPort']}.")
    print(f"Em outro terminal: export MANUAL7_PIN={result['pin']}")
    if args.no_tunnel:
        print("Retorno validado; --no-tunnel impediu a abertura do SSH.")
        return 0
    command = ssh_command(state.peer_ip, result, args)
    print("Abrindo API em 127.0.0.1:%d e webcam em 127.0.0.1:%d." %
          (args.local_port, args.webcam_local_port))
    print("Mantenha este terminal aberto. O SSH pode pedir confirmação da chave e autenticação.\n")
    return subprocess.call(command)


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (PairingError, OSError, subprocess.CalledProcessError) as exc:
        print(f"manual7_pair: {exc}", file=sys.stderr)
        raise SystemExit(2)
