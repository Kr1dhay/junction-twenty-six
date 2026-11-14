import base64
import hashlib
import io
import json
import math
from pathlib import Path
import struct
import tempfile
import unittest
import wave

from core import DenseVoiceModel, decode_sample


class ResearchCoreTests(unittest.TestCase):
    def recording(self, amplitude=4000, seconds=3, rate=16000):
        buffer = io.BytesIO()
        with wave.open(buffer, "wb") as out:
            out.setnchannels(1); out.setsampwidth(2); out.setframerate(rate)
            out.writeframes(b"".join(struct.pack("<h", int(amplitude * math.sin(i * 2 * math.pi * 180 / rate)))
                                     for i in range(rate * seconds)))
        return base64.b64encode(buffer.getvalue()).decode()

    def test_sample_and_quiet_abstention(self):
        _, duration, adequate = decode_sample(self.recording())
        self.assertEqual(duration, 3); self.assertTrue(adequate)
        self.assertFalse(decode_sample(self.recording(amplitude=0))[2])

    def test_bad_format_duration_and_base64(self):
        for value in ["invalid", self.recording(seconds=1), self.recording(rate=8000)]:
            with self.assertRaises(ValueError): decode_sample(value)

    def test_inference_uses_supplied_coefficients_not_fake_cancer_probabilities(self):
        # Synthetic arithmetic fixture only. Never shipped as a usable model.
        model = DenseVoiceModel("synthetic-test-only", "1", 1, (0,) * 20, (1,) * 20, (1,) * 20, -1)
        self.assertEqual(model.predict([0] * 20), "not_flagged")
        self.assertEqual(model.predict([1] * 20), "flagged")
        with self.assertRaises(ValueError): model.predict([float("nan")] * 20)

    def test_artifact_requires_checksum_provenance_and_valid_dimensions(self):
        item = {"feature_extractor": "librosa-mfcc-20-flatten-v1", "positive_class_meaning": "research_flag",
                "license_reference": "synthetic-test-only", "model_id": "synthetic-test-only", "model_version": "1",
                "target_frames": 1, "mean": [0] * 20, "scale": [1] * 20, "coefficients": [1] * 20, "intercept": 0}
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "model.json"
            blob = json.dumps(item).encode(); path.write_bytes(blob)
            checksum = hashlib.sha256(blob).hexdigest()
            self.assertEqual(DenseVoiceModel.load(str(path), checksum).version, "1")
            with self.assertRaises(ValueError): DenseVoiceModel.load(str(path), "0" * 64)
            del item["license_reference"]
            blob = json.dumps(item).encode(); path.write_bytes(blob)
            with self.assertRaises(ValueError): DenseVoiceModel.load(str(path), hashlib.sha256(blob).hexdigest())

    def test_artifact_rejects_non_objects_and_bounds_reads(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "invalid.json"
            for blob in [b"[]", b"null", b"0", b" " * (4 * 1024 * 1024 + 1)]:
                path.write_bytes(blob)
                with self.assertRaises(ValueError):
                    DenseVoiceModel.load(str(path), hashlib.sha256(blob).hexdigest())


if __name__ == "__main__":
    unittest.main()
