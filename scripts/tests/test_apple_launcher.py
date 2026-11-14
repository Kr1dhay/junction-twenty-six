import importlib.util
from pathlib import Path
import unittest
import sys
from unittest.mock import patch
import contextlib
import io

sys.path.insert(0, str(Path(__file__).parents[1]))

spec = importlib.util.spec_from_file_location("launcher", Path(__file__).parents[1] / "run-apple-demo.py")
launcher = importlib.util.module_from_spec(spec)
spec.loader.exec_module(launcher)

class RuntimeSelectionTests(unittest.TestCase):
    def setUp(self):
        self.runtimes = [{"identifier": "com.apple.CoreSimulator.SimRuntime.iOS-27-2", "version": "27.2", "name": "iOS 27.2", "isAvailable": True},
                         {"identifier": "com.apple.CoreSimulator.SimRuntime.iOS-27-2-1", "version": "27.2.1", "name": "iOS 27.2.1", "isAvailable": False},
                         {"identifier": "com.apple.CoreSimulator.SimRuntime.iOS-26-1", "version": "26.1", "name": "iOS 26.1", "isAvailable": True}]
    def test_exact_missing_runtime_does_not_silently_fallback(self):
        with self.assertRaisesRegex(ValueError, "27.2.1 runtime is not installed"):
            launcher.select_runtime(self.runtimes, "27.2.1")
    def test_explicit_compatible_selection_is_same_major_minor(self):
        self.assertEqual(launcher.select_runtime(self.runtimes, "27.2.1", True)["version"], "27.2")
        with self.assertRaises(ValueError):
            launcher.select_runtime(self.runtimes, "27.3.1", True)
    def test_explicit_latest_selection_ignores_unavailable_runtime(self):
        self.assertEqual(launcher.select_runtime(self.runtimes, "latest")["version"], "27.2")
    def test_device_match_is_exact(self):
        devices = [{"name": "iPad Air (5th generation)", "identifier": "air5"}]
        self.assertEqual(launcher.select_device(devices, "iPad Air (5th generation)")["identifier"], "air5")
        with self.assertRaises(ValueError):
            launcher.select_device(devices, "iPad Air 11-inch (M2)")

    def test_voice_setup_rejects_offline_or_external_backend(self):
        for args in [["--mode", "local"], ["--no-backend"], ["--base-url", "https://example.com"]]:
            with self.assertRaisesRegex(ValueError, "requires connected mode"):
                launcher.main(["--configure-voice"] + args)

    def test_voice_setup_will_not_reuse_running_backend_or_write_credentials(self):
        inventory = {"runtimes": [dict(self.runtimes[1], isAvailable=True)],
                     "devicetypes": [{"name": name, "identifier": role} for role, _, _, name in launcher.TARGETS]}
        with patch.object(launcher.platform, "system", return_value="Darwin"), \
                patch.object(launcher.shutil, "which", return_value="/tool"), \
                patch.object(launcher, "json_command", return_value=inventory), \
                patch.object(launcher, "health", return_value=True), \
                patch.object(launcher, "configure") as configure, \
                patch.object(launcher, "run") as run, contextlib.redirect_stdout(io.StringIO()):
            with self.assertRaisesRegex(ValueError, "already running"):
                launcher.main(["--configure-voice"])
            configure.assert_not_called()
            run.assert_not_called()

if __name__ == "__main__":
    unittest.main()
