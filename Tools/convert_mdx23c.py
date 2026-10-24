# Converte un modello MDX23C (ad es. «DrumSep» di aufr33 e jarredou: cassa, rullante, tom, charleston,
# ride, crash) in Core ML per AudioLR. Si esegue sul Mac di GitHub (workflow «Modello batteria»).
#
# Come per gli altri modelli, nel modello Core ML c'è solo la rete. L'app fa il resto in Swift
# (Sources/DrumSplit.swift):
#   1. STFT di ogni canale (2048 punti, passo 512, finestra di Hann, come torch.stft non normalizzata)
#   2. le prime dim_f frequenze → ingresso «spec» (1, 4, dim_f, T): sinistro re/im, destro re/im
#   3. il modello restituisce gli spettri degli strumenti «spec_out» (1, S·4, dim_f, T), nello stesso ordine
#   4. frequenze mancanti a zero, iSTFT
#
#   python Tools/convert_mdx23c.py <file.ckpt> <config.yaml> <NomeUscita>
import sys, os, math, json, types
import numpy as np
import torch
import yaml
import coremltools as ct

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from mdx23c.tfc_tdf_v3 import TFC_TDF_net

CKPT, CFG, OUT = sys.argv[1], sys.argv[2], sys.argv[3]


class Loader(yaml.SafeLoader):
    pass


Loader.add_constructor("tag:yaml.org,2002:python/tuple", lambda l, n: tuple(l.construct_sequence(n)))


def ns(d):
    return types.SimpleNamespace(**{k: ns(v) if isinstance(v, dict) else v for k, v in d.items()})


raw = yaml.load(open(CFG), Loader=Loader)
cfg = ns(raw)
m = TFC_TDF_net(cfg, "cpu").eval()
state = torch.load(CKPT, map_location="cpu")
if isinstance(state, dict) and "state_dict" in state:
    state = state["state_dict"]
missing, unexpected = m.load_state_dict(state, strict=False)
print("pesi mancanti:", missing[:5], "inattesi:", unexpected[:5])
assert not missing, "il file dei pesi non corrisponde al modello"

N, HOP, DIM_F = cfg.audio.n_fft, cfg.audio.hop_length, cfg.audio.dim_f
T = cfg.audio.dim_t
CHUNK = HOP * (T - 1)
STEMS = list(cfg.training.instruments) if not cfg.training.target_instrument else [cfg.training.target_instrument]
S = len(STEMS)
print(f"{OUT}: {STEMS}, pezzo di {CHUNK} campioni ({CHUNK / 44100:.2f} s), spettro {DIM_F}×{T}")


