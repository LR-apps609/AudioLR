# Converte un modello voce Mel-Band RoFormer (ad es. «vocals_mel_band_roformer» di Kimberley Jensen)
# in Core ML per AudioLR. Si esegue sul Mac di GitHub (workflow «Modello voce RoFormer»).
#
# Come per Demucs, nel modello Core ML c'è solo la rete. L'app fa il resto in Swift:
#   1. STFT di ogni canale (2048 punti, passo 441, finestra di Hann, come torch.stft non normalizzata)
#   2. raccolta delle frequenze delle bande mel (freq_indices) → ingresso «x» (1, T, Fsel·2)
#   3. il modello restituisce le maschere «mask» (1, T, Fsel·2) (reale/immaginaria alternate)
#   4. somma delle maschere sulle frequenze (scatter-add), divisione per il numero di bande,
#      prodotto complesso con la STFT, iSTFT
# stft_np/istft_np/pipeline_np qui sotto sono la copia esatta di quello che fa l'app, confrontata con il modello intero.
#
#   python Tools/convert_roformer.py <file.ckpt> <config.yaml> <NomeUscita> [campioni_per_pezzo]
import sys, os, math, json
import numpy as np
import torch
import yaml
import coremltools as ct

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from roformer.mel_band_roformer import MelBandRoformer

CKPT, CFG, OUT = sys.argv[1], sys.argv[2], sys.argv[3]
CHUNK = int(sys.argv[4]) if len(sys.argv) > 4 else 176400        # 4 s: l'attenzione nel tempo resta leggera


class Loader(yaml.SafeLoader):
    pass


Loader.add_constructor("tag:yaml.org,2002:python/tuple", lambda l, n: tuple(l.construct_sequence(n)))
cfg = yaml.load(open(CFG), Loader=Loader)
mc = dict(cfg["model"])
m = MelBandRoformer(**mc).eval()
state = torch.load(CKPT, map_location="cpu")
if isinstance(state, dict) and "state_dict" in state:
    state = state["state_dict"]
missing, unexpected = m.load_state_dict(state, strict=False)
print("pesi mancanti:", missing[:5], "inattesi:", unexpected[:5])
assert not missing, "il file dei pesi non corrisponde al modello"

N, HOP = mc.get("stft_n_fft", 2048), mc.get("stft_hop_length", 441)
assert mc.get("stft_win_length", N) == N and not mc.get("stft_normalized", False)
T = CHUNK // HOP + 1
FI = m.freq_indices.numpy().astype(np.int64)                      # indici in (f·2 + canale)
NB = m.num_bands_per_freq.numpy().astype(np.float64)              # bande che coprono ogni frequenza
FSEL = len(FI)
STEMS = list(cfg["training"]["instruments"]) if not cfg["training"].get("target_instrument") else [cfg["training"]["target_instrument"]]
print(f"{OUT}: {STEMS}, pezzo di {CHUNK} campioni, {T} colonne, {FSEL} frequenze selezionate")


class Core(torch.nn.Module):
    """Band split, trasformatori e stime delle maschere: la parte senza numeri complessi."""

    def __init__(self, m):
        super().__init__()
        self.m = m

    def forward(self, x):
        m = self.m
        x = m.band_split(x)
        for time_transformer, freq_transformer in m.layers:
            b, t, f, d = x.shape
            x = x.permute(0, 2, 1, 3).reshape(b * f, t, d)
            x = time_transformer(x)
            x = x.reshape(b, f, t, d).permute(0, 2, 1, 3).reshape(b * t, f, d)
            x = freq_transformer(x)
            x = x.reshape(b, t, f, d)
        masks = torch.stack([fn(x) for fn in m.mask_estimators], dim=1)   # (b, n, t, fsel·2)
        return masks[:, 0]


# ── Copia di quello che fa l'app ───────────────────────────────────────────────────────────────
WIN = 0.5 - 0.5 * np.cos(2 * np.pi * np.arange(N) / N)


