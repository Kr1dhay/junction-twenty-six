"""Run the real-model worker and an isolated local CRM for the hackathon.

Run with the prepared Python environment. No hosted service, existing .env,
device configuration, or existing referral database is changed.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import secrets
import signal
import socket
import subprocess
import sys
import time
from urllib.error import URLError
from urllib.request import Request, urlopen

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]


def wait_ready(url, process, headers=None):
    for _ in range(120):
        if process.poll() is not None:
            raise RuntimeError("Demo service exited; inspect artifacts/voice-demo logs")
        try:
            with urlopen(Request(url, headers=headers or {}), timeout=2) as response:
                if response.status == 200:
                    return json.load(response)
        except (OSError, URLError, ValueError):
            pass
        time.sleep(1)
    raise RuntimeError("Demo startup timed out")


def available_port(port):
    with socket.socket() as probe:
        probe.bind(("127.0.0.1", port))


def write_private(path, value):
    descriptor = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    os.fchmod(descriptor, 0o600)
    with os.fdopen(descriptor, "w") as output:
        json.dump(value, output, indent=2)
        output.write("\n")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--acknowledge-unlicensed-local-demo", action="store_true", required=True)
    parser.add_argument("--backend-port", type=int, default=3100)
    parser.add_argument("--worker-port", type=int, default=8091)
    parser.add_argument("--launch-simulator", help="Optional explicit simulator UDID; app must already be installed")
    parser.add_argument("--bundle-id", default="org.edgecare.demo.kiosk")
    args = parser.parse_args()
    if (not 1 <= args.backend_port <= 65535 or not 1 <= args.worker_port <= 65535
            or args.backend_port == args.worker_port):
        parser.error("Choose two distinct ports between 1 and 65535")
    for port in (args.backend_port, args.worker_port):
        available_port(port)  # Never reuse/terminate someone else's running server.
    artifact = HERE / "models/paterson-mfcc-lr.json"
    manifest_path = HERE / "models/manifest.json"
    if not artifact.exists() or not manifest_path.exists():
        parser.error("Run prepare_benchmark.py --acknowledge-unlicensed-local-demo first")
    manifest = json.loads(manifest_path.read_text())
    if hashlib.sha256(artifact.read_bytes()).hexdigest() != manifest["sha256"]:
        parser.error("Model does not match its preparation manifest")
    from core import DenseVoiceModel
    DenseVoiceModel.load(str(artifact), manifest["sha256"], allow_unlicensed_demo=True)
    logs = ROOT / "artifacts/voice-demo"
    logs.mkdir(parents=True, exist_ok=True)
    worker_token, issuer_token, clinician_token = (secrets.token_hex(32) for _ in range(3))
    worker_url = f"http://127.0.0.1:{args.worker_port}"
    backend_url = f"http://127.0.0.1:{args.backend_port}"
    environment = dict(os.environ,
        VOICE_RESEARCH_HACKATHON_DEMO="true", VOICE_RESEARCH_APPROVED="false",
        VOICE_RESEARCH_MODEL_PATH=str(artifact), VOICE_RESEARCH_MODEL_SHA256=manifest["sha256"],
        VOICE_RESEARCH_TOKEN=worker_token, VOICE_RESEARCH_URL=worker_url,
        VOICE_RESEARCH_MODEL_ID=manifest["model_id"], VOICE_RESEARCH_MODEL_VERSION=manifest["model_version"],
        EDGECARE_VOICE_RESEARCH="true", DEMO_MODE="true", CHAIN="mock", LLM="ondevice",
        EDGECARE_ISSUER_TOKEN=issuer_token, EDGECARE_CLINICIAN_TOKEN=clinician_token,
        EDGECARE_SESSION_SECRET=secrets.token_hex(32), EDGECARE_PUBLIC_ORIGIN="", VERCEL="",
        DATABASE_URL="", EDGECARE_DB_PATH=str(logs / "demo.sqlite"))
    processes = []
    with (logs / "worker.log").open("w") as worker_log, (logs / "backend.log").open("w") as backend_log:
        try:
            worker = subprocess.Popen([sys.executable, "-m", "uvicorn", "app:app", "--host", "127.0.0.1",
                "--port", str(args.worker_port), "--no-access-log"], cwd=HERE, env=environment,
                stdout=worker_log, stderr=subprocess.STDOUT, start_new_session=True)
            processes.append(worker)
            identity = wait_ready(worker_url + "/health", worker, {"Authorization": "Bearer " + worker_token})
            if identity["model_id"] != manifest["model_id"]:
                raise RuntimeError("Worker identity mismatch")
            # Match the installed SQLite ABI without replacing the user's Node.
            backend = subprocess.Popen(["npm", "exec", "--yes", "--package=node@22", "--", "node",
                str(ROOT / "apps/crm-web/node_modules/next/dist/bin/next"), "dev", "--hostname", "127.0.0.1",
                "--port", str(args.backend_port)], cwd=ROOT / "apps/crm-web", env=environment,
                stdout=backend_log, stderr=subprocess.STDOUT, start_new_session=True)
            processes.append(backend)
            wait_ready(backend_url + "/health", backend)
            availability = wait_ready(backend_url + "/demo/voice/research", backend,
                                      {"Authorization": "Bearer " + issuer_token})
            if not availability.get("available"):
                raise RuntimeError("Backend cannot reach the model")
            # Private tokens support app launch and smoke tests, never console output.
            write_private(logs / "connection.json", {"backend_url": backend_url, "worker_url": worker_url,
                "issuer_token": issuer_token, "clinician_token": clinician_token, "worker_token": worker_token})
            if args.launch_simulator:
                child_environment = {k: v for k, v in os.environ.items() if not k.startswith("SIMCTL_CHILD_")}
                child_environment.update(SIMCTL_CHILD_EDGECARE_MODE="connected",
                    SIMCTL_CHILD_EDGECARE_BASE_URL=backend_url,
                    SIMCTL_CHILD_EDGECARE_ISSUER_TOKEN=issuer_token,
                    SIMCTL_CHILD_EDGECARE_CLINICIAN_TOKEN=clinician_token)
                subprocess.run(["xcrun", "simctl", "launch", "--terminate-running-process",
                    args.launch_simulator, args.bundle_id], env=child_environment, check=True, capture_output=True)
            print(f"Real benchmark demo ready: {backend_url}", flush=True)
            print("Local conceptual demo only; no clinical validation or upstream licence granted.", flush=True)
            print("Private app connection: artifacts/voice-demo/connection.json. Ctrl+C stops owned services.", flush=True)
            while all(process.poll() is None for process in processes):
                time.sleep(1)
            raise RuntimeError("A demo service stopped; inspect artifacts/voice-demo logs")
        except KeyboardInterrupt:
            return 0
        finally:
            for process in reversed(processes):
                if process.poll() is None:
                    os.killpg(process.pid, signal.SIGTERM)
                    try:
                        process.wait(timeout=10)
                    except subprocess.TimeoutExpired:
                        os.killpg(process.pid, signal.SIGKILL)
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (OSError, RuntimeError) as error:
        print(f"Demo could not start: {error}", file=sys.stderr)
        raise SystemExit(1)
