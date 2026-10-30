#!/usr/bin/env python3
"""Manual7 remote-control client for Linux/macOS using only the Python stdlib."""

from __future__ import annotations

import argparse
import json
import os
import plistlib
import shlex
import shutil
import socket
import struct
import subprocess
import sys
import threading
import time
import urllib.error
import urllib.request
from pathlib import Path
from typing import Any


DEFAULT_URL = "http://127.0.0.1:17837"
DEFAULT_REMOTE_SOCKET = "/var/tmp/Manual7-api.sock"
DEFAULT_WEBCAM_URL = "http://127.0.0.1:17838/v1/webcam.mjpg"
DEFAULT_WEBCAM_SOCKET = "/var/tmp/Manual7-webcam.sock"
DEFAULT_REMOTE_PORT = 27839
DEFAULT_WEBCAM_REMOTE_PORT = 27840
USBMUXD_SOCKET = "/var/run/usbmuxd"
USB_HOST_ALIAS = "manual7-usb"


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


def usbmux_address() -> tuple[int, Any]:
    value = os.environ.get("USBMUXD_SOCKET_ADDRESS", "")
    if value.startswith("UNIX:"):
        return socket.AF_UNIX, value[5:]
    if ":" in value:
        host, port = value.rsplit(":", 1)
        return socket.AF_INET, (host, int(port))
    return socket.AF_UNIX, USBMUXD_SOCKET


def usbmux_exchange(message: dict[str, Any],
                    timeout: float = 2.0) -> tuple[dict[str, Any], socket.socket, bytes]:
    """Sends one plist request to usbmuxd; returns the reply, the socket and
    any bytes that followed the reply (the start of a Connect tunnel)."""
    family, address = usbmux_address()
    sock = socket.socket(family, socket.SOCK_STREAM)
    try:
        sock.settimeout(timeout)
        sock.connect(address)
        payload = plistlib.dumps({"ClientVersionString": "manual7_remote",
                                  "ProgName": "manual7_remote", **message})
        sock.sendall(struct.pack("<IIII", 16 + len(payload), 1, 8, 1) + payload)
        buffer = b""
        while len(buffer) < 16 or len(buffer) < struct.unpack_from("<I", buffer)[0]:
            chunk = sock.recv(65536)
            if not chunk:
                raise OSError("usbmuxd encerrou a conexão")
            buffer += chunk
            if len(buffer) >= 16 and not 16 <= struct.unpack_from("<I", buffer)[0] <= 1 << 20:
                raise OSError("resposta inválida do usbmuxd")
        length = struct.unpack_from("<I", buffer)[0]
        reply = plistlib.loads(buffer[16:length])
        sock.settimeout(None)
        return reply, sock, buffer[length:]
    except BaseException:
        sock.close()
        raise


def usb_devices() -> list[dict[str, Any]]:
    reply, sock, _ = usbmux_exchange({"MessageType": "ListDevices"})
    sock.close()
    return [entry.get("Properties", {}) for entry in reply.get("DeviceList", [])
            if entry.get("Properties", {}).get("ConnectionType") == "USB"]


def usb_connect(port: int) -> tuple[socket.socket, bytes]:
    """Opens a TCP connection to `port` on the only iPhone attached by USB."""
    try:
        devices = usb_devices()
    except OSError as exc:
        raise OSError(f"usbmuxd indisponível ({exc}); instale o pacote usbmuxd") from exc
    if len(devices) != 1:
        raise OSError(f"conecte exatamente um iPhone por USB (encontrados: {len(devices)})")
    # usbmuxd expects the port in network byte order inside a host integer.
    swapped = ((port & 0xff) << 8) | ((port >> 8) & 0xff)
    reply, sock, extra = usbmux_exchange({"MessageType": "Connect",
                                          "DeviceID": devices[0]["DeviceID"],
                                          "PortNumber": swapped})
    if reply.get("MessageType") != "Result" or reply.get("Number") != 0:
        sock.close()
        raise OSError(f"o iPhone recusou a conexão USB na porta {port} "
                      f"(usbmuxd {reply.get('Number', '?')})")
    return sock, extra


