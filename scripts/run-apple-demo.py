#!/usr/bin/env python3
"""Build and launch the three Edge-Care apps on explicitly selected Apple simulators."""
import argparse
import datetime
import json
import os
from pathlib import Path
import platform
import shutil
import signal
import subprocess
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

ROOT = Path(__file__).resolve().parents[1]
TARGETS = (
    ("kiosk", "EdgeCareKiosk", "org.edgecare.demo.kiosk", "iPad Air (5th generation)"),
    ("doctor", "EdgeCareDoctor", "org.edgecare.demo.doctor", "iPhone 15 Pro Max"),
    ("patient", "EdgeCarePatient", "org.edgecare.demo.patient", "iPhone 13 Pro"),
)


def version_tuple(value):
    return tuple(int(part) for part in value.split("."))


def select_runtime(runtimes, requested, allow_compatible=False):
    available = [item for item in runtimes if item.get("isAvailable", False)
                 and (".iOS-" in item["identifier"] or item.get("name", "").startswith("iOS "))]
    if requested == "latest":
        if not available:
            raise ValueError("No available iOS Simulator runtime is installed.")
        return max(available, key=lambda item: version_tuple(item["version"]))
    for item in available:
        if version_tuple(item["version"]) == version_tuple(requested):
            return item
    if allow_compatible:
        candidates = [item for item in available if version_tuple(item["version"])[:2] == version_tuple(requested)[:2]]
        if candidates:
            return max(candidates, key=lambda item: version_tuple(item["version"]))
    versions = ", ".join(sorted({item["version"] for item in available})) or "none"
    raise ValueError("Requested iOS {} runtime is not installed. Available: {}. Install a runtime in "
                     "Xcode Settings > Components/Platforms, or explicitly pass --runtime VERSION. "
                     "--allow-compatible-runtime permits only a runtime from the same major/minor release."
                     .format(requested, versions))


def select_device(device_types, name):
    for item in device_types:
        if item["name"] == name or item["identifier"] == name:
            return item
    raise ValueError("Device type '{}' is unavailable in this Xcode. Run --list and explicitly select "
                     "a replacement with --kiosk-device / --doctor-device / --patient-device.".format(name))


def run(command, **kwargs):
    print("→ " + " ".join(str(item) for item in command), flush=True)
    return subprocess.run([str(item) for item in command], cwd=ROOT, check=True, **kwargs)


def json_command(command):
    return json.loads(subprocess.check_output(command, cwd=ROOT, text=True))


def health(base_url):
    try:
        with urllib.request.urlopen(base_url.rstrip("/") + "/health", timeout=2) as response:
            body = json.load(response)
            return response.status == 200 and body.get("demo_mode") is True
    except (OSError, ValueError, urllib.error.URLError):
        return False


