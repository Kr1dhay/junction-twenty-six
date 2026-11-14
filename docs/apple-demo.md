# Run Edge-Care on your Mac

This checkout was implemented on a Linux host. The launcher performs the actual native checks on your Mac and opens Xcode plus three Simulator devices. It never reports a substitute OS/device as an exact match.

## Prerequisites

Install full Xcode, open it once to accept its license and finish platform installation, and select its command-line tools in Xcode Settings. Install Node 22+, pnpm 9.15.9 (`corepack enable`) and XcodeGen (`brew install xcodegen`). Get this updated repository onto the Mac and run from its root.

```sh
python3 scripts/run-apple-demo.py --list
python3 scripts/run-apple-demo.py --dry-run
python3 scripts/run-apple-demo.py
```

The default request is runtime **27.2.1** with:

| Role | Simulator device | App |
| --- | --- | --- |
| Kiosk | iPad Air (5th generation) | EdgeCareKiosk |
| Doctor | iPhone 15 Pro Max | EdgeCareDoctor |
| Patient substitute | iPhone 13 Pro | EdgeCarePatient |

Apple identifies the M1 iPad Air as the fifth-generation **10.9-inch** model. The newer nominal 11-inch Air is a different hardware generation. We select the M1 model specified in the request. [Apple specifications](https://support.apple.com/en-us/111887).

Simulator runtime releases do not necessarily correspond to every physical-device patch version. If 27.2.1 is absent, the launcher stops and lists the installed versions. Explicitly choose one with `--runtime 27.2`, or use `--allow-compatible-runtime` to permit only the same major/minor release. `--runtime latest` explicitly chooses the newest installed iOS runtime. If Air5 is unavailable in the installed Xcode, choose a layout substitute explicitly with `--kiosk-device 'NAME FROM --list'`; that is not hardware verification of an M1 iPad. [Apple runtime installation](https://help.apple.com/xcode/mac/current/en.lproj/deva7379ae35.html).

## What the launcher does

1. Verifies exact requested runtime/device availability.
2. Generates `EdgeCare.xcodeproj` and runs shared Swift tests.
3. Starts the local synthetic demo backend if needed, then opens Xcode and Simulator.
4. Builds each app for its selected simulator, installs it and launches it in connected-demo mode against `http://127.0.0.1:3000`.
5. Writes build logs and a report of actual device/runtime combinations to `artifacts/apple-demo/TIMESTAMP/`.

If you configured issuer/clinician tokens in the server environment file, also export the same `EDGECARE_ISSUER_TOKEN` and `EDGECARE_CLINICIAN_TOKEN` values in the launcher shell so they are passed into the simulators. Provider keys remain server-only.

Keep its terminal running to serve the backend. Ctrl+C stops only the backend it owns; simulators and stored referral data remain. A backend already running at the supplied URL is reused and never stopped by the launcher. `--no-backend --base-url URL` requires a reachable existing backend.

`--mode local` runs each native app with networking disabled and independent device stores. Shared cross-device referral arrival requires connected mode; offline enrollment queues locally until connectivity returns. The browser CRM itself needs its local backend.

## Physical devices and demo walkthrough

In Xcode, select your Apple development team and each connected device, enable Developer Mode when prompted, then build the appropriate scheme. Physical devices cannot use the Mac's `127.0.0.1`; configure `EDGECARE_BASE_URL` with a reachable **HTTPS** endpoint whose certificate the device trusts, backed by the Mac's demo server. The native transport permits plain HTTP only on loopback; a physical device cannot use a plain LAN-IP HTTP URL. Use the configured issuer/clinician tokens for any non-loopback demo access. Do not expose this synthetic demo publicly.

Walk through the structured intake form, optional on-device OCR, guidance, signature and a four-digit code confirmed twice. Configure [connected voice](voice-intake.md) separately to test automatically detected speech, ElevenLabs replies and English profile updates. Note the referral ID, verify that the CRM receives it, open it in the doctor app, redraw the signature and enter the code, and confirm that CRM status changes to spent. A second attempt must fail. Repeat enrollment with networking disabled and restore it to test the durable queue. Repeat on the patient phone and open the encrypted wallet.

Camera capture, offline recognition for each chosen language, VoiceOver, Dynamic Type, and hardware performance require testing on the actual devices. Simulator launch alone does not validate them. No exact 27.2.1 device run has been performed by the Linux-hosted implementation agent.