def usb_proxy(port: int) -> int:
    """Relays stdin/stdout to the iPhone over USB, for ssh's ProxyCommand."""
    sock, extra = usb_connect(port)
    if extra:
        os.write(1, extra)

    def upload() -> None:
        try:
            while chunk := os.read(0, 65536):
                sock.sendall(chunk)
        except OSError:
            pass
        try:
            sock.shutdown(socket.SHUT_WR)
        except OSError:
            pass

    threading.Thread(target=upload, daemon=True).start()
    try:
        while chunk := sock.recv(65536):
            os.write(1, chunk)
    except OSError:
        return 1
    finally:
        sock.close()
    return 0


def usb_ssh_options() -> list[str]:
    """ssh options that reach the iPhone through usb-proxy. A separate host
    key alias keeps the USB entry apart from the Wi-Fi address in known_hosts."""
    proxy = " ".join(shlex.quote(part) for part in
                     (sys.executable, str(Path(__file__).resolve()), "usb-proxy", "%p"))
    return ["-o", f"ProxyCommand={proxy}", "-o", f"HostKeyAlias={USB_HOST_ALIAS}"]


def tunnel_forwarding(local_port: int, remote_socket: str,
                      remote_port: int | None = None) -> str:
    if local_port < 1 or local_port > 65535:
        raise ValueError("a porta local deve estar entre 1 e 65535")
    if remote_port is not None:
        if remote_port < 1 or remote_port > 65535:
            raise ValueError("a porta remota deve estar entre 1 e 65535")
        return f"127.0.0.1:{local_port}:127.0.0.1:{remote_port}"
    if not remote_socket.startswith("/") or ":" in remote_socket:
        raise ValueError("o socket remoto deve ser um caminho absoluto sem dois-pontos")
    return f"127.0.0.1:{local_port}:{remote_socket}"


def webcam_ffmpeg_command(executable: str, webcam_url: str, pin: str,
                          device: Path) -> list[str]:
    return [executable, "-hide_banner", "-loglevel", "warning",
            "-fflags", "nobuffer+discardcorrupt", "-flags", "low_delay",
            "-thread_queue_size", "256",
            "-headers", f"X-Manual7-PIN: {pin}\r\n",
            "-use_wallclock_as_timestamps", "1",
            "-f", "mpjpeg", "-i", webcam_url,
            "-an", "-vf", "zscale=iw:ih:in_range=full:out_range=limited:filter=bilinear,format=yuv420p",
            "-color_range", "tv", "-fps_mode", "passthrough",
            "-f", "v4l2", str(device)]


def webcam_h264_ffmpeg_command(executable: str, device: Path) -> list[str]:
    """FFmpeg reading Annex-B H.264 on stdin. The iPhone already sends
    limited-range BT.709 4:2:0, so no range conversion is needed."""
    return [executable, "-hide_banner", "-loglevel", "warning",
            "-fflags", "nobuffer+discardcorrupt", "-flags", "low_delay",
            "-probesize", "262144", "-analyzeduration", "200000",
            "-use_wallclock_as_timestamps", "1",
            "-f", "h264", "-i", "pipe:0",
            "-an", "-pix_fmt", "yuv420p", "-color_range", "tv", "-fps_mode", "passthrough",
            "-f", "v4l2", str(device)]


def h264_url(webcam_url: str) -> str:
    return webcam_url[:-len(".mjpg")] + ".h264" if webcam_url.endswith(".mjpg") else webcam_url


def pump_h264(stream: Any, sink: Any) -> None:
    """Copies the Annex-B bodies of the multipart H.264 stream, starting at a
    keyframe, until either side closes."""
    waiting = True
    while True:
        line = stream.readline()
        if not line:
            return
        if not line.startswith(b"--"):
            continue
        headers: dict[str, str] = {}
        while True:
            line = stream.readline()
            if not line:
                return
            if line in (b"\r\n", b"\n"):
                break
            key, _, value = line.decode("latin-1").partition(":")
            headers[key.strip().lower()] = value.strip()
        length = int(headers.get("content-length", "0"))
        body = stream.read(length)
        if len(body) < length:
            return
        if waiting and headers.get("x-keyframe", "1") == "0":
            continue
        waiting = False
        sink.write(body)
        sink.flush()


