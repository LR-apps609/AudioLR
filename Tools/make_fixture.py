# 0.2.0 · Prova di fedeltà: una canzone di prova separata da Demucs originale (PyTorch),
# con le stesse impostazioni dell'app (pezzi da 7,8 s sovrapposti di un quarto, senza «shift»).
# Il test EndToEndTests dell'app separa la stessa canzone con il modello Core ML scaricato
# e controlla che il risultato sia quasi identico.
#
# File HTDemucs-prova.f32 (float32, little-endian):
#   n, S                       (due numeri: campioni per canale e numero di strumenti)
#   canzone   2 × n            (sinistro, destro)
#   risultato S × 2 × n        (per ogni strumento, sinistro e destro; ordine di HTDemucs)
import sys, numpy as np, torch
from demucs.pretrained import get_model
from demucs.apply import apply_model

OUT = sys.argv[1] if len(sys.argv) > 1 else "HTDemucs-prova.f32"
bag = get_model("htdemucs")
SR = bag.samplerate
n = int(10 * SR)                  # due pezzi: uno intero e uno corto (prova anche la ricucitura)

# «Musica» di prova: accordi, basso, colpi di batteria, una voce che sale e scende
rng = np.random.default_rng(0)
t = np.arange(n) / SR
sig = np.zeros((2, n))
for f, pan in [(220, 0.3), (277.18, 0.5), (329.63, 0.7)]:
    sig[0] += 0.12 * (1 - pan) * np.sin(2 * np.pi * f * t)
    sig[1] += 0.12 * pan * np.sin(2 * np.pi * f * t)
sig += 0.2 * np.sin(2 * np.pi * 55 * t)
for k in range(0, n, SR // 2):
    m = min(4000, n - k)
    sig[:, k:k + m] += rng.standard_normal(m) * np.exp(-np.arange(m) / 600) * 0.4
sig += 0.15 * np.sin(2 * np.pi * (440 + 80 * np.sin(2 * np.pi * 0.5 * t)) * t) * (0.5 + 0.5 * np.sin(2 * np.pi * 0.25 * t))
mix = sig.astype(np.float32)

# Come demucs.separate: tutta la canzone a media 0 e deviazione 1, poi si torna alla scala originale
wav = torch.from_numpy(mix)
ref = wav.mean(0)
wav = (wav - ref.mean()) / ref.std()
with torch.no_grad():
    out = apply_model(bag, wav[None], shifts=0, split=True, overlap=0.25, progress=False)[0]
out = out * ref.std() + ref.mean()
S = out.shape[0]
print("strumenti:", bag.sources, "campioni:", n)

with open(OUT, "wb") as f:
    np.array([n, S], dtype="<f4").tofile(f)
    mix.astype("<f4").tofile(f)
    out.numpy().astype("<f4").tofile(f)
print("Fatto:", OUT)

# ── Prove per passaggi (HTDemucs-passi.f32), per trovare subito dove l'app si discosta ──
m = bag.models[0].eval()
L = int(m.segment * SR)
# 1. Spettrogramma e ritorno di un segnale corto
x = (0.3 * np.sin(2 * np.pi * 440 * np.arange(10000) / SR) + 0.05 * rng.standard_normal(10000)).astype(np.float32)
with torch.no_grad():
    z = m._spec(torch.from_numpy(x)[None, None])[0, 0]                     # (2048, T) complesso
    # Per l'inverso: uno spettro diverso da quello «giusto» (fase ruotata), così si prova davvero l'iSTFT
    z2 = z * torch.exp(1j * torch.linspace(0, 3, z.shape[0]))[:, None]
    back = m._ispec(z2[None, None], 10000)[0, 0]
# 2. Un pezzo intero (il primo della canzone, già normalizzato) passato a Demucs
piece = wav[:, :L]
with torch.no_grad():
    seg_out = m(piece[None])[0]                                             # (S, 2, L)
T = z.shape[1]
with open("HTDemucs-passi.f32", "wb") as f:
    np.array([10000, T, L, S], dtype="<f4").tofile(f)
    x.astype("<f4").tofile(f)
    z.real.numpy().astype("<f4").tofile(f); z.imag.numpy().astype("<f4").tofile(f)
    z2.real.numpy().astype("<f4").tofile(f); z2.imag.numpy().astype("<f4").tofile(f)
    back.numpy().astype("<f4").tofile(f)
    piece.numpy().astype("<f4").tofile(f)
    seg_out.numpy().astype("<f4").tofile(f)
print("Fatto: HTDemucs-passi.f32")

# ── «Massima qualità» (htdemucs_ft): 7 secondi della stessa canzone, separati dal sacchetto di 4 modelli ──
ft = get_model("htdemucs_ft")
nf = int(7 * SR)
wf = torch.from_numpy(mix[:, :nf].copy())
reff = wf.mean(0)
wf = (wf - reff.mean()) / reff.std()
with torch.no_grad():
    outf = apply_model(ft, wf[None], shifts=0, split=True, overlap=0.25, progress=False)[0]
outf = outf * reff.std() + reff.mean()
with open("HTDemucsFT-prova.f32", "wb") as f:
    np.array([nf, outf.shape[0]], dtype="<f4").tofile(f)
    mix[:, :nf].astype("<f4").tofile(f)
    outf.numpy().astype("<f4").tofile(f)
print("Fatto: HTDemucsFT-prova.f32")
