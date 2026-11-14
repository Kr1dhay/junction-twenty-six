# Skin CNN (first-line classifier)

A tiny image classifier used as the **first stage** of the kiosk skin-photo risk estimate
(`apps/crm-web/src/server/skin-cnn.ts`, route `POST /demo/skin/assess`). Google Gemini is the second stage:
it receives the photo, this CNN's output and the patient's answers and produces the 0-100 score.

> Research / teaching demo only. Not a medical device. It must never be used to diagnose or rule out skin cancer.

| | |
|---|---|
| Architecture | torchvision `mobilenet_v3_small`, ImageNet-1K pretrained, new 7-class head (~1.5M params) |
| Data | [HAM10000](https://doi.org/10.1038/sdata.2018.161) via [`marmal88/skin_cancer`](https://huggingface.co/datasets/marmal88/skin_cancer), CC BY-NC 4.0 (non-commercial) |
| Classes | `akiec, bcc, bkl, df, mel, nv, vasc`; `mel`, `bcc`, `akiec` are summed as the malignant-class probability |
| Input | RGB 224×224, ImageNet mean/std, NCHW float32 |
| Output | `apps/crm-web/models/skin-cnn.<int8|fp32>.onnx` + `skin-cnn.json` (labels, preprocessing, test metrics), committed (< 8 MB, no Git LFS) |

The export keeps the dynamic-int8 model (~1.7 MB) only if it agrees with the float model on ≥ 95% of test images;
otherwise it ships fp32 (~6 MB). The metrics in `skin-cnn.json` are the shipped model's.

**Known limitations.** HAM10000 is dermoscopy (close-up, polarised light, mostly lighter skin types). Kiosk camera
photos look different, so the CNN is treated as a weak signal and the Gemini prompt says so. The dataset's
splits may contain several images of the same lesion, which can inflate test accuracy.

## Retrain

```sh
python3 -m venv .venv-skin && .venv-skin/bin/pip install -r scripts/skin-cnn/requirements.txt
.venv-skin/bin/python scripts/skin-cnn/train.py            # ~3.7 GB dataset download on first run
.venv-skin/bin/python scripts/skin-cnn/train.py --epochs 1 --limit 256   # quick smoke run
```

If the model files are missing, the backend still works: it returns a deterministic simulated CNN output marked
`"source": "simulated"`, and Gemini is told so.
