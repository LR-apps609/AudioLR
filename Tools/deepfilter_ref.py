"""«Togli rumore»: il calcolo intorno alla rete di DeepFilterNet3 (Hendrik Schröter, MIT o Apache 2.0), in numpy.

È il riferimento che IsoLR rifà uguale in Swift (Mac) e in JavaScript (Windows): finestra, spettro, caratteristiche
(bande ERB e spettro normalizzato), applicazione della maschera e del filtro profondo, ricostruzione. La rete
(codificatore e due decodificatori) è un modello Core ML / ONNX a pezzi fissi di FRAMES fotogrammi.
Rifatto dal codice di libDF (lib.rs, transforms.rs) e di df/deepfilternet3.py, multiframe.py; le prove in
convert_deepfilter.py lo confrontano con l'«enhance» originale.
"""
import math

import numpy as np

SR, FFT, HOP = 48000, 960, 480
BINS = FFT // 2 + 1
NB_ERB, NB_DF, ORDER, LOOK, CONV_LOOK = 32, 96, 5, 2, 2
# exp(-hop/sr/tau) con tau = 1 s, arrotondato come get_norm_alpha (3 cifre)
ALPHA = 0.99
# La rete gira a pezzi: FRAMES fotogrammi, di cui CTX all'inizio e alla fine solo come contesto
FRAMES, CTX = 700, 100


def erb_widths(sr=SR, fft=FFT, nb=NB_ERB, min_freqs=2):
    f2e = lambda f: 9.265 * math.log1p(f / (24.7 * 9.265))
    e2f = lambda e: 24.7 * 9.265 * (math.exp(e / 9.265) - 1.0)
    lo, hi = f2e(0.0), f2e(sr / 2)
    step, width = (hi - lo) / nb, sr / fft
    out, prev, over = [], 0, 0
    for i in range(1, nb + 1):
        fb = int(round(e2f(lo + i * step) / width))
        n = fb - prev - over
        if n < min_freqs:
            over, n = min_freqs - n, min_freqs
        else:
            over = 0
        out.append(n)
        prev = fb
    out[-1] += 1
    out[-1] -= sum(out) - (fft // 2 + 1)
    return out


WIDTHS = erb_widths()


def window():
    n = np.arange(FFT, dtype=np.float64)
    s = np.sin(0.5 * np.pi * (n + 0.5) / (FFT // 2))
    return np.sin(0.5 * np.pi * s * s).astype(np.float32)


WIN = window()


def analysis(x):
    """x mono float32 → spettro [T, BINS] complesso (come DFState.analysis, normalizzato 1/FFT·2·HOP/FFT)."""
    t = len(x) // HOP
    mem = np.zeros(FFT - HOP, np.float32)
    out = np.zeros((t, BINS), np.complex64)
    norm = 1.0 / (FFT * FFT / (2 * HOP))
    for i in range(t):
        fr = x[i * HOP:(i + 1) * HOP]
        buf = np.concatenate([mem * WIN[:FFT - HOP], fr * WIN[FFT - HOP:]])
        out[i] = np.fft.rfft(buf) * norm
        mem = fr.copy()
    return out


def synthesis(spec):
    t = spec.shape[0]
    out = np.zeros(t * HOP, np.float32)
    mem = np.zeros(FFT - HOP, np.float32)
    for i in range(t):
        x = np.fft.irfft(spec[i], FFT).astype(np.float32) * FFT * WIN
        out[i * HOP:(i + 1) * HOP] = x[:HOP] + mem
        mem = x[HOP:]
    return out


def features(spec):
    """Le due entrate della rete: bande ERB in dB normalizzate [T, 32], spettro basso normalizzato [T, 96] complesso."""
    t = spec.shape[0]
    p = (spec.real.astype(np.float32) ** 2 + spec.imag.astype(np.float32) ** 2)
    erb = np.zeros((t, NB_ERB), np.float32)
    a = 0
    for b, w in enumerate(WIDTHS):
        erb[:, b] = p[:, a:a + w].sum(axis=1) / w
        a += w
    erb = np.log10(erb + 1e-10) * 10
    s = np.linspace(-60, -90, NB_ERB).astype(np.float32)
    for i in range(t):
        s = erb[i] * (1 - ALPHA) + s * ALPHA
        erb[i] = (erb[i] - s) / 40
    low = spec[:, :NB_DF].copy()
    u = np.linspace(0.001, 0.0001, NB_DF).astype(np.float32)
    for i in range(t):
        u = np.abs(low[i]) * (1 - ALPHA) + u * ALPHA
        low[i] = low[i] / np.sqrt(u)
    return erb, low


def net_inputs(erb, low):
    """Come la rete li vuole: feat_erb [1, 1, T, 32], feat_spec [1, 2, T, 96]."""
    fe = erb[None, None].astype(np.float32)
    fs = np.stack([low.real, low.imag])[None].astype(np.float32)
    return fe, fs


def apply(spec, m, c):
    """La maschera sulle bande ERB per tutto lo spettro; sotto le 96 righe il filtro profondo (5 fotogrammi,
    2 nel futuro) sullo spettro originale. m [T, 32], c [T, 96, 10] (reale e immaginario alternati)."""
    t = spec.shape[0]
    g = np.repeat(m, WIDTHS, axis=1)
    out = spec * g
    pad = np.zeros((t + ORDER - 1, NB_DF), np.complex64)
    pad[ORDER - 1 - LOOK:ORDER - 1 - LOOK + t] = spec[:, :NB_DF]
    df = np.zeros((t, NB_DF), np.complex64)
    for n in range(ORDER):
        coef = c[:, :, 2 * n] + 1j * c[:, :, 2 * n + 1]
        df += pad[n:n + t] * coef
    out[:, :NB_DF] = df
    return out


def run_net(net, erb, low):
    """net(fe, fs) → (m [1,1,F,32], c [1,F,96,10]) su pezzi di FRAMES fotogrammi; si tiene il centro di ognuno."""
    t = erb.shape[0]
    core = FRAMES - 2 * CTX
    m = np.zeros((t, NB_ERB), np.float32)
    c = np.zeros((t, NB_DF, ORDER * 2), np.float32)
    s = 0
    while s < t:
        # All'inizio della traccia niente contesto finto: la rete parte da zero come sull'intera traccia
        # (gli zeri dopo la fine invece sono uguali a quelli che la rete vede comunque)
        a = max(0, s - CTX)
        fe = np.zeros((FRAMES, NB_ERB), np.float32)
        fl = np.zeros((FRAMES, NB_DF), np.complex64)
        lo, hi = max(a, 0), min(a + FRAMES, t)
        fe[lo - a:hi - a] = erb[lo:hi]
        fl[lo - a:hi - a] = low[lo:hi]
        mm, cc = net(*net_inputs(fe, fl))
        e = min(a + FRAMES - CTX, t)
        m[s:e] = np.asarray(mm).reshape(FRAMES, NB_ERB)[s - a:e - a]
        c[s:e] = np.asarray(cc).reshape(FRAMES, NB_DF, ORDER * 2)[s - a:e - a]
        s = e
    return m, c


def enhance(x, net):
    """Una traccia mono a 48 kHz → la stessa senza rumore, stessa lunghezza (ritardo compensato come enhance)."""
    n = len(x)
    xp = np.concatenate([x.astype(np.float32), np.zeros(FFT, np.float32)])
    spec = analysis(xp)
    erb, low = features(spec)
    m, c = run_net(net, erb, low)
    y = synthesis(apply(spec, m, c))
    d = FFT - HOP
    return y[d:d + n]
