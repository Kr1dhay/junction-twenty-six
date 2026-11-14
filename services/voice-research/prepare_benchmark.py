"""Fetch one pinned benchmark model and export numeric JSON for local demos.

This offline converter is not imported by the serving worker. It uses an exact
hash and a closed unpickling allowlist, never ordinary joblib.load or upstream
Python imports. Upstream licensing remains unresolved; weights stay gitignored.
"""
import argparse
import hashlib
import io
import json
import pickle
from pathlib import Path
from urllib.request import urlopen

import numpy as np
from joblib.numpy_pickle import NumpyUnpickler
from sklearn.base import BaseEstimator, TransformerMixin
from core import BENCHMARK_COMMIT, BENCHMARK_SHA256, BENCHMARK_MODEL_ID

COMMIT = BENCHMARK_COMMIT
SOURCE_SHA256 = BENCHMARK_SHA256
SOURCE_PATH = "Pre-Trained%20Models/Logistic%20Regression/LR_MFCC_Rec_Only.pkl"
REPOSITORY = "https://github.com/mary-paterson/LaryngealCancerClassificationBenchmark"
SOURCE_URL = f"https://raw.githubusercontent.com/mary-paterson/LaryngealCancerClassificationBenchmark/{COMMIT}/{SOURCE_PATH}"
MODEL_ID = BENCHMARK_MODEL_ID
MODEL_VERSION = COMMIT[:12]


class MFCCPreprocessor(BaseEstimator, TransformerMixin):
    """Independent implementation of the reviewed fixed-frame MFCC transform."""
    def __init__(self, target_length=None):
        self.target_length = target_length

    def transform(self, matrices):
        result = []
        for matrix in matrices:
            fixed = np.zeros((20, self.target_length), dtype=matrix.dtype)
            count = min(matrix.shape[1], self.target_length)
            fixed[:, :count] = matrix[:, :count]
            result.append(fixed.reshape(-1))
        return np.asarray(result)


class BenchmarkUnpickler(NumpyUnpickler):
    # Exact estimator/numpy globals required by this pinned artifact only.
    ALLOWED = {
        ("sklearn.model_selection._search", "GridSearchCV"),
        ("sklearn.pipeline", "Pipeline"),
        ("sklearn.compose._column_transformer", "ColumnTransformer"),
        ("sklearn.impute._base", "SimpleImputer"),
        ("sklearn.preprocessing._data", "StandardScaler"),
        ("sklearn.feature_selection._from_model", "SelectFromModel"),
        ("sklearn.tree._classes", "DecisionTreeClassifier"),
        ("sklearn.tree._tree", "Tree"),
        ("sklearn.linear_model._logistic", "LogisticRegression"),
        ("joblib.numpy_pickle", "NumpyArrayWrapper"),
        ("numpy", "ndarray"), ("numpy", "dtype"),
        ("numpy.core.multiarray", "_reconstruct"),
        ("numpy.core.multiarray", "scalar"),
        ("numpy.ma.core", "_mareconstruct"), ("numpy.ma.core", "MaskedArray"),
        ("builtins", "slice"),
        ("pandas.core.indexes.base", "_new_Index"),
        ("pandas.core.indexes.base", "Index"),
        ("sklearn.metrics._scorer", "_Scorer"),
        ("sklearn.metrics._classification", "balanced_accuracy_score"),
    }

    def find_class(self, module, name):
        if (module, name) == ("custom_preprocessing", "MFCCPreprocessor"):
            return MFCCPreprocessor
        if (module, name) not in self.ALLOWED:
            raise pickle.UnpicklingError(f"Blocked model global: {module}.{name}")
        return super().find_class(module, name)


def read_source(blob):
    if hashlib.sha256(blob).hexdigest() != SOURCE_SHA256:
        raise ValueError("Upstream model checksum changed; review it before use")
    import zlib
    decompressor = zlib.decompressobj()
    unpacked = decompressor.decompress(blob, 2 * 1024 * 1024 + 1)
    if len(unpacked) > 2 * 1024 * 1024 or not decompressor.eof:
        raise ValueError("Invalid compressed model")
    return BenchmarkUnpickler("pinned-benchmark", io.BytesIO(unpacked)).load()