def feed_h264(executable: str, webcam_url: str, pin: str, device: Path) -> int:
    process = subprocess.Popen(webcam_h264_ffmpeg_command(executable, device),
                               stdin=subprocess.PIPE)
    req = urllib.request.Request(h264_url(webcam_url), headers={"X-Manual7-PIN": pin})
    try:
        with urllib.request.urlopen(req, timeout=10) as response:
            pump_h264(response, process.stdin)
    except (BrokenPipeError, ConnectionResetError):
        pass
    finally:
        try:
            process.stdin.close()
        except OSError:
            pass
    return process.wait()


def wait_webcam(webcam_url: str, pin: str, timeout: float = 10) -> None:
    """Wait until the authenticated MJPEG endpoint has returned its headers."""
    deadline = time.monotonic() + timeout
    last_error: Exception | None = None
    while time.monotonic() < deadline:
        req = urllib.request.Request(webcam_url, headers={"X-Manual7-PIN": pin})
        try:
            with urllib.request.urlopen(req, timeout=min(2, timeout)):
                return
        except (OSError, urllib.error.URLError) as exc:
            last_error = exc
            time.sleep(.2)
    raise TimeoutError(f"endpoint MJPEG não ficou pronto: {last_error or 'timeout'}")


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
    webcam = sub.add_parser("webcam", help="Inicia ou para a saída MJPEG da webcam.")
    webcam.add_argument("action", choices=("start", "stop"))
    webcam.add_argument("--format", choices=("horizontal", "vertical"))
    feed = sub.add_parser("webcam-feed",
                          help="Alimenta um dispositivo v4l2loopback com a webcam M7.")
    feed.add_argument("--device", type=Path, default=Path("/dev/video10"))
    feed.add_argument("--format", choices=("horizontal", "vertical"), default="horizontal")
    feed.add_argument("--webcam-url",
                      default=os.environ.get("MANUAL7_WEBCAM_URL", DEFAULT_WEBCAM_URL))
    feed.add_argument("--ffmpeg", default="ffmpeg")
    feed.add_argument("--codec", choices=("auto", "h264", "mjpeg"), default="auto",
                      help="auto usa H.264 quando o M7 oferece /v1/webcam.h264, senão MJPEG.")
    feed.add_argument("--keep-enabled", action="store_true",
                      help="Mantém a saída M7 ativa quando o FFmpeg termina.")
    setting = sub.add_parser("set", help="Altera um controle do M7.")
    setting.add_argument("control")
    setting.add_argument("value")
    retry = sub.add_parser("retry", help="Repete uma gravação pendente no Fotos.")
    retry.add_argument("kind", choices=("photo", "videos"))
    sub.add_parser("close", help="Fecha o painel M7 após responder.")
    watch = sub.add_parser("watch", help="Atualiza o estado continuamente.")
    watch.add_argument("--interval", type=float, default=1.0)
    proxy = sub.add_parser("usb-proxy",
                           help="Ponte stdin/stdout para uma porta do iPhone pelo USB "
                                "(ProxyCommand do ssh).")
    proxy.add_argument("port", type=int)
    tunnel = sub.add_parser("tunnel", help="Abre o encaminhamento SSH para o iPhone.")
    tunnel.add_argument("host", nargs="?", help="IP ou nome do iPhone (dispensado com --usb).")
    tunnel.add_argument("--usb", action="store_true",
                        help="Conecta pelo cabo USB via usbmuxd em vez do Wi-Fi.")
    tunnel.add_argument("--user", default="mobile")
    tunnel.add_argument("--ssh-port", type=int,
                        help="Porta SSH explícita; sem esta opção, testa 22 e 2222.")
    tunnel.add_argument("--local-port", type=int, default=17837)
    tunnel.add_argument("--remote-socket", default=DEFAULT_REMOTE_SOCKET,
                        help="Socket Unix da API no iPhone.")
    tunnel.add_argument("--remote-port", type=int, default=DEFAULT_REMOTE_PORT,
                        help="Porta TCP loopback da API no bridge (padrão: 27839).")
    tunnel.add_argument("--webcam-local-port", type=int, default=17838)
    tunnel.add_argument("--webcam-remote-socket", default=DEFAULT_WEBCAM_SOCKET,
                        help="Socket Unix MJPEG no iPhone.")
    tunnel.add_argument("--webcam-remote-port", type=int, default=DEFAULT_WEBCAM_REMOTE_PORT,
                        help="Porta TCP loopback da webcam no bridge (padrão: 27840).")
    return parser


