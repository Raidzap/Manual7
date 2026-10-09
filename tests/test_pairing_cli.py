import argparse
import http.client
import importlib.util
import json
import pathlib
import sys
import tempfile
import threading
import unittest
from unittest import mock


ROOT = pathlib.Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location("manual7_pair", ROOT / "tools" / "manual7_pair.py")
PAIR = importlib.util.module_from_spec(SPEC)
assert SPEC and SPEC.loader
sys.modules[SPEC.name] = PAIR
SPEC.loader.exec_module(PAIR)


class PairingCLITests(unittest.TestCase):
    def payload(self):
        return {
            "version": "0.7.4",
            "pin": "123456",
            "preferredSSHPort": 22,
            "availableSSHPorts": [22, 2222],
            "apiSocket": PAIR.API_SOCKET,
            "webcamSocket": PAIR.WEBCAM_SOCKET,
            "apiBridgePort": PAIR.API_BRIDGE_PORT,
            "webcamBridgePort": PAIR.WEBCAM_BRIDGE_PORT,
        }

    def test_uri_round_trip_has_custom_scheme_and_callback(self):
        uri = PAIR.build_pairing_uri(
            "http://192.168.1.4:43123/v1/pair", "A" * 43, "linux notebook"
        )
        self.assertTrue(uri.startswith("manual7://pair?"))
        from urllib.parse import parse_qs, urlsplit

        query = parse_qs(urlsplit(uri).query)
        self.assertEqual(query["callback"], ["http://192.168.1.4:43123/v1/pair"])
        self.assertEqual(query["token"], ["A" * 43])

    def test_listener_accepts_only_rfc1918_or_link_local_ipv4(self):
        self.assertEqual(PAIR.private_ipv4("192.168.1.20"), "192.168.1.20")
        self.assertEqual(PAIR.private_ipv4("172.31.2.3"), "172.31.2.3")
        self.assertEqual(PAIR.private_ipv4("169.254.10.9"), "169.254.10.9")
        for address in ("127.0.0.1", "8.8.8.8", "192.0.2.1", "::1"):
            with self.assertRaises(argparse.ArgumentTypeError):
                PAIR.private_ipv4(address)

    def test_result_validation_accepts_temporary_camera_container_sockets(self):
        payload = self.payload()
        directory = "/private/var/mobile/Containers/Data/Application/01234567-89AB-CDEF-0123-456789ABCDEF/tmp"
        payload["apiSocket"] = directory + "/m7a"
        payload["webcamSocket"] = directory + "/m7w"
        result = PAIR.validate_result(payload)
        self.assertEqual(result["apiSocket"], payload["apiSocket"])

    def test_result_validation_rejects_pin_port_and_unsafe_socket_changes(self):
        self.assertEqual(PAIR.validate_result(self.payload())["preferredSSHPort"], 22)
        for key, value in (
            ("pin", "123"),
            ("availableSSHPorts", []),
            ("apiSocket", "/tmp/other.sock"),
            ("apiSocket", "/etc/Manual7-api.sock"),
        ):
            changed = self.payload()
            changed[key] = value
            with self.assertRaises(PAIR.PairingError):
                PAIR.validate_result(changed)

    def test_callback_accepts_token_once_and_uses_peer_address(self):
        state = PAIR.PairingState(token="one-use-token")
        server = PAIR.http.server.HTTPServer(("127.0.0.1", 0), PAIR.handler_for(state))
        thread = threading.Thread(target=lambda: [server.handle_request() for _ in range(3)])
        thread.start()
        try:
            body = json.dumps(self.payload())
            connection = http.client.HTTPConnection("127.0.0.1", server.server_port)
            connection.request("POST", PAIR.PAIR_PATH, body,
                               {"X-Manual7-Pairing": "wrong", "Content-Type": "application/json"})
            self.assertEqual(connection.getresponse().status, 403)
            connection.close()

            connection = http.client.HTTPConnection("127.0.0.1", server.server_port)
            connection.request("POST", PAIR.PAIR_PATH, body,
                               {"X-Manual7-Pairing": state.token, "Content-Type": "application/json"})
            self.assertEqual(connection.getresponse().status, 200)
            connection.close()

            connection = http.client.HTTPConnection("127.0.0.1", server.server_port)
            connection.request("POST", PAIR.PAIR_PATH, body,
                               {"X-Manual7-Pairing": state.token, "Content-Type": "application/json"})
            self.assertEqual(connection.getresponse().status, 409)
            connection.close()
        finally:
            thread.join(2)
            server.server_close()
        self.assertEqual(state.peer_ip, "127.0.0.1")
        self.assertEqual(state.result["pin"], "123456")
        self.assertEqual(state.rejected, 2)

    def test_ssh_command_forwards_both_reported_sockets_without_shell(self):
        args = argparse.Namespace(ssh_port=None, local_port=17837,
                                  webcam_local_port=17838, user="mobile")
        payload = self.payload()
        directory = "/private/var/mobile/Containers/Data/Application/01234567-89AB-CDEF-0123-456789ABCDEF/tmp"
        payload["apiSocket"] = directory + "/m7a"
        payload["webcamSocket"] = directory + "/m7w"
        command = PAIR.ssh_command("192.168.1.50", payload, args)
        self.assertEqual(command[0], "ssh")
        self.assertIn("127.0.0.1:17837:127.0.0.1:27839", command)
        self.assertIn("127.0.0.1:17838:127.0.0.1:27840", command)
        self.assertIn("StrictHostKeyChecking=accept-new", command)
        self.assertEqual(command[-1], "mobile@192.168.1.50")

    def test_qrencode_arguments_do_not_use_a_shell(self):
        with tempfile.TemporaryDirectory() as directory, \
             mock.patch.object(PAIR.shutil, "which", return_value="/usr/bin/qrencode"), \
             mock.patch.object(PAIR.subprocess, "run") as run:
            output = pathlib.Path(directory) / "pair.png"
            PAIR.render_qr("manual7://pair?secret", output)
            self.assertEqual(run.call_count, 2)
            for call in run.call_args_list:
                arguments, keywords = call
                self.assertEqual(arguments[0][0], "/usr/bin/qrencode")
                self.assertNotIn("manual7://pair?secret", arguments[0])
                self.assertEqual(keywords["input"], "manual7://pair?secret")
                self.assertTrue(keywords["check"])
                self.assertNotIn("shell", keywords)


if __name__ == "__main__":
    unittest.main()
