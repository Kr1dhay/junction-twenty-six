"""Bounded, research-only inference. No bundled weights, pickle loading, or audio storage."""
import base64
import hashlib
import io
import json
import math
import struct
import wave
from dataclasses import dataclass
from pathlib import Path

BENCHMARK_COMMIT = "7811f6d8cc8ac6dbe8535e9e2669febed4f51da4"
BENCHMARK_SHA256 = "c7278909c9961ec675bdacd63acd5c4862c49274b1ccd56b781387ed272d1853"
BENCHMARK_MODEL_ID = "paterson-mfcc-lr-hackathon-demo"


@dataclass(frozen=True)
class DenseVoiceModel:
    model_id: str
    version: str
    target_frames: int
    mean: tuple
    scale: tuple
    coefficients: tuple
    intercept: float
    selected_indices: tuple | None = None
    float32_pipeline: bool = False

    @classmethod
    def load(cls, path: str, expected_sha256: str, *, allow_unlicensed_demo=False):
        with Path(path).open("rb") as artifact:
            blob = artifact.read(4 * 1024 * 1024 + 1)
        if len(blob) > 4 * 1024 * 1024 or not isinstance(expected_sha256, str) or len(expected_sha256) != 64:
            raise ValueError("Invalid model artifact")
        if hashlib.sha256(blob).hexdigest() != expected_sha256:
            raise ValueError("Model checksum mismatch")
        item = json.loads(blob)
        if not isinstance(item, dict) or item.get("feature_extractor") != "librosa-mfcc-20-flatten-v1":
            raise ValueError("Unsupported preprocessing")
        local_demo = item.get("demo_only") is True
        if local_demo:
            source = item.get("source", {})
            if (not allow_unlicensed_demo or not isinstance(source, dict)
                    or source.get("commit") != BENCHMARK_COMMIT or source.get("sha256") != BENCHMARK_SHA256
                    or item.get("model_id") != BENCHMARK_MODEL_ID
                    or item.get("model_version") != BENCHMARK_COMMIT[:12]
                    or item.get("license_status") != "not_provided_by_upstream"):
                raise ValueError("Pinned local-demo acknowledgment is required")
        elif not isinstance(item.get("license_reference"), str) or not item["license_reference"].strip():
            raise ValueError("Model permission is required")
        if item.get("positive_class_meaning") != "research_flag":
            raise ValueError("Model provenance and label mapping are required")
        frames = item["target_frames"]
        if type(frames) is not int or not 1 <= frames <= 400:
            raise ValueError("Invalid feature dimensions")
        for name in ["model_id", "model_version"]:
            if not isinstance(item.get(name), str) or not 1 <= len(item[name]) <= 120:
                raise ValueError("Missing model identity")
        vectors = [tuple(item[key]) for key in ["mean", "scale", "coefficients"]]
        if any(len(v) != 20 * frames for v in vectors):
            raise ValueError("Invalid model dimensions")
        if not all(type(n) in (int, float) and math.isfinite(n) for v in vectors for n in v):
            raise ValueError("Non-finite model value")
        if any(n <= 0 for n in vectors[1]) or type(item["intercept"]) not in (int, float) or not math.isfinite(item["intercept"]):
            raise ValueError("Invalid scaling or intercept")
        float32_pipeline = item.get("arithmetic") == "sklearn-float32-selected-v1"
        indices = item.get("selected_indices")
        if float32_pipeline:
            if (not isinstance(indices, list) or not indices or
                    any(type(n) is not int or n < 0 or n >= 20 * frames for n in indices) or
                    indices != sorted(set(indices))):
                raise ValueError("Invalid selected features")
            if any(c != 0 for i, c in enumerate(vectors[2]) if i not in set(indices)):
                raise ValueError("Unexpected unselected coefficients")
        elif indices is not None or item.get("arithmetic") is not None:
            raise ValueError("Unsupported arithmetic")
        return cls(item["model_id"], item["model_version"], frames, *vectors, item["intercept"],
                   tuple(indices) if indices is not None else None, float32_pipeline)

    def predict(self, features):
        if len(features) != len(self.coefficients) or not all(math.isfinite(n) for n in features):
            raise ValueError("Invalid input features")
        if self.float32_pipeline:
            import numpy as np
            # sklearn's StandardScaler subtracts/divides in-place on float32
            # MFCCs, then the original classifier uses float32 selected features.
            values = np.asarray(features, dtype=np.float32).reshape(1, -1).copy()
            values -= np.asarray(self.mean)
            values /= np.asarray(self.scale)
            selected = values[:, self.selected_indices]
            weights = np.asarray(self.coefficients, dtype=np.float32)[list(self.selected_indices)]
            margin = float((selected @ weights + np.float32(self.intercept))[0])
        else:
            margin = self.intercept + sum(c * ((x - m) / s) for x, m, s, c in
                                          zip(features, self.mean, self.scale, self.coefficients))
        if not math.isfinite(margin):
            raise ValueError("Invalid model output")
        # This boundary is the supplied model's research boundary, not clinical risk.
        return "flagged" if margin > 0 else "not_flagged"


def decode_sample(encoded):
    if not isinstance(encoded, str) or len(encoded) > 700 * 1024:
        raise ValueError("Recording too large")
    audio = base64.b64decode(encoded, validate=True)
    if not 44 <= len(audio) <= 512 * 1024 or audio[:4] != b"RIFF" or audio[8:12] != b"WAVE":
        raise ValueError("Expected PCM WAV")
    if struct.unpack_from("<I", audio, 4)[0] != len(audio) - 8:
        raise ValueError("Invalid RIFF length")
    with wave.open(io.BytesIO(audio), "rb") as recording:
        if (recording.getnchannels(), recording.getsampwidth(), recording.getframerate(), recording.getcomptype()) != (1, 2, 16000, "NONE"):
            raise ValueError("Expected mono 16 kHz 16-bit PCM")
        frames = recording.getnframes()
        duration = frames / 16000
        if not 2 <= duration <= 12:
            raise ValueError("Expected 2–12 second recording")
        pcm = recording.readframes(frames)
    if len(pcm) != frames * 2:
        raise ValueError("Truncated PCM")
    samples = tuple(v[0] / 32768 for v in struct.iter_unpack("<h", pcm))
    rms = math.sqrt(sum(v * v for v in samples) / frames)
    clipped = sum(abs(v) >= 0.999 for v in samples) / frames
    return samples, duration, rms >= 0.006 and clipped < 0.01


def mfcc_features(samples, target_frames):
    # Mirrors the benchmark's 16 kHz librosa MFCC + fixed frame count + C-order
    # flattening. Only an artifact verified against its original pipeline may be
    # used; arbitrary benchmark pickles cannot be dropped into this service.
    import librosa
    import numpy as np
    matrix = librosa.feature.mfcc(y=np.asarray(samples, dtype=np.float32), sr=16000, n_mfcc=20,
                                 n_fft=2048, hop_length=512, n_mels=128, dct_type=2, norm="ortho")
    matrix = matrix[:, :target_frames]
    if matrix.shape[1] < target_frames:
        matrix = np.pad(matrix, ((0, 0), (0, target_frames - matrix.shape[1])))
    return matrix.flatten(order="C").tolist()
