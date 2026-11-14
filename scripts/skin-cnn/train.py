"""Fine-tune a tiny skin-lesion CNN (MobileNetV3-Small) on HAM10000 and export an int8 ONNX model.

Research/demo use only. This model is NOT a medical device and must never be used to diagnose.

Usage (see README.md):
    python scripts/skin-cnn/train.py [--epochs 8] [--limit 0]
Outputs (committed):
    apps/crm-web/models/skin-cnn.int8.onnx   (~1.7 MB) or skin-cnn.fp32.onnx (~6 MB) if int8 loses accuracy
    apps/crm-web/models/skin-cnn.json        (labels, preprocessing, metrics)
"""
from __future__ import annotations

import argparse
import datetime as dt
import json
import os
import tempfile
from pathlib import Path

import numpy as np
import torch
import torch.nn as nn
from datasets import load_dataset
from torch.utils.data import DataLoader, Dataset
from torchvision import models, transforms

LABELS = ["akiec", "bcc", "bkl", "df", "mel", "nv", "vasc"]
# marmal88/skin_cancer spells the HAM10000 dx codes out in full.
DATASET_LABELS = {"actinic_keratoses": "akiec", "basal_cell_carcinoma": "bcc", "benign_keratosis-like_lesions": "bkl",
                  "dermatofibroma": "df", "melanoma": "mel", "melanocytic_Nevi": "nv", "vascular_lesions": "vasc"}


def label_index(dx: str) -> int:
    return LABELS.index(DATASET_LABELS.get(dx, dx))
MEAN = [0.485, 0.456, 0.406]
STD = [0.229, 0.224, 0.225]
SIZE = 224
MAX_BYTES = 8 * 1024 * 1024  # small enough to commit without Git LFS
MIN_INT8_AGREEMENT = 0.95
ROOT = Path(__file__).resolve().parents[2]
OUT = ROOT / "apps" / "crm-web" / "models"


class HFImages(Dataset):
    def __init__(self, split, transform, limit: int):
        self.split = split if not limit else split.select(range(min(limit, len(split))))
        self.transform = transform

    def __len__(self):
        return len(self.split)

    def __getitem__(self, index):
        row = self.split[index]
        return self.transform(row["image"].convert("RGB")), label_index(row["dx"])


def build_model() -> nn.Module:
    model = models.mobilenet_v3_small(weights=models.MobileNet_V3_Small_Weights.IMAGENET1K_V1)
    model.classifier[3] = nn.Linear(model.classifier[3].in_features, len(LABELS))
    return model


