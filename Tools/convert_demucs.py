# 0.1.0 · Converte HTDemucs (Demucs v4, licenza MIT, Meta) in un modello Core ML per AudioLR.
# Si esegue sul Mac di GitHub (workflow «Modello Demucs»): scarica il modello, lo converte, lo prova.
#
# Nel modello Core ML c'è solo la rete neurale. Spettrogramma (STFT), spettrogramma inverso e
# normalizzazione li fa l'app (Sources/Spectrogram.swift, Sources/Separator.swift): Core ML non
# gestisce i numeri complessi. Qui sotto stft_np/istft_np sono la copia esatta di quello che fa l'app,
# e vengono confrontate con quelle di Demucs: se l'app e il modello non si capiscono, il workflow fallisce.
#
# Ingressi (già normalizzati: media 0, deviazione 1):
#   spec  (1, 4, 2048, T)   spettrogramma: sinistro reale, sinistro immaginario, destro reale, destro immaginario
#   wave  (1, 2, L)         onda: sinistro, destro
# Uscite (da riportare alla scala dell'ingresso):
#   spec_out (1, S*4, 2048, T)   per ogni strumento, come l'ingresso
#   wave_out (1, S*2, L)         per ogni strumento, sinistro e destro
# Il risultato di uno strumento è istft(spec_out) + wave_out.
import sys, math, json
import numpy as np
import torch
import coremltools as ct
from demucs.pretrained import get_model

NAME = sys.argv[1] if len(sys.argv) > 1 else "htdemucs"
OUT = sys.argv[2] if len(sys.argv) > 2 else "HTDemucs"

bag = get_model(NAME)
assert len(bag.models) == 1, "per ora solo modelli singoli (htdemucs, htdemucs_6s)"
m = bag.models[0].eval()
SR = m.samplerate
L = int(m.segment * SR)
HOP, NFFT = m.hop_length, m.nfft
LE = math.ceil(L / HOP)
SOURCES = list(m.sources)
S = len(SOURCES)
print(f"{NAME}: {SOURCES}, {SR} Hz, pezzo di {L} campioni ({L / SR:.2f} s), spettrogramma {NFFT // 2}×{LE}")

# Il «percorso veloce» dell'attenzione di PyTorch usa un'operazione che Core ML non conosce
try:
    torch.backends.mha.set_fastpath_enabled(False)
except Exception:
    pass


class Core(torch.nn.Module):
    """La parte centrale di HTDemucs.forward: tutto tranne STFT, iSTFT e normalizzazione."""

    def __init__(self, m):
        super().__init__()
        self.m = m

    def forward(self, spec, wave):
        m = self.m
        x, xt = spec, wave
        B, C, Fq, T = x.shape
        saved, saved_t, lengths, lengths_t = [], [], [], []
        for idx, encode in enumerate(m.encoder):
            lengths.append(x.shape[-1])
            inject = None
            if idx < len(m.tencoder):
                lengths_t.append(xt.shape[-1])
                tenc = m.tencoder[idx]
                xt = tenc(xt)
                if not tenc.empty:
                    saved_t.append(xt)
                else:
                    inject = xt
            x = encode(x, inject)
            if idx == 0 and m.freq_emb is not None:
                frs = torch.arange(x.shape[-2], device=x.device)
                emb = m.freq_emb(frs).t()[None, :, :, None].expand_as(x)
                x = x + m.freq_emb_scale * emb
            saved.append(x)
        if m.crosstransformer:
            if m.bottom_channels:
                b, c, f, t = x.shape
                x = x.reshape(b, c, f * t)
                x = m.channel_upsampler(x)
                x = x.reshape(b, -1, f, t)
                xt = m.channel_upsampler_t(xt)
            x, xt = m.crosstransformer(x, xt)
            if m.bottom_channels:
                b, c, f, t = x.shape
                x = x.reshape(b, c, f * t)
                x = m.channel_downsampler(x)
                x = x.reshape(b, -1, f, t)
                xt = m.channel_downsampler_t(xt)
        for idx, decode in enumerate(m.decoder):
            skip = saved.pop(-1)
            x, pre = decode(x, skip, lengths.pop(-1))
            offset = m.depth - len(m.tdecoder)
            if idx >= offset:
                tdec = m.tdecoder[idx - offset]
                length_t = lengths_t.pop(-1)
                if tdec.empty:
                    pre = pre[:, :, 0]
                    xt, _ = tdec(pre, None, length_t)
                else:
                    skip = saved_t.pop(-1)
                    xt, _ = tdec(xt, skip, length_t)
        x = x.reshape(B, S * C, Fq, T)
        xt = xt.reshape(B, S * 2, -1)
        return x, xt


