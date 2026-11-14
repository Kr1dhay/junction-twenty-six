import base64
import io
import math
import os
import struct
import unittest
from unittest.mock import patch
import wave

from fastapi.testclient import TestClient
import app as worker
from core import DenseVoiceModel


class WorkerAPITests(unittest.TestCase):
    def setUp(self):
        self.environment = patch.dict(os.environ, {"VOICE_RESEARCH_TOKEN": "synthetic-worker-token-" + "x" * 32})
        self.environment.start()
        self.client = TestClient(worker.app)
        self.headers = {"authorization": "Bearer " + os.environ["VOICE_RESEARCH_TOKEN"]}

    def tearDown(self):
        self.client.close()
        self.environment.stop()

    def body(self):
        buffer = io.BytesIO()
        with wave.open(buffer, "wb") as audio:
            audio.setnchannels(1); audio.setsampwidth(2); audio.setframerate(16000)
            audio.writeframes(b"".join(struct.pack("<h", int(4000 * math.sin(2 * math.pi * 180 * n / 16000)))
                                       for n in range(48000)))
        return {"consent": True, "task": "sustained_a", "capture_mode": "measurement",
                "audio_base64": base64.b64encode(buffer.getvalue()).decode()}

    def test_unauthorized_or_unconfigured_worker_never_classifies(self):
        with patch.object(worker, "model", None):
            self.assertEqual(self.client.get("/health").status_code, 401)
            self.assertEqual(self.client.get("/health", headers=self.headers).status_code, 503)
            self.assertEqual(self.client.post("/assess", json=self.body(), headers=self.headers).status_code, 503)

    def test_contract_consent_and_metadata(self):
        model = DenseVoiceModel("synthetic-test-only", "test-1", 1, (0,) * 20, (1,) * 20, (1,) * 20, -1)
        with patch.object(worker, "model", model), patch.object(worker, "mfcc_features", return_value=[1] * 20) as features:
            health = self.client.get("/health", headers=self.headers)
            self.assertTrue(health.json()["research_only"])
            response = self.client.post("/assess", json=self.body(), headers=self.headers)
            self.assertEqual(response.status_code, 200)
            self.assertEqual(response.json()["outcome"], "flagged")
            self.assertEqual(response.json()["sample_duration_seconds"], 3)
            self.assertNotIn("audio_base64", response.json())
            self.assertNotIn("probability", response.json())
            self.assertEqual(features.call_count, 1)
            for change in [{"consent": False}, {"consent": 1}, {"task": "conversation"}, {"capture_mode": "voiceChat"}]:
                body = self.body(); body.update(change)
                self.assertEqual(self.client.post("/assess", json=body, headers=self.headers).status_code, 400)
            self.assertEqual(features.call_count, 1)

    def test_real_mfcc_pipeline_has_expected_finite_dimensions(self):
        from core import decode_sample, mfcc_features
        samples, _, _ = decode_sample(self.body()["audio_base64"])
        values = mfcc_features(samples, 30)
        self.assertEqual(len(values), 600)
        self.assertTrue(all(math.isfinite(n) for n in values))

    def test_quiet_audio_abstains_and_oversized_body_is_rejected(self):
        model = DenseVoiceModel("synthetic-test-only", "test-1", 1, (0,) * 20, (1,) * 20, (1,) * 20, -1)
        body = self.body()
        audio = bytearray(base64.b64decode(body["audio_base64"]))
        audio[44:] = bytes(len(audio) - 44)
        body["audio_base64"] = base64.b64encode(audio).decode()
        with patch.object(worker, "model", model), patch.object(worker, "mfcc_features") as features:
            response = self.client.post("/assess", json=body, headers=self.headers)
            self.assertEqual(response.status_code, 200)
            self.assertEqual(response.json()["outcome"], "inconclusive")
            features.assert_not_called()
            response = self.client.post("/assess", content=b" " * (720 * 1024 + 1), headers=self.headers)
            self.assertEqual(response.status_code, 413)
            features.assert_not_called()


if __name__ == "__main__":
    unittest.main()
