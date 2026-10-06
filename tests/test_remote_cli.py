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


if __name__ == "__main__":
    unittest.main()
