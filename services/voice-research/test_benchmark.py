import hashlib
import io
import json
from pathlib import Path
import pickle
import tempfile
import unittest

from core import DenseVoiceModel, BENCHMARK_COMMIT, BENCHMARK_SHA256, BENCHMARK_MODEL_ID


class BenchmarkDemoTests(unittest.TestCase):
    def artifact(self):
        return {"feature_extractor": "librosa-mfcc-20-flatten-v1", "positive_class_meaning": "research_flag",
            "model_id": BENCHMARK_MODEL_ID, "model_version": BENCHMARK_COMMIT[:12], "target_frames": 1,
            "mean": [0] * 20, "scale": [1] * 20, "coefficients": [1] + [0] * 19, "intercept": 0,
            "demo_only": True, "license_status": "not_provided_by_upstream",
            "source": {"commit": BENCHMARK_COMMIT, "sha256": BENCHMARK_SHA256},
            "arithmetic": "sklearn-float32-selected-v1", "selected_indices": [0]}

    def load(self, item, **kwargs):
        with tempfile.TemporaryDirectory() as folder:
            path = Path(folder) / "fixture.json"
            blob = json.dumps(item).encode()
            path.write_bytes(blob)
            return DenseVoiceModel.load(str(path), hashlib.sha256(blob).hexdigest(), **kwargs)

    def test_demo_is_explicit_pinned_and_never_claims_a_license(self):
        item = self.artifact()
        with self.assertRaises(ValueError):
            self.load(item)
        model = self.load(item, allow_unlicensed_demo=True)
        self.assertEqual(model.predict([0] * 20), "not_flagged")  # sklearn's zero-margin tie rule
        self.assertEqual(model.predict([1] * 20), "flagged")
        item["source"]["sha256"] = "0" * 64
        with self.assertRaises(ValueError):
            self.load(item, allow_unlicensed_demo=True)

    def test_selection_contract_rejects_bad_masks_and_hidden_weights(self):
        for indices in [[], [20], [-1], [0, 0], [True], [1, 0]]:
            item = self.artifact(); item["selected_indices"] = indices
            with self.assertRaises(ValueError):
                self.load(item, allow_unlicensed_demo=True)
        item = self.artifact(); item["coefficients"][1] = 1
        with self.assertRaises(ValueError):
            self.load(item, allow_unlicensed_demo=True)

    def test_offline_converter_rejects_unreviewed_globals_and_changed_downloads(self):
        try:
            from prepare_benchmark import BenchmarkUnpickler, read_source
        except ImportError:
            self.skipTest("Optional converter dependencies are not installed")
        loader = BenchmarkUnpickler("test", io.BytesIO(b""))
        for module, name in [("os", "system"), ("subprocess", "Popen"), ("builtins", "eval")]:
            with self.assertRaises(pickle.UnpicklingError):
                loader.find_class(module, name)
        with self.assertRaises(ValueError):
            read_source(b"unreviewed-download")

    def test_prepared_real_artifact_is_loadable_if_present(self):
        folder = Path(__file__).parent / "models"
        if not (folder / "manifest.json").exists():
            self.skipTest("Run the opt-in model preparation for the real-artifact test")
        manifest = json.loads((folder / "manifest.json").read_text())
        model = DenseVoiceModel.load(str(folder / "paterson-mfcc-lr.json"), manifest["sha256"], allow_unlicensed_demo=True)
        self.assertEqual(model.model_id, BENCHMARK_MODEL_ID)
        self.assertEqual(model.target_frames, 77)
        self.assertEqual(len(model.selected_indices), 29)
        self.assertEqual(manifest["parity"]["cases"], 12)


if __name__ == "__main__":
    unittest.main()
