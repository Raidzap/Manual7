import importlib.util
import io
import json
import os
import pathlib
import plistlib
import socket
import struct
import tempfile
import threading
import unittest
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from unittest import mock


ROOT = pathlib.Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location("manual7_remote", ROOT / "tools" / "manual7_remote.py")
REMOTE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(REMOTE)


class Handler(BaseHTTPRequestHandler):
    seen_pin = None

    def do_GET(self):
        Handler.seen_pin = self.headers.get("X-Manual7-PIN")
        if self.path == "/v1/fail":
            self.send_response(409)
            payload = {"ok": False, "error": "ocupado"}
        else:
            self.send_response(200)
            payload = {"ok": True, "path": self.path}
        data = json.dumps(payload).encode()
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def log_message(self, *_args):
        pass


class RemoteCLITests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        cls.thread = threading.Thread(target=cls.server.serve_forever, daemon=True)
        cls.thread.start()
        cls.url = f"http://127.0.0.1:{cls.server.server_port}"

    @classmethod
    def tearDownClass(cls):
        cls.server.shutdown()
        cls.server.server_close()

    def test_parse_remote_values(self):
        self.assertIs(REMOTE.parse_value("true"), True)
        self.assertEqual(REMOTE.parse_value("1760"), 1760)
        self.assertAlmostEqual(REMOTE.parse_value("0.25"), .25)
        self.assertEqual(REMOTE.parse_value("manual"), "manual")

    def test_request_sends_pin_and_decodes_json(self):
        result = REMOTE.request(self.url, "654321", "GET", "/v1/state")
        self.assertTrue(result["ok"])
        self.assertEqual(Handler.seen_pin, "654321")

    def test_http_error_keeps_remote_message(self):
        with self.assertRaises(REMOTE.RemoteError) as caught:
            REMOTE.request(self.url, "654321", "GET", "/v1/fail")
        self.assertEqual(caught.exception.status, 409)
        self.assertIn("ocupado", str(caught.exception))

    def test_ssh_port_uses_explicit_value(self):
        with mock.patch.object(REMOTE.socket, "create_connection") as connect:
            self.assertEqual(REMOTE.choose_ssh_port("iphone.local", 2222), 2222)
            connect.assert_not_called()

    def test_ssh_port_falls_back_to_procursus_2222(self):
        connection = mock.MagicMock()
        connection.__enter__.return_value = connection
        with mock.patch.object(REMOTE.socket, "create_connection",
                               side_effect=[OSError("closed"), connection]) as connect:
            self.assertEqual(REMOTE.choose_ssh_port("iphone.local", None), 2222)
            self.assertEqual([call.args[0][1] for call in connect.call_args_list], [22, 2222])

    def test_ssh_port_reports_both_failures(self):
        with mock.patch.object(REMOTE.socket, "create_connection",
                               side_effect=[OSError("closed"), OSError("closed")]):
            with self.assertRaises(OSError) as caught:
                REMOTE.choose_ssh_port("iphone.local", None)
        self.assertIn("22 ou 2222", str(caught.exception))

    def test_tunnel_forwards_local_tcp_to_remote_unix_socket(self):
        self.assertEqual(
            REMOTE.tunnel_forwarding(17837, "/var/tmp/Manual7-api.sock"),
            "127.0.0.1:17837:/var/tmp/Manual7-api.sock")

    def test_tunnel_keeps_legacy_tcp_option(self):
        self.assertEqual(
            REMOTE.tunnel_forwarding(27837, "/ignored.sock", 17837),
            "127.0.0.1:27837:127.0.0.1:17837")

    def test_tunnel_rejects_relative_socket(self):
        with self.assertRaises(ValueError):
            REMOTE.tunnel_forwarding(17837, "tmp/Manual7.sock")

    def test_wait_webcam_sends_pin(self):
        REMOTE.wait_webcam(self.url + "/v1/webcam.mjpg", "246810", timeout=1)
        self.assertEqual(Handler.seen_pin, "246810")

    def test_ffmpeg_feeds_v4l2loopback_with_authenticated_mjpeg(self):
        command = REMOTE.webcam_ffmpeg_command(
            "/usr/bin/ffmpeg", REMOTE.DEFAULT_WEBCAM_URL, "246810",
            pathlib.Path("/dev/video10"))
        self.assertEqual(command[0], "/usr/bin/ffmpeg")
        self.assertIn("X-Manual7-PIN: 246810\r\n", command)
        self.assertIn("mpjpeg", command)
        self.assertIn("zscale=iw:ih:in_range=full:out_range=limited:filter=bilinear,format=yuv420p", command)
        self.assertIn("-use_wallclock_as_timestamps", command)
        self.assertIn("passthrough", command)
        self.assertNotIn("10", command)
        self.assertEqual(command[-2:], ["v4l2", "/dev/video10"])

    def test_tunnel_opens_api_and_webcam_forwards(self):
        with mock.patch.object(REMOTE, "choose_ssh_port", return_value=22), \
             mock.patch.object(REMOTE.subprocess, "call", return_value=0) as call:
            self.assertEqual(REMOTE.main(["tunnel", "iphone.local"]), 0)
        argv = call.call_args.args[0]
        forwards = [argv[index + 1] for index, value in enumerate(argv) if value == "-L"]
        self.assertEqual(forwards, [
            "127.0.0.1:17837:127.0.0.1:27839",
            "127.0.0.1:17838:127.0.0.1:27840"])
        self.assertIn("StrictHostKeyChecking=accept-new", argv)

    def test_webcam_start_sets_format_then_starts(self):
        with mock.patch.object(REMOTE, "command",
                               side_effect=[{"ok": True}, {"ok": True}, {"ok": True}]) as command:
            self.assertEqual(REMOTE.main(["--pin", "246810", "webcam", "start",
                                          "--format", "vertical"]), 0)
        self.assertEqual(command.call_args_list[0].args[2], "webcam.stop")
        self.assertEqual(command.call_args_list[1].args[2], "set")
        self.assertEqual(command.call_args_list[1].kwargs["control"], "webcamFormat")
        self.assertEqual(command.call_args_list[2].args[2], "webcam.start")