def export_model(search):
    pipeline = search.best_estimator_
    steps = dict(pipeline.steps)
    if set(steps) != {"preprocessor", "classifier"}:
        raise ValueError("Unexpected pipeline")
    preprocessor, classifier = steps["preprocessor"], steps["classifier"]
    if list(preprocessor.feature_names_in_) != ["mfcc"] or list(classifier.classes_) != ["Benign", "Malignant"]:
        raise ValueError("Unexpected inputs or class ordering")
    audio = preprocessor.named_transformers_["audio"]
    stages = dict(audio.steps)
    if list(stages) != ["mfcc_preprocessor", "imputer", "scaler", "feature_selection"]:
        raise ValueError("Unexpected preprocessing")
    frames = int(stages["mfcc_preprocessor"].target_length)
    scaler = stages["scaler"]
    support = stages["feature_selection"].get_support()
    coefficients = np.zeros(20 * frames, dtype=np.float64)
    coefficients[support] = classifier.coef_[0]
    if len(scaler.mean_) != len(coefficients) or not np.isfinite(stages["imputer"].statistics_).all():
        raise ValueError("Unexpected imputation/scaling dimensions")
    if not scaler.with_mean or not scaler.with_std or classifier.coef_.shape != (1, int(support.sum())):
        raise ValueError("Unexpected scaler/classifier")
    return {
        "feature_extractor": "librosa-mfcc-20-flatten-v1",
        "positive_class_meaning": "research_flag",
        "model_id": MODEL_ID, "model_version": MODEL_VERSION,
        "target_frames": frames, "mean": scaler.mean_.tolist(), "scale": scaler.scale_.tolist(),
        "coefficients": coefficients.tolist(), "intercept": float(classifier.intercept_[0]),
        "arithmetic": "sklearn-float32-selected-v1",
        "selected_indices": np.flatnonzero(support).tolist(),
        "demo_only": True, "license_status": "not_provided_by_upstream",
        "source": {"repository": REPOSITORY, "commit": COMMIT, "sha256": SOURCE_SHA256, "url": SOURCE_URL},
        "class_mapping": {"negative": "Benign", "positive": "Malignant (includes dysplasia in training)"},
    }


def verify_parity(search, artifact, model):
    import pandas as pd
    from core import mfcc_features
    rng = np.random.default_rng(2026)
    maximum_error = 0.0
    cases = []
    # Vary lengths and feature distributions to exercise padding, truncation and
    # both sides of the decision boundary. These are software, not clinical tests.
    for count in [25, artifact["target_frames"], artifact["target_frames"] + 20]:
        for location in [-100.0, 0.0, 100.0]:
            cases.append(rng.normal(location, 30, (20, count)).astype(np.float32))
    import librosa
    for seconds in [3, 6, 10]:
        signal = (0.15 * np.sin(2 * np.pi * 180 * np.arange(seconds * 16000) / 16000)).astype(np.float32)
        matrix = librosa.feature.mfcc(y=signal, sr=16000)
        cases.append(matrix)
        expected = MFCCPreprocessor(artifact["target_frames"]).transform([matrix])[0]
        np.testing.assert_allclose(mfcc_features(signal, artifact["target_frames"]), expected, rtol=0, atol=0)
    for matrix in cases:
        frame = pd.DataFrame({"mfcc": [matrix]})
        original_margin = float(search.best_estimator_.decision_function(frame)[0])
        fixed = MFCCPreprocessor(artifact["target_frames"]).transform([matrix])[0]
        expanded_margin = float(artifact["intercept"] + np.dot(
            (fixed - np.asarray(artifact["mean"])) / np.asarray(artifact["scale"]), artifact["coefficients"]))
        # Expanded double-precision algebra can differ slightly from sklearn's
        # float32 path. Actual serving below preserves the original float32 path.
        np.testing.assert_allclose(expanded_margin, original_margin, rtol=1e-5, atol=1e-5)
        expected = "flagged" if search.predict(frame)[0] == "Malignant" else "not_flagged"
        if model.predict(fixed) != expected:
            raise ValueError("Exported prediction does not match upstream pipeline")
        maximum_error = max(maximum_error, abs(original_margin - expanded_margin))
    return {"cases": len(cases), "maximum_margin_error": maximum_error, "clinical_validation": False}


def prepare(destination):
    from core import DenseVoiceModel
    destination.mkdir(parents=True, exist_ok=True)
    with urlopen(SOURCE_URL, timeout=45) as response:
        blob = response.read(1024 * 1024 + 1)
    source = read_source(blob)
    artifact = export_model(source)
    path = destination / "paterson-mfcc-lr.json"
    encoded = (json.dumps(artifact, allow_nan=False, separators=(",", ":")) + "\n").encode()
    checksum = hashlib.sha256(encoded).hexdigest()
    # Verify fully before writing a ready-to-use artifact.
    import tempfile
    with tempfile.TemporaryDirectory() as folder:
        test_path = Path(folder) / "candidate.json"
        test_path.write_bytes(encoded)
        model = DenseVoiceModel.load(str(test_path), checksum, allow_unlicensed_demo=True)
        parity = verify_parity(source, artifact, model)
    path.write_bytes(encoded)
    report = {"model_id": MODEL_ID, "model_version": MODEL_VERSION, "sha256": checksum,
              "source_sha256": SOURCE_SHA256, "parity": parity, "license_status": artifact["license_status"]}
    (destination / "manifest.json").write_text(json.dumps(report, indent=2) + "\n")
    print(json.dumps(report, indent=2))
    return path, report


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, default=Path(__file__).parent / "models")
    parser.add_argument("--acknowledge-unlicensed-local-demo", action="store_true",
                        help="Local conceptual evaluation only; this does not grant a license")
    args = parser.parse_args()
    if not args.acknowledge_unlicensed_local_demo:
        parser.error("Explicit --acknowledge-unlicensed-local-demo is required; do not redistribute the weights")
    prepare(args.output)