def evaluate(model, loader, device):
    model.eval()
    predictions, targets = [], []
    with torch.no_grad():
        for images, labels in loader:
            predictions.append(model(images.to(device)).argmax(1).cpu())
            targets.append(labels)
    predictions, targets = torch.cat(predictions).numpy(), torch.cat(targets).numpy()
    accuracy = float((predictions == targets).mean())
    recalls = [float((predictions[targets == c] == c).mean()) for c in range(len(LABELS)) if (targets == c).any()]
    return accuracy, float(np.mean(recalls)), predictions


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--epochs", type=int, default=8)
    parser.add_argument("--batch", type=int, default=64)
    parser.add_argument("--limit", type=int, default=0, help="Rows per split for a quick smoke run (0 = all).")
    parser.add_argument("--workers", type=int, default=min(6, os.cpu_count() or 1))
    args = parser.parse_args()
    torch.manual_seed(7)
    device = torch.device("mps" if torch.backends.mps.is_available() else "cuda" if torch.cuda.is_available() else "cpu")
    print(f"device={device}")

    data = load_dataset("marmal88/skin_cancer")
    train_tf = transforms.Compose([
        transforms.RandomResizedCrop(SIZE, scale=(0.6, 1.0)),
        transforms.RandomHorizontalFlip(), transforms.RandomVerticalFlip(), transforms.RandomRotation(20),
        # Colour jitter narrows the gap between dermoscopy training images and kiosk phone photos.
        transforms.ColorJitter(0.3, 0.3, 0.3, 0.05),
        transforms.ToTensor(), transforms.Normalize(MEAN, STD),
    ])
    eval_tf = transforms.Compose([transforms.Resize((SIZE, SIZE)), transforms.ToTensor(), transforms.Normalize(MEAN, STD)])
    train = HFImages(data["train"], train_tf, args.limit)
    val = HFImages(data["validation"], eval_tf, args.limit)
    test = HFImages(data["test"], eval_tf, args.limit)
    loader = lambda ds, shuffle: DataLoader(ds, batch_size=args.batch, shuffle=shuffle, num_workers=args.workers,
                                            persistent_workers=args.workers > 0)
    train_loader, val_loader, test_loader = loader(train, True), loader(val, False), loader(test, False)

    # nv dominates HAM10000 (~67%); weight classes by inverse frequency so melanoma is not ignored.
    counts = np.bincount([label_index(dx) for dx in train.split["dx"]], minlength=len(LABELS)).astype(np.float32)
    weights = torch.tensor(counts.sum() / (len(LABELS) * np.maximum(counts, 1)), dtype=torch.float32).sqrt()
    print("class counts", dict(zip(LABELS, counts.astype(int).tolist())))

    model = build_model().to(device)
    criterion = nn.CrossEntropyLoss(weight=weights.to(device), label_smoothing=0.05)
    optimizer = torch.optim.AdamW(model.parameters(), lr=1e-3, weight_decay=1e-4)
    scheduler = torch.optim.lr_scheduler.CosineAnnealingLR(optimizer, T_max=args.epochs * len(train_loader))
    best, best_state = -1.0, None
    for epoch in range(args.epochs):
        model.train()
        total = 0.0
        for images, labels in train_loader:
            optimizer.zero_grad()
            loss = criterion(model(images.to(device)), labels.to(device))
            loss.backward(); optimizer.step(); scheduler.step()
            total += loss.item() * len(labels)
        accuracy, balanced, _ = evaluate(model, val_loader, device)
        print(f"epoch {epoch + 1}/{args.epochs} loss={total / len(train):.4f} val_acc={accuracy:.3f} val_bal_acc={balanced:.3f}", flush=True)
        if balanced > best:
            best, best_state = balanced, {k: v.detach().cpu().clone() for k, v in model.state_dict().items()}

    model.load_state_dict(best_state)
    test_acc, test_bal, fp32_predictions = evaluate(model, test_loader, device)
    print(f"test_acc={test_acc:.3f} test_bal_acc={test_bal:.3f}")

    from onnxruntime.quantization import QuantType, quantize_dynamic
    import onnxruntime as ort
    OUT.mkdir(parents=True, exist_ok=True)
    model = model.cpu().eval()
    targets = np.array([label_index(dx) for dx in test.split["dx"]])

    def onnx_predictions(path: Path):
        session = ort.InferenceSession(str(path), providers=["CPUExecutionProvider"])
        return np.concatenate([session.run(["logits"], {"input": images.numpy()})[0].argmax(1) for images, _ in test_loader])

    for stale in OUT.glob("skin-cnn*.onnx"):
        stale.unlink()
    with tempfile.TemporaryDirectory() as tmp:
        fp32 = Path(tmp) / "skin-cnn.fp32.onnx"
        int8 = Path(tmp) / "skin-cnn.int8.onnx"
        torch.onnx.export(model, torch.zeros(1, 3, SIZE, SIZE), fp32, input_names=["input"], output_names=["logits"],
                          dynamic_axes={"input": {0: "batch"}, "logits": {0: "batch"}}, opset_version=17, dynamo=False)
        quantize_dynamic(str(fp32), str(int8), weight_type=QuantType.QUInt8)
        # Dynamic int8 can hurt small conv nets (hard-swish / squeeze-excite). Keep it only if it
        # agrees with the float model; otherwise ship fp32, which is still only ~6 MB.
        predictions = onnx_predictions(int8)
        agreement = float((predictions == fp32_predictions).mean())
        print(f"int8 size={int8.stat().st_size / 1024 / 1024:.2f} MB agreement_with_fp32={agreement:.3f}")
        if agreement >= MIN_INT8_AGREEMENT:
            precision, chosen = "int8", int8
        else:
            precision, chosen, predictions = "fp32", fp32, onnx_predictions(fp32)
        target = OUT / f"skin-cnn.{precision}.onnx"
        target.write_bytes(chosen.read_bytes())
    size = target.stat().st_size
    assert size < MAX_BYTES, f"Model is {size} bytes; must stay under {MAX_BYTES} to be committed."
    onnx_acc = float((predictions == targets).mean())
    print(f"shipping {precision}: size={size / 1024 / 1024:.2f} MB onnx_test_acc={onnx_acc:.3f}")

    (OUT / "skin-cnn.json").write_text(json.dumps({
        "model": target.name,
        "architecture": f"torchvision mobilenet_v3_small (ImageNet-1K pretrained), 7-class head, {precision}",
        "dataset": "HAM10000 via huggingface.co/datasets/marmal88/skin_cancer (CC BY-NC 4.0)",
        "labels": LABELS,
        "malignant_labels": ["mel", "bcc", "akiec"],
        "input": {"name": "input", "size": SIZE, "layout": "NCHW", "mean": MEAN, "std": STD},
        "output": "logits",
        "metrics": {"test_accuracy": round(onnx_acc, 4), "test_balanced_accuracy": round(test_bal, 4),
                    "int8_fp32_agreement": round(agreement, 4), "test_images": int(len(targets)), "size_bytes": size},
        "trained": dt.date.today().isoformat(),
        "warning": "Research demo only. Trained on dermoscopy images; unreliable on phone photos. Not a diagnosis.",
    }, indent=2) + "\n")
    print(f"wrote {target} and skin-cnn.json")


if __name__ == "__main__":
    main()
