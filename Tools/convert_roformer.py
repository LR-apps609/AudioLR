# Converte un modello RoFormer in Core ML per AudioLR: Mel-Band (ad es. la voce di Kimberley Jensen)
# o BS-RoFormer (ad es. «BS-Roformer-SW», sei strumenti: voce, batteria, basso, chitarra, piano, altro). Si esegue sul Mac di GitHub (workflow «Modello voce RoFormer»).
#
# Come per Demucs, nel modello Core ML c'è solo la rete. L'app fa il resto in Swift:
#   1. STFT di ogni canale (2048 punti, passo 441, finestra di Hann, come torch.stft non normalizzata)
#   2. raccolta delle frequenze delle bande mel (freq_indices) → ingresso «x» (1, T, Fsel·2)
#      (per BS-RoFormer le bande sono contigue e senza sovrapposizioni: tutte le frequenze in ordine)
#   3. il modello restituisce le maschere «mask» (1, S, T, Fsel·2), una per strumento (reale/immaginaria alternate)
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
from roformer.bs_roformer import BSRoformer

CKPT, CFG, OUT = sys.argv[1], sys.argv[2], sys.argv[3]
CHUNK = int(sys.argv[4]) if len(sys.argv) > 4 else 352800        # 8 s, come nell'addestramento del modello


class Loader(yaml.SafeLoader):
    pass


Loader.add_constructor("tag:yaml.org,2002:python/tuple", lambda l, n: tuple(l.construct_sequence(n)))
cfg = yaml.load(open(CFG), Loader=Loader)
mc = dict(cfg["model"])
BS = "freqs_per_bands" in mc
KIND = "bsroformer" if BS else "melroformer"
m = (BSRoformer if BS else MelBandRoformer)(**mc).eval()
state = torch.load(CKPT, map_location="cpu")
if isinstance(state, dict) and "state_dict" in state:
    state = state["state_dict"]
missing, unexpected = m.load_state_dict(state, strict=False)
print("pesi mancanti:", missing[:5], "inattesi:", unexpected[:5])
assert not missing, "il file dei pesi non corrisponde al modello"

