#!/usr/bin/env python3
"""Relaunch installed Edge-Care simulator apps against a hosted backend."""
import argparse
import json
import os
from pathlib import Path
import platform
import subprocess
import sys
import urllib.parse
import urllib.request

ROOT = Path(__file__).resolve().parents[1]
SCHEMES = {"kiosk": "EdgeCareKiosk", "doctor": "EdgeCareDoctor", "patient": "EdgeCarePatient"}


def rebuild(role, device):
    scheme = SCHEMES[role]
    derived = ROOT / "artifacts" / "hosted-build" / scheme
    derived.mkdir(parents=True, exist_ok=True)
    log = derived / "build.log"
    print("Building {} for {} (log: {})".format(scheme, device["name"], log), flush=True)
    with log.open("w") as output:
        subprocess.run(["xcodebuild", "-project", "EdgeCare.xcodeproj", "-scheme", scheme,
                        "-configuration", "Debug", "-sdk", "iphonesimulator", "-destination", "id=" + device["udid"],
                        "-derivedDataPath", str(derived), "CODE_SIGNING_ALLOWED=NO", "build"],
                       cwd=ROOT, stdout=output, stderr=subprocess.STDOUT, check=True)
    app = derived / "Build" / "Products" / "Debug-iphonesimulator" / (scheme + ".app")
    if not app.is_dir():
        raise ValueError("Built app is missing: " + str(app))
    subprocess.run(["xcrun", "simctl", "install", device["udid"], str(app)], check=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--config", type=Path, required=True, help="Device JSON supplied with the deployment")
    parser.add_argument("--rebuild", action="store_true", help="Test, rebuild and reinstall apps before reconnecting")
    args = parser.parse_args()
    if platform.system() != "Darwin":
        raise ValueError("Run this command on the Mac with your booted simulators.")
    config = json.loads(args.config.read_text())
    origin = config["base_url"]
    url = urllib.parse.urlparse(origin)
    if url.scheme != "https" or not url.hostname or url.username or url.path not in ["", "/"] or url.query or url.fragment:
        raise ValueError("The device configuration must contain an HTTPS origin.")
    for key in ["EDGECARE_ISSUER_TOKEN", "EDGECARE_CLINICIAN_TOKEN"]:
        if not isinstance(config.get(key), str) or not config[key]:
            raise ValueError("Missing device credential: " + key)
    with urllib.request.urlopen(origin.rstrip("/") + "/health", timeout=30) as response:
        if response.status != 200 or json.load(response).get("demo_mode") is not True:
            raise ValueError("The configured backend is not healthy.")
    environment = {key: value for key, value in os.environ.items() if not key.startswith("SIMCTL_CHILD_")}
    environment.update(SIMCTL_CHILD_EDGECARE_MODE="connected", SIMCTL_CHILD_EDGECARE_BASE_URL=origin)
    for key in ["EDGECARE_ISSUER_TOKEN", "EDGECARE_CLINICIAN_TOKEN"]:
        environment["SIMCTL_CHILD_" + key] = config[key]
    inventory = json.loads(subprocess.check_output(["xcrun", "simctl", "list", "devices", "booted", "--json"], text=True))
    prepared = False
    count = 0
    for runtime, devices in inventory["devices"].items():
        for device in devices:
            if device.get("state") != "Booted":
                continue
            for role in ["kiosk", "doctor", "patient"]:
                bundle = "org.edgecare.demo." + role
                installed = subprocess.run(["xcrun", "simctl", "get_app_container", device["udid"], bundle, "app"], capture_output=True)
                if installed.returncode:
                    continue
                if args.rebuild:
                    if not prepared:
                        subprocess.run(["swift", "test", "--package-path", "packages/edgecare-core"], cwd=ROOT, check=True)
                        subprocess.run(["xcodegen", "generate", "--spec", "project.yml"], cwd=ROOT, check=True)
                        prepared = True
                    rebuild(role, device)
                subprocess.run(["xcrun", "simctl", "launch", "--terminate-running-process", device["udid"], bundle], env=environment, check=True)
                print("Connected {} on {} ({}) to {}".format(role, device["name"], runtime, origin))
                count += 1
    if not count:
        raise ValueError("No installed Edge-Care apps found on booted simulators. Open the existing simulators first.")
    print("Relaunched {} installed app(s). No local backend is needed. Xcode Run may reset scheme environment; rerun this command to reconnect.".format(count))


if __name__ == "__main__":
    try:
        main()
    except (ValueError, KeyError, OSError, subprocess.CalledProcessError) as error:
        print("Edge-Care connection: {}".format(error), file=sys.stderr)
        sys.exit(1)
