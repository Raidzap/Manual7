import shutil
import socket
import subprocess
import tempfile
import time
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]


def unused_port() -> int:
    listener = socket.socket()
    listener.bind(("127.0.0.1", 0))
    port = listener.getsockname()[1]
    listener.close()
    return port


class LaunchdBridgeTests(unittest.TestCase):
    def build_and_start(self, temporary: Path):
        compiler = shutil.which("cc")
        if not compiler:
            self.skipTest("cc is required")
        executable = temporary / "manual7bridge"
        subprocess.run([
            compiler, "-std=c11", "-Wall", "-Wextra", "-Werror", "-pthread",
            str(ROOT / "Bridge/manual7bridge.c"), "-o", str(executable),
        ], check=True)
        api_path = temporary / "api.sock"
        webcam_path = temporary / "webcam.sock"
        api_port = unused_port()
        webcam_port = unused_port()
        while webcam_port == api_port:
            webcam_port = unused_port()
        api_public_port = unused_port()
        webcam_public_port = unused_port()
        while len({api_port, webcam_port, api_public_port, webcam_public_port}) != 4:
            api_public_port = unused_port()
            webcam_public_port = unused_port()
        process = subprocess.Popen([
            str(executable), str(api_path), str(webcam_path),
            str(api_port), str(webcam_port), str(api_public_port), str(webcam_public_port),
        ], stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, text=True)
        deadline = time.monotonic() + 3
        while time.monotonic() < deadline and not api_path.exists():
            time.sleep(.02)
        self.assertTrue(api_path.exists(), process.stderr.read() if process.poll() else "")
        return process, api_path, api_port, api_public_port

    def test_authenticated_camera_worker_is_proxied_to_unix_client(self):
        with tempfile.TemporaryDirectory() as directory:
            temporary = Path(directory)
            process, api_path, api_port, _ = self.build_and_start(temporary)
            try:
                worker = socket.create_connection(("127.0.0.1", api_port), timeout=2)
                worker.sendall(b"M7-CAMERA-API-1\n")
                public = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
                public.settimeout(2)
                public.connect(str(api_path))

                request = b"GET /v1/ping HTTP/1.1\r\n\r\n"
                public.sendall(request)
                self.assertEqual(worker.recv(19), b"M7-BRIDGE-CLIENT-1\n")
                self.assertEqual(worker.recv(len(request)), request)
                response = b"HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\n{}"
                worker.sendall(response)
                self.assertEqual(public.recv(len(response)), response)
                public.close()
                worker.close()
            finally:
                process.terminate()
                process.wait(timeout=3)
                if process.stderr:
                    process.stderr.close()

    def test_closed_worker_is_pruned_before_pairing_public_client(self):
        with tempfile.TemporaryDirectory() as directory:
            process, api_path, api_port, _ = self.build_and_start(Path(directory))
            try:
                stale = socket.create_connection(("127.0.0.1", api_port), timeout=2)
                stale.sendall(b"M7-CAMERA-API-1\n")
                stale.close()
                time.sleep(.05)

                live = socket.create_connection(("127.0.0.1", api_port), timeout=2)
                live.settimeout(2)
                live.sendall(b"M7-CAMERA-API-1\n")
                public = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
                public.settimeout(2)
                public.connect(str(api_path))
                request = b"GET /v1/ping HTTP/1.1\r\n\r\n"
                public.sendall(request)
                self.assertEqual(live.recv(19), b"M7-BRIDGE-CLIENT-1\n")
                self.assertEqual(live.recv(len(request)), request)
                public.close()
                live.close()
            finally:
                process.terminate()
                process.wait(timeout=3)
                if process.stderr:
                    process.stderr.close()

    def test_loopback_tcp_public_endpoint_is_proxied(self):
        with tempfile.TemporaryDirectory() as directory:
            process, _, api_port, api_public_port = self.build_and_start(Path(directory))
            try:
                worker = socket.create_connection(("127.0.0.1", api_port), timeout=2)
                worker.settimeout(2)
                worker.sendall(b"M7-CAMERA-API-1\n")
                public = socket.create_connection(("127.0.0.1", api_public_port), timeout=2)
                public.settimeout(2)
                request = b"GET /v1/ping HTTP/1.1\r\n\r\n"
                public.sendall(request)
                self.assertEqual(worker.recv(19), b"M7-BRIDGE-CLIENT-1\n")
                self.assertEqual(worker.recv(len(request)), request)
                public.close()
                worker.close()
            finally:
                process.terminate()
                process.wait(timeout=3)
                if process.stderr:
                    process.stderr.close()


if __name__ == "__main__":
    unittest.main()
