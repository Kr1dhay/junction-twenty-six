# Hackathon voice-model artifact

`paterson-mfcc-lr.json` contains the real numeric parameters exported from Mary
Paterson et al.'s audio-only `LR_MFCC_Rec_Only.pkl` benchmark model. It is not a
newly trained model, synthetic classifier, or the paper's best-performing model.

- Source: https://github.com/mary-paterson/LaryngealCancerClassificationBenchmark
- Source commit: `7811f6d8cc8ac6dbe8535e9e2669febed4f51da4`
- Source path: `Pre-Trained Models/Logistic Regression/LR_MFCC_Rec_Only.pkl`
- Source SHA-256: `c7278909c9961ec675bdacd63acd5c4862c49274b1ccd56b781387ed272d1853`
- Runtime JSON SHA-256: `06f1c199787cec244ec8924739eefcdd8d0149ef7832c4cdcd7357be173d2b6a`
- Research paper: https://arxiv.org/abs/2412.16267

The export preserves the 77-frame MFCC preprocessing, standard scaling, 29
selected features, float32 classifier arithmetic and `Benign`/`Malignant` label
ordering. The upstream positive training category includes dysplasia. The
manifest records 12 synthetic software-parity checks, not clinical validation.
No audio, patient records, credentials or executable pickle is included.

**Conceptual hackathon evaluation only—not a cancer test.** It cannot diagnose
or rule out cancer, and must not determine clinical urgency.
