import contextlib
import io
import os
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).parents[1]))
import voice_setup


class VoiceSetupTests(unittest.TestCase):
    def test_missing_credentials_leave_existing_file_untouched(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            path = root / "apps/crm-web/.env.local"
            path.parent.mkdir(parents=True)
            path.write_text("# preserved\n")
            with patch.object(voice_setup, "load_settings", return_value={}), contextlib.redirect_stdout(io.StringIO()):
                with self.assertRaisesRegex(ValueError, "GEMINI_API_KEY.*ELEVENLABS_VOICE_ID"):
                    voice_setup.configure(root, prompt=lambda _: "")
            self.assertEqual(path.read_text(), "# preserved\n")

    def test_keeps_configured_values_and_does_not_print_secrets(self):
        values = {key: "private-" + key for key in voice_setup.REQUIRED}
        with tempfile.TemporaryDirectory() as directory, patch.dict(os.environ, {"PATH": os.environ["PATH"]}, clear=True):
            root = Path(directory)
            captured = io.StringIO()
            with patch.object(voice_setup, "load_settings", return_value=values), contextlib.redirect_stdout(captured):
                voice_setup.configure(root, prompt=lambda _: "")
            path = root / "apps/crm-web/.env.local"
            self.assertEqual(path.stat().st_mode & 0o777, 0o600)
            for key, value in values.items():
                self.assertIn(value, path.read_text())
                self.assertEqual(os.environ[key], value)
                self.assertNotIn(value, captured.getvalue())
            self.assertEqual(os.environ["EDGECARE_CLOUD_VOICE"], "true")

    def test_next_parser_round_trip_preserves_unrelated_settings_and_literal_dollars(self):
        repo = Path(__file__).resolve().parents[2]
        with tempfile.TemporaryDirectory() as directory, patch.dict(os.environ, {"PATH": os.environ["PATH"]}, clear=True):
            root = Path(directory)
            (root / "node_modules").symlink_to(repo / "node_modules", target_is_directory=True)
            app = root / "apps/crm-web"
            app.mkdir(parents=True)
            (app / "node_modules").symlink_to(repo / "apps/crm-web/node_modules", target_is_directory=True)
            path = app / ".env.local"
            path.write_text('# existing comment\nEDGECARE_ISSUER_TOKEN="issuer-secret"\nGEMINI_MODEL=old\n')
            values = {key: "test-" + key for key in voice_setup.REQUIRED}
            values["ELEVENLABS_API_KEY"] = "literal-${GEMINI_MODEL}-$GEMINI_MODEL"
            voice_setup.write_settings(path, values)
            loaded = voice_setup.load_settings(root)
            for key, value in values.items():
                self.assertEqual(loaded[key], value)
            self.assertEqual(loaded["EDGECARE_ISSUER_TOKEN"], "issuer-secret")
            self.assertIn("# existing comment", path.read_text())
            with patch.dict(os.environ, {"GEMINI_MODEL": "shell-wins"}):
                self.assertEqual(voice_setup.load_settings(root)["GEMINI_MODEL"], "shell-wins")

    def test_simulator_receives_connection_and_device_tokens_but_no_provider_keys(self):
        inherited = {"GEMINI_API_KEY": "secret", "SIMCTL_CHILD_ELEVENLABS_API_KEY": "leaked",
                     "SIMCTL_CHILD_EDGECARE_MODE": "local", "PATH": "/bin"}
        with patch.dict(os.environ, inherited, clear=True):
            settings = {"EDGECARE_ISSUER_TOKEN": "issuer", "EDGECARE_CLINICIAN_TOKEN": "doctor"}
            env = voice_setup.simulator_environment("connected", "http://127.0.0.1:3001", settings)
            self.assertEqual(env["SIMCTL_CHILD_EDGECARE_MODE"], "connected")
            self.assertEqual(env["SIMCTL_CHILD_EDGECARE_BASE_URL"], "http://127.0.0.1:3001")
            self.assertEqual(env["SIMCTL_CHILD_EDGECARE_ISSUER_TOKEN"], "issuer")
            self.assertEqual(env["SIMCTL_CHILD_EDGECARE_CLINICIAN_TOKEN"], "doctor")
            self.assertNotIn("GEMINI_API_KEY", env)
            self.assertNotIn("SIMCTL_CHILD_ELEVENLABS_API_KEY", env)
            local = voice_setup.simulator_environment("local", "http://127.0.0.1:3000", settings)
            self.assertNotIn("SIMCTL_CHILD_EDGECARE_ISSUER_TOKEN", local)

    def test_invalid_values_do_not_replace_file(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / ".env.local"
            path.write_text("original")
            with self.assertRaises(ValueError):
                voice_setup.write_settings(path, {"GEMINI_API_KEY": "bad\nvalue"})
            self.assertEqual(path.read_text(), "original")


if __name__ == "__main__":
    unittest.main()