N, HOP = mc.get("stft_n_fft", 2048), mc.get("stft_hop_length", 441)
assert mc.get("stft_win_length", N) == N and not mc.get("stft_normalized", False)
T = CHUNK // HOP + 1
if BS:
    # Tutte le frequenze, in ordine (f·2 + canale), ognuna in una banda sola
    FI = np.arange((N // 2 + 1) * 2, dtype=np.int64)
    NB = np.ones(N // 2 + 1)
else:
    FI = m.freq_indices.numpy().astype(np.int64)                  # indici in (f·2 + canale)
    NB = m.num_bands_per_freq.numpy().astype(np.float64)          # bande che coprono ogni frequenza
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
        for block in m.layers:
            if len(block) == 3:
                linear, time_transformer, freq_transformer = block
                b, t, f, d = x.shape
                x = linear(x.reshape(b, t * f, d)).reshape(b, t, f, d)
            else:
                time_transformer, freq_transformer = block
            b, t, f, d = x.shape
            x = x.permute(0, 2, 1, 3).reshape(b * f, t, d)
            x = time_transformer(x)
            x = x.reshape(b, f, t, d).permute(0, 2, 1, 3).reshape(b * t, f, d)
            x = freq_transformer(x)
            x = x.reshape(b, t, f, d)
        if hasattr(m, "final_norm"):
            x = m.final_norm(x)
        return torch.stack([fn(x) for fn in m.mask_estimators], dim=1)   # (b, n, t, fsel·2)


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
    """Un pezzo (2, CHUNK) come lo lavora l'app → strumenti (S, 2, CHUNK)."""
    z = [stft_np(mix[c]) for c in range(2)]
    F = N // 2 + 1
    full = np.empty((F * 2, T), dtype=np.complex128)            # (f·2 + canale, t)
    full[0::2], full[1::2] = z[0], z[1]
    sel = full[FI]                                               # (fsel, t)
    x = np.stack([sel.real, sel.imag], -1).transpose(1, 0, 2).reshape(1, T, FSEL * 2)
    masks = core_fn(x.astype(np.float32))[0].astype(np.float64).reshape(-1, T, FSEL, 2)
    out = []
    for mask in masks:
        mc_ = mask[..., 0] + 1j * mask[..., 1]                   # (t, fsel)
        summed = np.zeros((F * 2, T), dtype=np.complex128)
        np.add.at(summed, FI, mc_.T)
        denom = np.repeat(NB, 2)[:, None]
        est = full * summed / np.maximum(denom, 1e-8)
        out.append(np.stack([istft_np(est[c::2], mix.shape[1]) for c in range(2)]))
    return np.stack(out)


def snr(ref, est):
    return 10 * math.log10(np.sum(ref ** 2) / max(np.sum((ref - est) ** 2), 1e-20))


# Una «canzone» di prova con una voce che il modello riconosce: una «a» cantata (impulsi glottali filtrati
# dalle formanti, con vibrato, due note) sopra basso e accordi. Senza voce vera il riferimento sarebbe quasi
# silenzio, e il confronto non direbbe niente.
from scipy.signal import lfilter
sr = 44100
t = np.arange(CHUNK) / sr
f0 = 220 * (1 + 0.03 * np.sin(2 * np.pi * 5.5 * t)) * np.where((t % 1.0) < 0.5, 1.0, 1.26)
ph = 2 * np.pi * np.cumsum(f0) / sr
voice = sum(np.sin(k * ph) / k for k in range(1, 40))
for F, B in [(700, 110), (1220, 120), (2600, 160)]:
    r, th = np.exp(-np.pi * B / sr), 2 * np.pi * F / sr
    voice = lfilter([1 - r], [1, -2 * r * np.cos(th), r * r], voice)
voice = 0.25 * voice / np.abs(voice).max() * np.clip(np.sin(np.pi * (t % 1.0) / 0.9), 0, 1) ** 0.3
acc = 0.15 * np.sin(2 * np.pi * 110 * t) + 0.1 * np.sin(2 * np.pi * 165 * t) + 0.06 * np.sin(2 * np.pi * 330 * t)
# Un filo di fruscio (−60 dB) come in ogni registrazione vera: senza, le bande alte sono silenzio digitale,
# e lì i modelli BS-RoFormer amplificano anche gli arrotondamenti (il confronto non direbbe niente)
hiss = 0.001 * np.random.default_rng(0).standard_normal((2, CHUNK))
sig = np.stack([voice + acc, voice + 0.8 * acc]) + hiss
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
ref = ref.reshape(-1, 2, CHUNK)                                 # (S, 2, CHUNK)
VI = STEMS.index("vocals") if "vocals" in STEMS else 0
for k, name in enumerate(STEMS):
    print(f"{name} stimata / canzone (energia): {np.sum(ref[k] ** 2) / np.sum(mix.astype(np.float64) ** 2):.3f}")
# Il modello voce deve trovare la voce; uno a più strumenti può metterla dove vuole (SW la mette in «other»),
# ma il confronto qui sotto è su tutti gli strumenti insieme, quindi basta che non sia silenzio
loud = ref[VI] if len(STEMS) == 1 else ref
assert np.sum(loud ** 2) > 0.05 * np.sum(mix.astype(np.float64) ** 2), "il modello non trova la voce di prova"


def core_torch(x):
    with torch.no_grad():
        return core(torch.from_numpy(x)).numpy()


q = snr(ref, pipeline_np(core_torch, mix.astype(np.float64)))
print(f"RoFormer diviso / intero: {q:.1f} dB")
if os.environ.get("SOLO_TORCH"):
    sys.exit(0)
assert q > 45, "dividere il modello cambia il risultato"

# 3. Core ML
x_in = torch.randn(1, T, FSEL * 2)
# Senza gradienti: PyTorch non tiene da parte i dati per l'addestramento, e la memoria resta bassa
# (con i gradienti, 2 s di pezzo chiedevano 8 GB; senza, 8 s ne chiedono meno di 5)
for p_ in core.parameters():
    p_.requires_grad_(False)
with torch.no_grad():
    traced = torch.jit.trace(core, (x_in,), check_trace=False)


def convert(precision):
    mlm = ct.convert(traced, inputs=[ct.TensorType(name="x", shape=x_in.shape, dtype=np.float32)],
                     outputs=[ct.TensorType(name="mask", dtype=np.float32)], convert_to="mlprogram",
                     minimum_deployment_target=ct.target.macOS13, compute_precision=precision)
    mlm.short_description = ("BS-RoFormer" if BS else "Mel-Band RoFormer") + " per AudioLR: " + ", ".join(STEMS)
    mlm.license = "Codice MIT (BS-RoFormer, audio-separator); pesi: vedi l'autore del modello"
    mlm.user_defined_metadata["kind"] = KIND
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
# Pesi a 8 bit: metà dello spazio da scaricare (circa 230 MB invece di 450). Si tiene solo se resta fedele.
try:
    import coremltools.optimize.coreml as cto
    cfg8 = cto.OptimizationConfig(global_config=cto.OpLinearQuantizerConfig(mode="linear_symmetric", weight_threshold=2048))
    mlm8 = cto.linear_quantize_weights(mlm, config=cfg8)
    q8 = snr(ref, pipeline_np(lambda x: mlm8.predict({"x": x})["mask"], mix.astype(np.float64)))
    print(f"Core ML pesi a 8 bit / RoFormer: {q8:.1f} dB")
    if q8 >= 30:
        mlm, precision, qbest = mlm8, precision + "+w8", q8
except Exception as e:
    print("pesi a 8 bit non riusciti:", e)
mlm.save(OUT + ".mlpackage")
json.dump({"kind": KIND, "sources": STEMS, "samplerate": sr, "n_fft": N, "hop": HOP, "chunk": CHUNK,
           "frames": T, "freq_indices": FI.tolist(), "num_bands_per_freq": NB.tolist(), "precision": precision,
           "db": round(qbest, 1)}, open(OUT + ".json", "w"))
# Prova di fedeltà per l'app (VoiceTests): un pezzo e gli strumenti secondo il modello originale
# [campioni, strumenti] · canzone (2 canali) · strumento 1 (2 canali) · strumento 2 …
with open(OUT + "-prova.f32", "wb") as f:
    np.array([CHUNK, len(STEMS)], dtype="<f4").tofile(f)
    mix.astype("<f4").tofile(f)
    ref.astype("<f4").tofile(f)
print("Fatto:", OUT, precision, round(qbest, 1))