def stft_np(x):
    pad = N // 2
    xp = np.pad(x, (pad, pad), mode="reflect")
    frames = 1 + len(x) // HOP
    out = np.empty((N // 2 + 1, frames), dtype=np.complex128)
    for t in range(frames):
        out[:, t] = np.fft.rfft(xp[t * HOP:t * HOP + N] * WIN)
    return out


def istft_np(z, length):
    frames = z.shape[1]
    total = N + HOP * (frames - 1)
    buf, env = np.zeros(total), np.zeros(total)
    for t in range(frames):
        buf[t * HOP:t * HOP + N] += np.fft.irfft(z[:, t], n=N) * WIN
        env[t * HOP:t * HOP + N] += WIN * WIN
    pad = N // 2
    e = env[pad:pad + length]
    return buf[pad:pad + length] / np.where(e > 1e-11, e, 1)


def pipeline_np(core_fn, mix):
    """Un pezzo (2, CHUNK) come lo lavora l'app → voce (2, CHUNK)."""
    z = [stft_np(mix[c]) for c in range(2)]
    F = N // 2 + 1
    full = np.empty((F * 2, T), dtype=np.complex128)            # (f·2 + canale, t)
    full[0::2], full[1::2] = z[0], z[1]
    sel = full[FI]                                               # (fsel, t)
    x = np.stack([sel.real, sel.imag], -1).transpose(1, 0, 2).reshape(1, T, FSEL * 2)
    mask = core_fn(x.astype(np.float32))[0].astype(np.float64).reshape(T, FSEL, 2)
    mc_ = mask[..., 0] + 1j * mask[..., 1]                       # (t, fsel)
    summed = np.zeros((F * 2, T), dtype=np.complex128)
    np.add.at(summed, FI, mc_.T)
    denom = np.repeat(NB, 2)[:, None]
    est = full * summed / np.maximum(denom, 1e-8)
    return np.stack([istft_np(est[c::2], mix.shape[1]) for c in range(2)])


def snr(ref, est):
    return 10 * math.log10(np.sum(ref ** 2) / max(np.sum((ref - est) ** 2), 1e-20))


# Una «canzone» di prova: accordi, basso, colpi, una voce che sale e scende
rng = np.random.default_rng(0)
sr = 44100
t = np.arange(CHUNK) / sr
sig = np.zeros((2, CHUNK))
for f, pan in [(220, 0.3), (277.18, 0.5), (329.63, 0.7)]:
    sig[0] += 0.12 * (1 - pan) * np.sin(2 * np.pi * f * t)
    sig[1] += 0.12 * pan * np.sin(2 * np.pi * f * t)
sig += 0.2 * np.sin(2 * np.pi * 55 * t)
for k in range(0, CHUNK, sr // 2):
    n = min(4000, CHUNK - k)
    sig[:, k:k + n] += rng.standard_normal(n) * np.exp(-np.arange(n) / 600) * 0.4
sig += 0.15 * np.sin(2 * np.pi * (440 + 80 * np.sin(2 * np.pi * 0.5 * t)) * t) * (0.5 + 0.5 * np.sin(2 * np.pi * 0.25 * t))
mix = sig.astype(np.float32)

# 1. La STFT dell'app è quella di torch
with torch.no_grad():
    zt = torch.stft(torch.from_numpy(mix[0]), n_fft=N, hop_length=HOP, win_length=N, window=torch.hann_window(N),
                    return_complex=True).numpy()
e1 = np.abs(zt - stft_np(mix[0].astype(np.float64))).max() / np.abs(zt).max()
print(f"STFT app / torch: {e1:.2e}")
assert e1 < 1e-4

# 2. Il modello diviso (app + Core) dà lo stesso risultato del modello intero
core = Core(m).eval()
m.match_input_audio_length = True
with torch.no_grad():
    ref = m(torch.from_numpy(mix)[None]).numpy()[0].astype(np.float64)
ref = ref.reshape(-1, 2, CHUNK)[0]


def core_torch(x):
    with torch.no_grad():
        return core(torch.from_numpy(x)).numpy()


q = snr(ref, pipeline_np(core_torch, mix.astype(np.float64)))
print(f"RoFormer diviso / intero: {q:.1f} dB")
assert q > 60, "dividere il modello cambia il risultato"

# 3. Core ML
x_in = torch.randn(1, T, FSEL * 2)
traced = torch.jit.trace(core, (x_in,), check_trace=False)


def convert(precision):
    mlm = ct.convert(traced, inputs=[ct.TensorType(name="x", shape=x_in.shape, dtype=np.float32)],
                     outputs=[ct.TensorType(name="mask", dtype=np.float32)], convert_to="mlprogram",
                     minimum_deployment_target=ct.target.macOS13, compute_precision=precision)
    mlm.short_description = "Mel-Band RoFormer per AudioLR: separa la voce"
    mlm.license = "Codice MIT (BS-RoFormer, audio-separator); pesi: vedi l'autore del modello"
    mlm.user_defined_metadata["kind"] = "melroformer"
    mlm.user_defined_metadata["sources"] = ",".join(STEMS)

    def core_ml(x):
        return mlm.predict({"x": x})["mask"]

    return mlm, snr(ref, pipeline_np(core_ml, mix.astype(np.float64)))


mlm, q16 = convert(ct.precision.FLOAT16)
print(f"Core ML 16 bit / RoFormer: {q16:.1f} dB")
precision, qbest = "16", q16
if q16 < 30:
    mlm, q32 = convert(ct.precision.FLOAT32)
    print(f"Core ML 32 bit / RoFormer: {q32:.1f} dB")
    assert q32 > 40, "conversione non fedele"
    precision, qbest = "32", q32
mlm.save(OUT + ".mlpackage")
json.dump({"kind": "melroformer", "sources": STEMS, "samplerate": sr, "n_fft": N, "hop": HOP, "chunk": CHUNK,
           "frames": T, "freq_indices": FI.tolist(), "num_bands_per_freq": NB.tolist(), "precision": precision,
           "db": round(qbest, 1)}, open(OUT + ".json", "w"))
# Prova di fedeltà per l'app (EndToEndTests): un pezzo e la voce secondo il modello originale
with open(OUT + "-prova.f32", "wb") as f:
    np.array([CHUNK, 1], dtype="<f4").tofile(f)
    mix.astype("<f4").tofile(f)
    ref.astype("<f4").tofile(f)
print("Fatto:", OUT, precision, round(qbest, 1))
