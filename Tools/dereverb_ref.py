"""«Togli riverbero»: il calcolo di IsoLR (nessun modello, nessuna licenza di terzi), in numpy.

È il riferimento che il Mac (Swift) e Windows (JavaScript) rifanno uguale. L'idea (coda tardiva di Lebart e altri,
2001, con una porta sul decadimento): in ogni riga dello spettro, l'energia che si spiega come la coda di quella
di 116 ms prima, smorzata come in una stanza (T60), è riverbero e si abbassa; dove l'energia è più alta di così
(una nota che parte o che resta tenuta) si lascia passare. Il guadagno è lo stesso per i due canali (stessa
immagine stereo), con un minimo (FLOOR) per non scavare buchi.
"""
import numpy as np

SR = 44100
N, H = 2048, 512
DELAY = 10                # fotogrammi: circa 116 ms; una nota tenuta resta più alta della sua coda attesa
T60 = 2.0                 # secondi: una sala grande; le code più corte si tolgono comunque
R0, R1 = 1.3, 2.2         # rapporto energia / coda attesa: sotto R0 è riverbero, sopra R1 è suono diretto
FLOOR_DB = -18.0
FW, SMOOTH = 3, 0.85


def window():
    n = np.arange(N)
    return (0.5 - 0.5 * np.cos(2 * np.pi * n / N)).astype(np.float32)


WIN = window()
NORM = float(np.sum(WIN ** 2) / H)   # 1,5 con la sovrapposizione del 75%


def stft(x):
    t = (len(x) + N) // H + 1
    xp = np.zeros((t - 1) * H + N, np.float32)
    xp[N // 2:N // 2 + len(x)] = x
    return np.stack([np.fft.rfft(xp[i * H:i * H + N] * WIN) for i in range(t)]).astype(np.complex64)


def istft(spec, n):
    t = spec.shape[0]
    out = np.zeros((t - 1) * H + N, np.float32)
    for i in range(t):
        out[i * H:i * H + N] += np.fft.irfft(spec[i], N).astype(np.float32) * WIN
    return out[N // 2:N // 2 + n] / NORM


def decay():
    delta = 3 * np.log(10) / T60
    return float(np.exp(-2 * delta * DELAY * H / SR))


def gains(power):
    """power [T, F] (somma dei canali) → guadagno [T, F] in [floor, 1]."""
    t, f = power.shape
    # Media sulle righe vicine (±FW) e nel tempo (SMOOTH): la coda di una stanza è rumorosa riga per riga
    p = np.zeros_like(power)
    for i in range(f):
        a, b = max(0, i - FW), min(f, i + FW + 1)
        p[:, i] = power[:, a:b].sum(axis=1) / (b - a)
    for i in range(1, t):
        p[i] = SMOOTH * p[i - 1] + (1 - SMOOTH) * p[i]
    late = np.zeros_like(p)
    late[DELAY:] = decay() * p[:-DELAY]
    eps = 1e-10 + 1e-8 * float(p.mean())
    r = p / (late + eps)
    s = np.clip((r - R0) / (R1 - R0), 0, 1)
    s = s * s * (3 - 2 * s)
    floor = 10 ** (FLOOR_DB / 20)
    g = floor + (1 - floor) * s
    # Si apre subito (attacchi intatti), si chiude in due fotogrammi
    out = np.empty_like(g)
    prev = np.ones(f, np.float32)
    for i in range(t):
        prev = np.maximum(g[i], 0.5 * prev + 0.5 * g[i])
        out[i] = prev
    return out.astype(np.float32)


def dereverb(channels):
    """channels: lista di tracce float32 (1 o 2) a 44,1 kHz → stesse tracce senza la coda del riverbero."""
    n = len(channels[0])
    specs = [stft(np.asarray(c, np.float32)) for c in channels]
    power = sum(np.abs(s) ** 2 for s in specs)
    g = gains(power)
    return [istft(s * g, n) for s in specs]
