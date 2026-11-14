import { existsSync, readFileSync } from "node:fs";
import path from "node:path";
import { createHash } from "node:crypto";
import type { InferenceSession } from "onnxruntime-node";

/** First-line skin-lesion classifier: MobileNetV3-Small fine-tuned on HAM10000 (see scripts/skin-cnn). Research demo only. */
export const skinLabels = ["akiec", "bcc", "bkl", "df", "mel", "nv", "vasc"] as const;
export type SkinLabel = typeof skinLabels[number];
export const skinLabelNames: Record<SkinLabel, string> = {
  akiec: "actinic keratosis / intraepithelial carcinoma", bcc: "basal cell carcinoma", bkl: "benign keratosis-like lesion",
  df: "dermatofibroma", mel: "melanoma", nv: "melanocytic nevus (mole)", vasc: "vascular lesion",
};
const malignant: SkinLabel[] = ["mel", "bcc", "akiec"];
export interface SkinCNNResult {
  probabilities: Record<SkinLabel, number>;
  top: SkinLabel;
  top_probability: number;
  malignant_probability: number;
  /** "cnn" when the committed ONNX model ran; "simulated" when it is unavailable (demo continues). */
  source: "cnn" | "simulated";
  model: string;
}
interface Manifest { model: string; architecture: string; input: { name: string; size: number; mean: number[]; std: number[] }; output: string; metrics?: Record<string, number> }

// Next runs from apps/crm-web; the root test runner runs from the repository root.
const modelDirectory = () => process.env.EDGECARE_SKIN_MODEL_DIR ??
  [path.join(process.cwd(), "models"), path.join(process.cwd(), "apps", "crm-web", "models")].find(directory => existsSync(path.join(directory, "skin-cnn.json"))) ??
  path.join(process.cwd(), "models");
let cached: Promise<{ session: InferenceSession; manifest: Manifest } | undefined> | undefined;
function load() {
  cached ??= (async () => {
    const directory = modelDirectory();
    const manifestPath = path.join(directory, "skin-cnn.json");
    if (!existsSync(manifestPath)) return undefined;
    const manifest = JSON.parse(readFileSync(manifestPath, "utf8")) as Manifest;
    const modelPath = path.join(directory, manifest.model);
    if (!existsSync(modelPath)) return undefined;
    const ort = await import("onnxruntime-node");
    return { session: await ort.InferenceSession.create(modelPath, { executionProviders: ["cpu"] }), manifest };
  })().catch(error => { console.warn(`skin-cnn: model unavailable (${error instanceof Error ? error.message : "load failed"}); using simulated output.`); return undefined; });
  return cached;
}
/** Test hook. */
export function resetSkinCNN() { cached = undefined; }

function summarise(probabilities: number[], source: SkinCNNResult["source"], model: string): SkinCNNResult {
  const entries = skinLabels.map((label, index) => [label, Number(probabilities[index]!.toFixed(4))] as const);
  const [top, topProbability] = entries.reduce((best, entry) => entry[1] > best[1] ? entry : best);
  return {
    probabilities: Object.fromEntries(entries) as Record<SkinLabel, number>, top, top_probability: topProbability,
    malignant_probability: Number(malignant.reduce((sum, label) => sum + entries[skinLabels.indexOf(label)]![1], 0).toFixed(4)),
    source, model,
  };
}
const softmax = (logits: number[]) => { const max = Math.max(...logits); const exp = logits.map(value => Math.exp(value - max)); const sum = exp.reduce((a, b) => a + b, 0); return exp.map(value => value / sum); };

/** Deterministic per-image pseudo-random distribution so the demo still works without the model file. */
export function simulatedSkinCNN(image: Buffer): SkinCNNResult {
  const seed = createHash("sha256").update(image).digest();
  const logits = skinLabels.map((label, index) => seed[index]! / 64 + (label === "nv" ? 2 : 0));
  return summarise(softmax(logits), "simulated", "simulated (model file not found)");
}

export async function classifySkinImage(image: Buffer): Promise<SkinCNNResult> {
  const loaded = await load();
  if (!loaded) return simulatedSkinCNN(image);
  const { session, manifest } = loaded;
  const { size, mean, std } = manifest.input;
  const sharp = (await import("sharp")).default;
  // .rotate() applies EXIF orientation from phone cameras before resizing.
  const pixels = await sharp(image, { limitInputPixels: 50_000_000 }).rotate().removeAlpha().resize(size, size, { fit: "fill" }).raw().toBuffer();
  const plane = size * size;
  const input = new Float32Array(3 * plane);
  for (let index = 0; index < plane; index++) {
    for (let channel = 0; channel < 3; channel++) input[channel * plane + index] = (pixels[index * 3 + channel]! / 255 - mean[channel]!) / std[channel]!;
  }
  const ort = await import("onnxruntime-node");
  const output = await session.run({ [manifest.input.name]: new ort.Tensor("float32", input, [1, 3, size, size]) });
  const logits = Array.from(output[manifest.output]!.data as Float32Array);
  return summarise(softmax(logits), "cnn", manifest.architecture);
}