def h264_part(body: bytes, keyframe: bool) -> bytes:
    return (b"--m7frame\r\nContent-Type: video/h264\r\nContent-Length: %d\r\nX-Keyframe: %d\r\n\r\n"
            % (len(body), int(keyframe))) + body + b"\r\n"


class FakeUsbmuxd:
    """Unix-socket usbmuxd that lists one USB iPhone and echoes after Connect."""

    def __init__(self, devices):
        self.directory = tempfile.TemporaryDirectory()
        self.path = os.path.join(self.directory.name, "usbmuxd")
        self.devices = devices
        self.requests = []
        self.server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.server.bind(self.path)
        self.server.listen(4)
        threading.Thread(target=self.serve, daemon=True).start()

    @staticmethod
    def reply(message):
        payload = plistlib.dumps(message)
        return struct.pack("<IIII", 16 + len(payload), 1, 8, 1) + payload

    def serve(self):
        while True:
            try:
                client, _ = self.server.accept()
            except OSError:
                return
            with client:
                header = client.recv(16)
                length = struct.unpack_from("<I", header)[0]
                payload = b""
                while len(payload) < length - 16:
                    payload += client.recv(65536)
                request = plistlib.loads(payload)
                self.requests.append(request)
                if request["MessageType"] == "ListDevices":
                    client.sendall(self.reply({"DeviceList": [
                        {"DeviceID": d["DeviceID"], "Properties": d} for d in self.devices]}))
                else:
                    client.sendall(self.reply({"MessageType": "Result", "Number": 0}) + b"SSH-2.0-x\r\n")
                    while data := client.recv(65536):
                        client.sendall(data)

    def close(self):
        self.server.close()
        self.directory.cleanup()


class USBAndH264Tests(unittest.TestCase):
    def test_usb_connect_reaches_the_only_usb_iphone(self):
        mux = FakeUsbmuxd([{"DeviceID": 4, "ConnectionType": "USB", "SerialNumber": "a"},
                           {"DeviceID": 5, "ConnectionType": "Network", "SerialNumber": "b"}])
        try:
            with mock.patch.dict(os.environ, {"USBMUXD_SOCKET_ADDRESS": f"UNIX:{mux.path}"}):
                sock, extra = REMOTE.usb_connect(22)
            with sock:
                sock.sendall(b"ping")
                echoed = extra
                while b"ping" not in echoed:
                    echoed += sock.recv(65536)
            self.assertEqual(echoed, b"SSH-2.0-x\r\nping")
            connect = mux.requests[-1]
            self.assertEqual(connect["DeviceID"], 4)
            self.assertEqual(connect["PortNumber"], 0x1600)
        finally:
            mux.close()

    def test_usb_connect_refuses_ambiguous_or_missing_device(self):
        mux = FakeUsbmuxd([])
        try:
            with mock.patch.dict(os.environ, {"USBMUXD_SOCKET_ADDRESS": f"UNIX:{mux.path}"}), \
                 self.assertRaisesRegex(OSError, "exatamente um iPhone"):
                REMOTE.usb_connect(22)
        finally:
            mux.close()
        with mock.patch.dict(os.environ, {"USBMUXD_SOCKET_ADDRESS": "UNIX:/nonexistent/usbmuxd"}), \
             self.assertRaisesRegex(OSError, "usbmuxd indisponível"):
            REMOTE.usb_connect(22)

    def test_tunnel_over_usb_uses_proxy_command_and_host_alias(self):
        fake = mock.Mock()
        with mock.patch.object(REMOTE, "usb_connect", return_value=(fake, b"")), \
             mock.patch.object(REMOTE.subprocess, "call", return_value=0) as call:
            self.assertEqual(REMOTE.main(["tunnel", "--usb"]), 0)
        argv = call.call_args.args[0]
        self.assertTrue(any(value.startswith("ProxyCommand=") and "usb-proxy %p" in value
                            for value in argv))
        self.assertIn("HostKeyAlias=manual7-usb", argv)
        self.assertEqual(argv[-1], "mobile@manual7-usb")
        self.assertEqual(argv[argv.index("-p") + 1], "22")

    def test_tunnel_without_host_or_usb_is_rejected(self):
        self.assertEqual(REMOTE.main(["tunnel"]), 2)

    def test_pump_h264_starts_at_keyframe_and_strips_multipart(self):
        stream = io.BytesIO(h264_part(b"P0", False) + h264_part(b"K1", True) + h264_part(b"P1", False))
        sink = io.BytesIO()
        REMOTE.pump_h264(stream, sink)
        self.assertEqual(sink.getvalue(), b"K1P1")

    def test_h264_ffmpeg_reads_stdin_without_range_filter(self):
        command = REMOTE.webcam_h264_ffmpeg_command("/usr/bin/ffmpeg", pathlib.Path("/dev/video10"))
        self.assertEqual(command[command.index("-f") + 1], "h264")
        self.assertIn("pipe:0", command)
        self.assertFalse(any("zscale" in value for value in command))
        self.assertEqual(command[-2:], ["v4l2", "/dev/video10"])
        self.assertEqual(REMOTE.h264_url(REMOTE.DEFAULT_WEBCAM_URL),
                         "http://127.0.0.1:17838/v1/webcam.h264")


if __name__ == "__main__":
    unittest.main()