# ── Copia di quello che fa l'app (Spectrogram.swift, Separator.swift) ──────────────────────────
WIN = (0.5 - 0.5 * np.cos(2 * np.pi * np.arange(NFFT) / NFFT)).astype(np.float64)


def stft_np(x):
    n = len(x)
    le = math.ceil(n / HOP)
    pad = HOP // 2 * 3
    a = np.pad(x, (pad, pad + le * HOP - n), mode="reflect")
    b = np.pad(a, (NFFT // 2, NFFT // 2), mode="reflect")
    out = np.empty((NFFT // 2, le), dtype=np.complex128)
    for j in range(le):
        s = (j + 2) * HOP
        out[:, j] = np.fft.fft(b[s:s + NFFT] * WIN)[:NFFT // 2] / math.sqrt(NFFT)
    return out


def istft_np(z, n):
    le = z.shape[1]
    pad = HOP // 2 * 3
    frames = le + 4
    total = NFFT + HOP * (frames - 1)
    buf, env = np.zeros(total), np.zeros(total)
    for t in range(frames):
        j = t - 2
        s = t * HOP
        if 0 <= j < le:
            full = np.zeros(NFFT // 2 + 1, dtype=np.complex128)
            full[:NFFT // 2] = z[:, j]
            buf[s:s + NFFT] += np.fft.irfft(full, n=NFFT) * math.sqrt(NFFT) * WIN
        env[s:s + NFFT] += WIN * WIN
    start = NFFT // 2 + pad
    e = env[start:start + n]
    return buf[start:start + n] / np.where(e > 1e-11, e, 1)


def separate_np(core_fn, mix):
    """Un pezzo come lo lavora l'app: mix (2, L) → (S, 2, L)."""
    z = [stft_np(mix[c]) for c in range(2)]
    x = np.stack([z[0].real, z[0].imag, z[1].real, z[1].imag])
    mean, std = x.mean(), x.std(ddof=1)
    xn = (x - mean) / (1e-5 + std)
    meant, stdt = mix.mean(), mix.std(ddof=1)
    xtn = (mix - meant) / (1e-5 + stdt)
    so, wo = core_fn(xn[None].astype(np.float32), xtn[None].astype(np.float32))
    so = so[0].astype(np.float64) * std + mean
    wo = wo[0].astype(np.float64) * stdt + meant
    out = np.zeros((S, 2, mix.shape[1]))
    for s in range(S):
        for c in range(2):
            k = s * 4 + c * 2
            out[s, c] = istft_np(so[k] + 1j * so[k + 1], mix.shape[1]) + wo[s * 2 + c]
    return out


def snr(ref, est):
    return 10 * math.log10(np.sum(ref ** 2) / max(np.sum((ref - est) ** 2), 1e-20))


# ── Un pezzo di «musica» di prova: accordi, basso, colpi di batteria, una voce che sale e scende ──
rng = np.random.default_rng(0)
t = np.arange(L) / SR
sig = np.zeros((2, L))
for f, pan in [(220, 0.3), (277.18, 0.5), (329.63, 0.7)]:
    sig[0] += 0.12 * (1 - pan) * np.sin(2 * np.pi * f * t)
    sig[1] += 0.12 * pan * np.sin(2 * np.pi * f * t)
sig += 0.2 * np.sin(2 * np.pi * 55 * t)
for k in range(0, L, SR // 2):
    n = min(4000, L - k)
    hit = rng.standard_normal(n) * np.exp(-np.arange(n) / 600) * 0.4
    sig[:, k:k + n] += hit
voice = 0.15 * np.sin(2 * np.pi * (440 + 80 * np.sin(2 * np.pi * 0.5 * t)) * t) * (0.5 + 0.5 * np.sin(2 * np.pi * 0.25 * t))
sig += voice
mix = sig.astype(np.float32)

# 1. Lo spettrogramma dell'app è identico a quello di Demucs
with torch.no_grad():
    zt = m._spec(torch.from_numpy(mix)[None]).numpy()[0]
zn = np.stack([stft_np(mix[c].astype(np.float64)) for c in range(2)])
e1 = np.abs(zt - zn).max() / np.abs(zt).max()
print(f"STFT app / Demucs: differenza relativa {e1:.2e}")
assert e1 < 1e-4, "la STFT dell'app non è uguale a quella di Demucs"

with torch.no_grad():
    back_t = m._ispec(torch.from_numpy(zt)[None], L).numpy()[0]
back_n = np.stack([istft_np(zn[c], L) for c in range(2)])
e2 = np.abs(back_t - back_n).max()
print(f"iSTFT app / Demucs: differenza massima {e2:.2e}; ricostruzione {snr(mix.astype(np.float64), back_n):.1f} dB")
assert e2 < 1e-4, "la iSTFT dell'app non è uguale a quella di Demucs"

# 2. Il modello diviso (app + Core) dà lo stesso risultato di Demucs intero
core = Core(m).eval()
with torch.no_grad():
    ref = m(torch.from_numpy(mix)[None]).numpy()[0].astype(np.float64)


def core_torch(xn, xtn):
    with torch.no_grad():
        a, b = core(torch.from_numpy(xn), torch.from_numpy(xtn))
    return a.numpy(), b.numpy()


split = separate_np(core_torch, mix.astype(np.float64))
q = snr(ref, split)
print(f"Demucs diviso / intero: {q:.1f} dB")
assert q > 60, "dividere il modello cambia il risultato"

# 3. Conversione in Core ML. Tracciato con i gradienti attivi: così PyTorch non usa il percorso veloce dell'attenzione.
spec_in = torch.randn(1, 4, NFFT // 2, LE)
wave_in = torch.randn(1, 2, L)
traced = torch.jit.trace(core, (spec_in, wave_in), check_trace=False)


def convert(precision):
    mlm = ct.convert(
        traced,
        inputs=[ct.TensorType(name="spec", shape=spec_in.shape, dtype=np.float32),
                ct.TensorType(name="wave", shape=wave_in.shape, dtype=np.float32)],
        outputs=[ct.TensorType(name="spec_out", dtype=np.float32), ct.TensorType(name="wave_out", dtype=np.float32)],
        convert_to="mlprogram",
        minimum_deployment_target=ct.target.macOS13,
        compute_precision=precision,
    )
    mlm.short_description = "Demucs v4 (HTDemucs) per AudioLR: separa voce, batteria, basso e altri strumenti"
    mlm.license = "MIT (Demucs, Meta Platforms)"
    mlm.user_defined_metadata["sources"] = ",".join(SOURCES)
    mlm.user_defined_metadata["samplerate"] = str(SR)
    mlm.user_defined_metadata["segment"] = str(L)
    mlm.user_defined_metadata["model"] = NAME

    def core_ml(xn, xtn):
        p = mlm.predict({"spec": xn, "wave": xtn})
        return p["spec_out"], p["wave_out"]

    q = snr(ref, separate_np(core_ml, mix.astype(np.float64)))
    return mlm, q


mlm, q16 = convert(ct.precision.FLOAT16)
print(f"Core ML 16 bit / Demucs: {q16:.1f} dB")
precision = "16"
if q16 < 30:
    print("16 bit non abbastanza fedele: provo a 32 bit")
    mlm, q32 = convert(ct.precision.FLOAT32)
    print(f"Core ML 32 bit / Demucs: {q32:.1f} dB")
    assert q32 > 40, "conversione non fedele"
    precision = "32"
mlm.save(OUT + ".mlpackage")
json.dump({"model": NAME, "sources": SOURCES, "samplerate": SR, "segment": L, "precision": precision},
          open(OUT + ".json", "w"), indent=1)
print("Fatto:", OUT + ".mlpackage")
