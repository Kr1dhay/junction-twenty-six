"""Private local voice configuration; provider credentials never enter simulator env."""
import getpass
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile

REQUIRED = ("GEMINI_API_KEY", "GEMINI_MODEL", "ELEVENLABS_API_KEY", "ELEVENLABS_VOICE_ID")
DEVICE_KEYS = ("EDGECARE_ISSUER_TOKEN", "EDGECARE_CLINICIAN_TOKEN")
RUNWARE_REQUIRED = ("RUNWARE_API_KEY", "RUNWARE_MODEL", "ELEVENLABS_API_KEY", "ELEVENLABS_VOICE_ID")
KEYS = REQUIRED + RUNWARE_REQUIRED + DEVICE_KEYS + ("EDGECARE_CLOUD_VOICE", "VOICE_LLM_PROVIDER")


def load_settings(root):
    # Use Next's own dotenv parser, expansion and dev-file precedence. Capture output
    # privately: it contains credentials and must never be logged or printed.
    script = """
const path = require('node:path');
const app = path.join(process.argv[1], 'apps/crm-web');
const next = require.resolve('next', {paths: [app]});
const {loadEnvConfig} = require(require.resolve('@next/env', {paths: [next]}));
loadEnvConfig(app, true, {info() {}, error() {} });
const keys = JSON.parse(process.argv[2]);
process.stdout.write(JSON.stringify(Object.fromEntries(keys.map(k => [k, process.env[k] || '']))));
"""
    result = subprocess.run(["node", "-e", script, str(root), json.dumps(KEYS)],
                            capture_output=True, text=True, check=False)
    if result.returncode:
        raise ValueError("Cannot read Next.js environment. Run pnpm install --frozen-lockfile first.")
    return json.loads(result.stdout)


def write_settings(path, values):
    # Preserve comments and unrelated settings. dotenv uses the last assignment.
    lines = []
    for key, value in values.items():
        if any(char in value for char in "\n\r\\\"'"):
            raise ValueError("{} must be a single-line value without quotes or backslashes.".format(key))
        lines.append('{}="{}"'.format(key, value.replace('$', '\\$')))
    previous = path.read_text() if path.exists() else ""
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, temporary = tempfile.mkstemp(prefix=".env.voice-", dir=path.parent)
    try:
        with os.fdopen(fd, "w") as output:
            output.write(previous.rstrip() + "\n\n# Local connected voice setup\n" + "\n".join(lines) + "\n")
        os.replace(temporary, path)  # mkstemp creates the replacement with mode 0600.
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


def configure(root, prompt=None):
    if prompt is None:
        if not sys.stdin.isatty():
            raise ValueError("Run pnpm ios:voice in an interactive terminal for private credential input.")
        prompt = getpass.getpass
    current = load_settings(root)
    values = {}
    print("Configure this Mac's backend. Input is hidden; Enter keeps an existing value.")
    required = RUNWARE_REQUIRED if current.get("VOICE_LLM_PROVIDER") == "runware" else REQUIRED
    for key in required:
        value = prompt(key + (" [configured]: " if current.get(key) else " [required]: ")).strip()
        values[key] = value or current.get(key, "")
    missing = [key for key in required if not values[key]]
    if missing:
        raise ValueError("Voice configuration incomplete; no file written. Missing: " + ", ".join(missing))
    values.update(EDGECARE_CLOUD_VOICE="true", DEMO_MODE="true", CHAIN="mock", LLM="ondevice")
    write_settings(Path(root) / "apps/crm-web/.env.local", values)
    # Explicitly selected values win over stale shell variables for this launch.
    os.environ.update(values)
    print("Saved server settings to ignored apps/crm-web/.env.local (0600). "
          "Configuration is complete; provider permissions and live speech are not yet verified.")
    return load_settings(root)


def simulator_environment(mode, base_url, settings):
    # Do not forward provider keys or inherited SIMCTL_CHILD_* secrets to apps.
    environment = {key: value for key, value in os.environ.items()
                   if not key.startswith("SIMCTL_CHILD_") and key not in REQUIRED + RUNWARE_REQUIRED}
    environment.update(SIMCTL_CHILD_EDGECARE_MODE=mode, SIMCTL_CHILD_EDGECARE_BASE_URL=base_url)
    if mode == "connected":
        for key in DEVICE_KEYS:
            if settings.get(key):
                environment["SIMCTL_CHILD_" + key] = settings[key]
    return environment