def parse_args(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--list", action="store_true", help="List installed runtimes/device types; change nothing")
    parser.add_argument("--runtime", default="27.2.1", help="Exact runtime version; 'latest' explicitly opts into newest installed")
    parser.add_argument("--allow-compatible-runtime", action="store_true")
    parser.add_argument("--mode", choices=["local", "connected"], default="connected",
                        help="local is network-free per device; connected shares this Mac's demo backend")
    parser.add_argument("--base-url", default="http://127.0.0.1:3000")
    parser.add_argument("--no-backend", action="store_true", help="Use an already-running backend")
    parser.add_argument("--skip-tests", action="store_true", help="Explicitly skip Swift package tests")
    parser.add_argument("--skip-install", action="store_true", help="Skip pnpm dependency installation")
    parser.add_argument("--dry-run", action="store_true", help="Validate simulator selection and print plan without mutation")
    for role, _, _, name in TARGETS:
        parser.add_argument("--{}-device".format(role), default=name)
    return parser.parse_args(argv)


def main(argv=None):
    args = parse_args(argv)
    if platform.system() != "Darwin":
        raise ValueError("This launcher needs your Mac. Xcode and iOS Simulator cannot run on this Linux host.")
    for executable in ["xcodebuild", "xcrun", "swift"]:
        if not shutil.which(executable):
            raise ValueError("Missing {}. Install/open full Xcode and select its developer directory.".format(executable))
    inventory = json_command(["xcrun", "simctl", "list", "--json"])
    if args.list:
        print(json.dumps({"runtimes": [{"name": item["name"], "version": item["version"], "available": item.get("isAvailable", False)}
                                      for item in inventory["runtimes"]],
                          "device_types": [item["name"] for item in inventory["devicetypes"]]}, indent=2))
        return 0
    runtime = select_runtime(inventory["runtimes"], args.runtime, args.allow_compatible_runtime)
    planned = []
    for role, scheme, bundle, _ in TARGETS:
        device = select_device(inventory["devicetypes"], getattr(args, role + "_device"))
        planned.append({"role": role, "scheme": scheme, "bundle": bundle, "device": device})
    print("Requested runtime: {}. Selected installed runtime: {} ({}).".format(args.runtime, runtime["version"], runtime["name"]))
    print("The M1 iPad Air is the 10.9-inch fifth-generation model; a Simulator does not emulate M1 hardware performance.")
    print("Mode: {}. {}".format(args.mode, "Each app has its own local store and makes no network calls." if args.mode == "local"
                               else "All three apps share the explicitly configured local demo backend."))
    for item in planned:
        print("  {}: {} → {}".format(item["role"], item["device"]["name"], item["scheme"]))
    if args.dry_run:
        return 0
    for executable in ["xcodegen"] + (["node", "pnpm"] if args.mode == "connected" else []):
        if not shutil.which(executable):
            raise ValueError("Missing {}. See docs/apple-demo.md for prerequisites.".format(executable))
    run(["xcodebuild", "-version"])
    run(["xcodegen", "generate", "--spec", "project.yml"])
    if not args.skip_tests:
        run(["swift", "test", "--package-path", "packages/edgecare-core"])
    stamp = datetime.datetime.now(datetime.timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    output = ROOT / "artifacts" / "apple-demo" / stamp
    output.mkdir(parents=True)
    backend = None
    backend_log = None
    try:
        if args.mode == "connected" and not health(args.base_url):
            if args.no_backend:
                raise ValueError("Configured backend is not healthy. Start it first or omit --no-backend.")
            url = urllib.parse.urlparse(args.base_url)
            if url.hostname not in ["localhost", "127.0.0.1"] or url.scheme != "http" or url.path not in ["", "/"] or url.username:
                raise ValueError("Auto-start only supports http://localhost:PORT or http://127.0.0.1:PORT. Use --no-backend for another server.")
            if not args.skip_install:
                run(["pnpm", "install", "--frozen-lockfile"])
            environment = dict(os.environ, DEMO_MODE="true", CHAIN="mock", LLM="ondevice")
            backend_log = (output / "backend.log").open("w")
            backend = subprocess.Popen(["pnpm", "--filter", "@edgecare/crm-web", "exec", "next", "dev", "--hostname", "127.0.0.1", "--port", str(url.port or 3000)],
                                       cwd=ROOT, env=environment, stdout=backend_log, stderr=subprocess.STDOUT, start_new_session=True)
            for _ in range(90):
                if backend.poll() is not None:
                    raise ValueError("Backend exited. Read {}".format(output / "backend.log"))
                if health(args.base_url):
                    break
                time.sleep(1)
            else:
                raise ValueError("Backend startup timed out. Read {}".format(output / "backend.log"))
        run(["open", "-a", "Xcode", ROOT / "EdgeCare.xcodeproj"])
        run(["open", "-a", "Simulator"])
        results = []
        for item in planned:
            name = "EdgeCare {} iOS {}".format(item["role"].title(), runtime["version"])
            existing = next((device for device in inventory["devices"].get(runtime["identifier"], [])
                             if device.get("isAvailable", False) and device["name"] == name
                             and device.get("deviceTypeIdentifier") == item["device"]["identifier"]), None)
            udid = existing["udid"] if existing else subprocess.check_output(
                ["xcrun", "simctl", "create", name, item["device"]["identifier"], runtime["identifier"]], cwd=ROOT, text=True).strip()
            if not existing or existing.get("state") != "Booted":
                run(["xcrun", "simctl", "boot", udid])
            run(["xcrun", "simctl", "bootstatus", udid, "-b"])
            derived = output / "DerivedData" / item["scheme"]
            with (output / (item["role"] + "-build.log")).open("w") as logfile:
                print("Building {} (log: {})".format(item["scheme"], logfile.name), flush=True)
                run(["xcodebuild", "-project", "EdgeCare.xcodeproj", "-scheme", item["scheme"], "-configuration", "Debug",
                     "-sdk", "iphonesimulator", "-destination", "id=" + udid, "-derivedDataPath", derived,
                     "CODE_SIGNING_ALLOWED=NO", "build"], stdout=logfile, stderr=subprocess.STDOUT)
            app = derived / "Build" / "Products" / "Debug-iphonesimulator" / (item["scheme"] + ".app")
            if not app.is_dir():
                raise ValueError("Built app is missing: {}".format(app))
            run(["xcrun", "simctl", "install", udid, app])
            environment = dict(os.environ, SIMCTL_CHILD_EDGECARE_MODE=args.mode, SIMCTL_CHILD_EDGECARE_BASE_URL=args.base_url)
            for key in ["EDGECARE_ISSUER_TOKEN", "EDGECARE_CLINICIAN_TOKEN"]:
                if os.environ.get(key):
                    environment["SIMCTL_CHILD_" + key] = os.environ[key]
            run(["xcrun", "simctl", "launch", "--terminate-running-process", udid, item["bundle"]], env=environment)
            run(["open", "-a", "Simulator", "--args", "-CurrentDeviceUDID", udid])
            results.append({"role": item["role"], "device_type": item["device"]["name"], "udid": udid, "runtime": runtime["version"], "bundle_id": item["bundle"], "build_and_launch": "succeeded"})
            (output / "launch-report.json").write_text(json.dumps({"requested_runtime": args.runtime, "simulators": results}, indent=2) + "\n")
        if args.mode == "connected":
            run(["open", args.base_url])
        print("All three apps launched. Report: {}".format(output / "launch-report.json"))
        print("Simulator launch is not proof of camera, speech, biometric accuracy, or real-device performance. Follow docs/apple-demo.md.")
        if backend:
            print("The local backend remains active in this terminal. Press Ctrl+C to stop only this launcher's backend; simulators remain open.", flush=True)
            while backend.poll() is None:
                time.sleep(1)
            if backend.returncode:
                raise ValueError("The demo backend exited unexpectedly. See backend.log.")
        return 0
    except KeyboardInterrupt:
        print("Stopping the owned backend. Simulator apps and device data are preserved.")
        return 0
    finally:
        if backend and backend.poll() is None:
            os.killpg(backend.pid, signal.SIGTERM)
            try:
                backend.wait(timeout=10)
            except subprocess.TimeoutExpired:
                os.killpg(backend.pid, signal.SIGKILL)
        if backend_log:
            backend_log.close()


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (ValueError, subprocess.CalledProcessError, OSError) as error:
        print("Edge-Care launcher: {}".format(error), file=sys.stderr)
        sys.exit(1)
