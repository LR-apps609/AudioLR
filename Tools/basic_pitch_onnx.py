# Basic Pitch (Spotify, ICASSP 2022, licenza Apache 2.0) per IsoLR su Windows: il file ONNX che Spotify
# pubblica nel pacchetto Python basic-pitch (saved_models/icassp_2022/nmp.onnx), provato con ONNX Runtime
# contro il modello originale TensorFlow (saved_models/icassp_2022/nmp). È lo stesso modello che il Mac usa
# in Core ML (Resources/BasicPitch.mlpackage): lo si verifica confrontando i pesi con nmp.mlpackage del pacchetto.
#
#   python Tools/basic_pitch_onnx.py <cartella basic_pitch/saved_models/icassp_2022> <NomeUscita> [Resources/BasicPitch.mlpackage]
#
# Contratto (come Sources/Midi.swift): audio mono a 22 050 Hz, finestre di 43 844 campioni (2 s meno un passo),
# passo della rete 256 campioni, 172 colonne per finestra, 88 tasti (da MIDI 21).
#   ingresso  «serving_default_input_2:0»   float32 (N, 43844, 1)
#   uscite    «StatefulPartitionedCall:1»   note    (N, 172, 88)   (Core ML: Identity_1)
#             «StatefulPartitionedCall:2»   onset   (N, 172, 88)   (Core ML: Identity_2)
#             «StatefulPartitionedCall:0»   contour (N, 172, 264)  (Core ML: Identity)
import sys, os, math, json, hashlib, shutil
import numpy as np

SRC, OUT = sys.argv[1], sys.argv[2]
MAC = sys.argv[3] if len(sys.argv) > 3 else None
MIN_DB = float(os.environ.get("MIN_DB", "60"))
SR, HOP, W, FRAMES, KEYS = 22050, 256, 43844, 172, 88
IN = "serving_default_input_2:0"
OUTS = {"note": "StatefulPartitionedCall:1", "onset": "StatefulPartitionedCall:2", "contour": "StatefulPartitionedCall:0"}


def sha(path):
    return hashlib.sha256(open(path, "rb").read()).hexdigest()


# 0. Lo stesso modello del Mac
if MAC:
    rel = "Data/com.apple.CoreML/weights/weight.bin"
    same = sha(os.path.join(MAC, rel)) == sha(os.path.join(SRC, "nmp.mlpackage", rel))
    print(f"Pesi uguali a quelli del Mac (BasicPitch.mlpackage): {'sì' if same else 'NO'}")
    assert same, "il modello del pacchetto non è quello del Mac"

# 1. Audio di prova: tre finestre con note di pianoforte finto (armoniche che decadono), accordi e silenzio
rng = np.random.default_rng(0)
n = 3 * W
t = np.arange(n) / SR
x = np.zeros(n)
for k, (start, midi) in enumerate([(0.1, 60), (0.6, 64), (1.1, 67), (2.3, 48), (2.4, 72), (3.5, 55), (4.2, 76), (5.0, 62)]):
    f0 = 440 * 2 ** ((midi - 69) / 12)
    on = t >= start
    tt = np.where(on, t - start, 0)
    env = np.where(on, np.exp(-tt * 2.5) * np.minimum(tt * 200, 1), 0)
    x += sum(0.25 / h * np.sin(2 * np.pi * h * f0 * tt) for h in range(1, 8)) * env
x += 0.002 * rng.standard_normal(n)
batch = x.reshape(3, W, 1).astype(np.float32)

# 2. ONNX Runtime (lo stesso di Windows: 1.19.2) contro TensorFlow
import onnxruntime as ort
import tensorflow as tf

onnx_path = os.path.join(SRC, "nmp.onnx")
sess = ort.InferenceSession(onnx_path, providers=["CPUExecutionProvider"])
ins = {i.name: i.shape for i in sess.get_inputs()}
outs = {o.name: o.shape for o in sess.get_outputs()}
print("ONNX ingressi:", ins, "uscite:", outs)
assert IN in ins and all(v in outs for v in OUTS.values())
got = dict(zip(OUTS, sess.run(list(OUTS.values()), {IN: batch})))

model = tf.saved_model.load(os.path.join(SRC, "nmp"))
fn = model.signatures["serving_default"]
key = list(fn.structured_input_signature[1].keys())[0]
ref = {k: v.numpy() for k, v in fn(**{key: tf.constant(batch)}).items()}
print("TensorFlow uscite:", {k: v.shape for k, v in ref.items()})
assert set(OUTS) <= set(ref), f"uscite TensorFlow inattese: {list(ref)}"


def snr(r, e):
    return 10 * math.log10(np.sum(r.astype(np.float64) ** 2) / max(np.sum((r.astype(np.float64) - e) ** 2), 1e-20))


dbs = {}
for k in OUTS:
    assert ref[k].shape == got[k].shape, f"{k}: misure diverse {ref[k].shape} / {got[k].shape}"
    assert np.all(np.isfinite(got[k]))
    dbs[k] = snr(ref[k], got[k])
    print(f"ONNX 32 bit / Basic Pitch ({k}): {dbs[k]:.1f} dB, massimo {got[k].max():.2f}")
db = min(dbs.values())
print(f"ONNX 32 bit / Basic Pitch: {db:.1f} dB")
assert db > MIN_DB, "nmp.onnx non dà lo stesso risultato del modello TensorFlow"
assert got["note"].max() > 0.3, "il modello non trova le note di prova"

shutil.copyfile(onnx_path, OUT + ".onnx")
json.dump({"kind": "basicpitch", "model": "basic-pitch 0.4.0 icassp_2022 nmp", "samplerate": SR, "hop": HOP,
           "window": W, "frames": FRAMES, "keys": KEYS, "midi_offset": 21, "overlap_frames": 30,
           "precision": "32", "db": round(db, 1), "db_per_output": {k: round(v, 1) for k, v in dbs.items()},
           "format": "onnx", "inputs": {IN: ["N", W, 1]},
           "outputs": {"note": {"name": OUTS["note"], "shape": ["N", FRAMES, KEYS], "coreml": "Identity_1"},
                       "onset": {"name": OUTS["onset"], "shape": ["N", FRAMES, KEYS], "coreml": "Identity_2"},
                       "contour": {"name": OUTS["contour"], "shape": ["N", FRAMES, 3 * KEYS], "coreml": "Identity"}},
           "license": "Apache-2.0 (Spotify basic-pitch)"}, open(OUT + ".json", "w"), indent=1)
# [campioni per finestra, finestre] · audio (finestre × campioni) · note · onset (TensorFlow, finestre × 172 × 88)
with open(OUT + "-prova.f32", "wb") as f:
    np.array([W, 3], dtype="<f4").tofile(f)
    batch.astype("<f4").tofile(f)
    ref["note"].astype("<f4").tofile(f)
    ref["onset"].astype("<f4").tofile(f)
print("Fatto:", OUT + ".onnx", "32", round(db, 1), f"{os.path.getsize(OUT + '.onnx') / 1e3:.0f} KB")
