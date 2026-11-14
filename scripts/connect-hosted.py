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


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--config", type=Path, required=True, help="Private device JSON supplied with the deployment")
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