def main(argv: list[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    if args.subcommand == "usb-proxy":
        try:
            return usb_proxy(args.port)
        except OSError as exc:
            print(f"Manual7: {exc}", file=sys.stderr)
            return 1
    if args.subcommand == "tunnel":
        if not args.usb and not args.host:
            print("Manual7: informe o IP do iPhone ou use --usb.", file=sys.stderr)
            return 2
        try:
            if args.usb:
                ssh_port = args.ssh_port or 22
                usb_connect(ssh_port)[0].close()
            else:
                ssh_port = choose_ssh_port(args.host, args.ssh_port)
            forwarding = tunnel_forwarding(args.local_port, args.remote_socket, args.remote_port)
            webcam_forwarding = tunnel_forwarding(args.webcam_local_port,
                                                   args.webcam_remote_socket,
                                                   args.webcam_remote_port)
        except (OSError, ValueError) as exc:
            print(f"Manual7: {exc}", file=sys.stderr)
            return 1
        target = f"{args.user}@{USB_HOST_ALIAS if args.usb else args.host}"
        destination = f"127.0.0.1:{args.remote_port}" if args.remote_port else args.remote_socket
        print(f"API http://127.0.0.1:{args.local_port} → {target}:{destination}", file=sys.stderr)
        webcam_destination = f"127.0.0.1:{args.webcam_remote_port}"
        print(f"Webcam http://127.0.0.1:{args.webcam_local_port}/v1/webcam.mjpg "
              f"→ {target}:{webcam_destination} via SSH {ssh_port}"
              f"{' por USB' if args.usb else ''}", file=sys.stderr)
        return subprocess.call(["ssh", "-p", str(ssh_port), "-N",
                                *(usb_ssh_options() if args.usb else []),
                                "-L", forwarding, "-L", webcam_forwarding,
                                "-o", "ExitOnForwardFailure=yes",
                                "-o", "StrictHostKeyChecking=accept-new", target])
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
        elif args.subcommand == "webcam":
            if args.format and args.action == "start":
                command(args.url, args.pin, "webcam.stop")
                command(args.url, args.pin, "set", control="webcamFormat", value=args.format)
            result = command(args.url, args.pin, f"webcam.{args.action}")
        elif args.subcommand == "webcam-feed":
            executable = shutil.which(args.ffmpeg)
            if not executable:
                print(f"Manual7: FFmpeg não encontrado: {args.ffmpeg}", file=sys.stderr)
                return 2
            if not args.device.exists():
                print(f"Manual7: dispositivo v4l2loopback não existe: {args.device}", file=sys.stderr)
                return 2
            started = False
            try:
                codec = args.codec
                if codec == "auto":
                    state = request(args.url, args.pin, "GET", "/v1/state")
                    state = state.get("state", state)
                    available = state.get("webcam", {}).get("h264", {}).get("available") is True
                    codec = "h264" if available else "mjpeg"
                command(args.url, args.pin, "webcam.stop")
                command(args.url, args.pin, "set", control="webcamFormat", value=args.format)
                command(args.url, args.pin, "webcam.start")
                started = True
                webcam_url = h264_url(args.webcam_url) if codec == "h264" else args.webcam_url
                wait_webcam(webcam_url, args.pin)
                print(f"Manual7 {args.format} {codec.upper()} → {args.device}; Ctrl+C encerra.",
                      file=sys.stderr)
                if codec == "h264":
                    return feed_h264(executable, args.webcam_url, args.pin, args.device)
                return subprocess.call(webcam_ffmpeg_command(executable, args.webcam_url,
                                                             args.pin, args.device))
            finally:
                if started and not args.keep_enabled:
                    try:
                        command(args.url, args.pin, "webcam.stop")
                    except Exception as exc:  # The SSH tunnel may already be closed.
                        print(f"Manual7: não foi possível desligar a webcam: {exc}", file=sys.stderr)
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