class Core(torch.nn.Module):
    """TFC_TDF_net.forward senza STFT e iSTFT."""

    def __init__(self, m):
        super().__init__()
        self.m = m

    def forward(self, spec):
        m = self.m
        mix = x = m.cac2cws(spec)
        first_conv_out = x = m.first_conv(x)
        x = x.transpose(-1, -2)
        enc = []
        for block in m.encoder_blocks:
            x = block.tfc_tdf(x)
            enc.append(x)
            x = block.downscale(x)
        x = m.bottleneck_block(x)
        for block in m.decoder_blocks:
            x = block.upscale(x)
            x = torch.cat([x, enc.pop()], 1)
            x = block.tfc_tdf(x)
        x = x.transpose(-1, -2)
        x = x * first_conv_out
        x = m.final_conv(torch.cat([mix, x], 1))
        return m.cws2cac(x)                                       # (1, S·4, dim_f, T)


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
    z = [stft_np(mix[c])[:DIM_F] for c in range(2)]
    x = np.stack([z[0].real, z[0].imag, z[1].real, z[1].imag])[None].astype(np.float32)
    y = core_fn(x)[0].astype(np.float64).reshape(S, 4, DIM_F, T)
    out = []
    for k in range(S):
        st = []
        for c in range(2):
            full = np.zeros((N // 2 + 1, T), dtype=np.complex128)
            full[:DIM_F] = y[k, c * 2] + 1j * y[k, c * 2 + 1]
            st.append(istft_np(full, mix.shape[1]))
        out.append(np.stack(st))
    return np.stack(out)


def snr(ref, est):
    return 10 * math.log10(np.sum(ref ** 2) / max(np.sum((ref - est) ** 2), 1e-20))


# Una «batteria» di prova: cassa (seno che scende), rullante (rumore e tono), charleston (rumore acuto)
rng = np.random.default_rng(0)
sr = 44100
t = np.arange(CHUNK) / sr
kick, snare, hat = np.zeros(CHUNK), np.zeros(CHUNK), np.zeros(CHUNK)
beat = int(sr * 0.25)
for i, s0 in enumerate(range(0, CHUNK - beat, beat)):
    tt = np.arange(beat) / sr
    if i % 4 == 0:
        kick[s0:s0 + beat] += 0.8 * np.sin(2 * np.pi * (50 + 120 * np.exp(-tt * 30)) * tt) * np.exp(-tt * 12)
    if i % 4 == 2:
        snare[s0:s0 + beat] += (0.4 * rng.standard_normal(beat) + 0.3 * np.sin(2 * np.pi * 190 * tt)) * np.exp(-tt * 20)
    hp = np.diff(rng.standard_normal(beat + 1))
    hat[s0:s0 + beat] += 0.15 * hp * np.exp(-tt * 60)
drums = kick + snare + hat
mix = np.stack([drums, 0.9 * drums + 0.1 * hat]).astype(np.float32)

# 1. La STFT dell'app è quella di torch
with torch.no_grad():
    zt = torch.stft(torch.from_numpy(mix[0]), n_fft=N, hop_length=HOP, window=torch.hann_window(N), center=True,
                    return_complex=True).numpy()
e1 = np.abs(zt - stft_np(mix[0].astype(np.float64))).max() / np.abs(zt).max()
print(f"STFT app / torch: {e1:.2e}")
assert e1 < 1e-4

# 2. Il modello diviso (app + Core) dà lo stesso risultato del modello intero
core = Core(m).eval()
with torch.no_grad():
    ref = m(torch.from_numpy(mix)[None]).numpy()[0].astype(np.float64)    # (S, 2, CHUNK)
ref = ref.reshape(S, 2, -1)[..., :CHUNK]
for k, name in enumerate(STEMS):
    print(f"{name} stimata / batteria (energia): {np.sum(ref[k] ** 2) / np.sum(mix.astype(np.float64) ** 2):.3f}")
assert np.sum(ref ** 2) > 0.05 * np.sum(mix.astype(np.float64) ** 2), "il modello non trova la batteria di prova"


def core_torch(x):
    with torch.no_grad():
        return core(torch.from_numpy(x)).numpy()


q = snr(ref, pipeline_np(core_torch, mix.astype(np.float64)))
print(f"MDX23C diviso / intero: {q:.1f} dB")
assert q > 45, "dividere il modello cambia il risultato"
if os.environ.get("SOLO_TORCH"):
    sys.exit(0)

# 3. Core ML
x_in = torch.randn(1, 4, DIM_F, T)
for p_ in core.parameters():
    p_.requires_grad_(False)
with torch.no_grad():
    traced = torch.jit.trace(core, (x_in,), check_trace=False)


def convert(precision):
    mlm = ct.convert(traced, inputs=[ct.TensorType(name="spec", shape=x_in.shape, dtype=np.float32)],
                     outputs=[ct.TensorType(name="spec_out", dtype=np.float32)], convert_to="mlprogram",
                     minimum_deployment_target=ct.target.macOS13, compute_precision=precision)
    mlm.short_description = "MDX23C per AudioLR: " + ", ".join(STEMS)
    mlm.license = "Codice MIT (MDX23C, ZFTurbo, audio-separator); pesi: vedi gli autori del modello"
    mlm.user_defined_metadata["kind"] = "mdx23c"
    mlm.user_defined_metadata["sources"] = ",".join(STEMS)
    return mlm, snr(ref, pipeline_np(lambda x: mlm.predict({"spec": x})["spec_out"], mix.astype(np.float64)))


mlm, q16 = convert(ct.precision.FLOAT16)
print(f"Core ML 16 bit / MDX23C: {q16:.1f} dB")
precision, qbest = "16", q16
if q16 < 30:
    mlm, q32 = convert(ct.precision.FLOAT32)
    print(f"Core ML 32 bit / MDX23C: {q32:.1f} dB")
    assert q32 > 40, "conversione non fedele"
    precision, qbest = "32", q32
try:
    import coremltools.optimize.coreml as cto
    cfg8 = cto.OptimizationConfig(global_config=cto.OpLinearQuantizerConfig(mode="linear_symmetric", weight_threshold=2048))
    mlm8 = cto.linear_quantize_weights(mlm, config=cfg8)
    q8 = snr(ref, pipeline_np(lambda x: mlm8.predict({"spec": x})["spec_out"], mix.astype(np.float64)))
    print(f"Core ML pesi a 8 bit / MDX23C: {q8:.1f} dB")
    if q8 >= 30:
        mlm, precision, qbest = mlm8, precision + "+w8", q8
except Exception as e:
    print("pesi a 8 bit non riusciti:", e)
mlm.save(OUT + ".mlpackage")
json.dump({"kind": "mdx23c", "sources": STEMS, "samplerate": sr, "n_fft": N, "hop": HOP, "dim_f": DIM_F,
           "chunk": CHUNK, "frames": T, "precision": precision, "db": round(qbest, 1)}, open(OUT + ".json", "w"))
# [campioni, strumenti] · batteria (2 canali) · strumento 1 (2 canali) · strumento 2 …
with open(OUT + "-prova.f32", "wb") as f:
    np.array([CHUNK, S], dtype="<f4").tofile(f)
    mix.astype("<f4").tofile(f)
    ref.astype("<f4").tofile(f)
print("Fatto:", OUT, precision, round(qbest, 1))
