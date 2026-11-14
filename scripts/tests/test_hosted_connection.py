import contextlib
import importlib.util
import io
import json
import os
from pathlib import Path
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location("connect_hosted", Path(__file__).parents[1] / "connect-hosted.py")
connector = importlib.util.module_from_spec(spec)
spec.loader.exec_module(connector)


class HostedConnectionTests(unittest.TestCase):
    def test_installed_app_launches_connected_without_putting_credentials_in_arguments(self):
        config = {"base_url": "https://edgecare.example", "EDGECARE_ISSUER_TOKEN": "private-issuer", "EDGECARE_CLINICIAN_TOKEN": "private-clinician"}
        inventory = {"devices": {"runtime-27.2.1": [{"udid": "device", "name": "iPad", "state": "Booted"}]}}
        calls = []

        def run(command, **kwargs):
            calls.append((command, kwargs))
            return SimpleNamespace(returncode=0 if command[-2] == "org.edgecare.demo.kiosk" or "launch" in command else 1)

        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "device.json"
            path.write_text(json.dumps(config))
            response = io.BytesIO(b'{"demo_mode":true}')
            response.status = 200
            with patch.object(connector.platform, "system", return_value="Darwin"), \
                    patch.object(connector.sys, "argv", ["connect-hosted.py", "--config", str(path)]), \
                    patch.object(connector.urllib.request, "urlopen", return_value=response), \
                    patch.object(connector.subprocess, "check_output", return_value=json.dumps(inventory)), \
                    patch.object(connector.subprocess, "run", side_effect=run), \
                    patch.dict(os.environ, {"SIMCTL_CHILD_GEMINI_API_KEY": "inherited-secret"}), \
                    contextlib.redirect_stdout(io.StringIO()):
                connector.main()
        launches = [(command, kwargs) for command, kwargs in calls if "launch" in command]
        self.assertEqual(len(launches), 1)
        command, options = launches[0]
        self.assertNotIn("private-issuer", " ".join(command))
        self.assertEqual(options["env"]["SIMCTL_CHILD_EDGECARE_MODE"], "connected")
        self.assertEqual(options["env"]["SIMCTL_CHILD_EDGECARE_BASE_URL"], config["base_url"])
        self.assertEqual(options["env"]["SIMCTL_CHILD_EDGECARE_ISSUER_TOKEN"], config["EDGECARE_ISSUER_TOKEN"])
        self.assertNotIn("SIMCTL_CHILD_GEMINI_API_KEY", options["env"])


if __name__ == "__main__":
    unittest.main()
