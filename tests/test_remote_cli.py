import importlib.util
import json
import pathlib
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
        self.assertEqual(command[-2:], ["v4l2", "/dev/video10"])

    def test_tunnel_opens_api_and_webcam_forwards(self):
        with mock.patch.object(REMOTE, "choose_ssh_port", return_value=22), \
             mock.patch.object(REMOTE.subprocess, "call", return_value=0) as call:
            self.assertEqual(REMOTE.main(["tunnel", "iphone.local"]), 0)
        argv = call.call_args.args[0]
        forwards = [argv[index + 1] for index, value in enumerate(argv) if value == "-L"]
        self.assertEqual(forwards, [
            "127.0.0.1:17837:/var/tmp/Manual7-api.sock",
            "127.0.0.1:17838:/var/tmp/Manual7-webcam.sock"])

    def test_webcam_start_sets_format_then_starts(self):
        with mock.patch.object(REMOTE, "command",
                               side_effect=[{"ok": True}, {"ok": True}, {"ok": True}]) as command:
            self.assertEqual(REMOTE.main(["--pin", "246810", "webcam", "start",
                                          "--format", "vertical"]), 0)
        self.assertEqual(command.call_args_list[0].args[2], "webcam.stop")
        self.assertEqual(command.call_args_list[1].args[2], "set")
        self.assertEqual(command.call_args_list[1].kwargs["control"], "webcamFormat")
        self.assertEqual(command.call_args_list[2].args[2], "webcam.start")


if __name__ == "__main__":
    unittest.main()
