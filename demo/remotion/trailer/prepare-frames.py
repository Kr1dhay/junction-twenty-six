"""Extract deterministic 30 fps JPEG sequences from the committed source clips."""
import json
import pathlib
import shutil
import subprocess

root = pathlib.Path(__file__).resolve().parent
manifest = json.loads((root / "frames.json").read_text())
if not shutil.which("ffmpeg"):
    raise SystemExit("Install ffmpeg before preparing trailer frames.")

for name, expected in manifest.items():
    source = root / "public" / f"{name}.mp4"
    output = root / "public" / "frames" / name
    output.mkdir(parents=True, exist_ok=True)
    for frame in output.glob("*.jpg"):
        frame.unlink()
    subprocess.run([
        "ffmpeg", "-v", "error", "-y", "-i", str(source),
        "-vf", "fps=30", "-q:v", "3", "-pix_fmt", "yuvj420p",
        "-threads", "2", str(output / "%05d.jpg"),
    ], check=True)
    actual = len(list(output.glob("*.jpg")))
    if actual != expected:
        raise SystemExit(f"{name}: expected {expected} frames, got {actual}")
    print(f"{name}: {actual} frames", flush=True)
