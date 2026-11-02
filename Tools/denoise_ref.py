"""«Togli rumore»: il calcolo di IsoLR (nessun modello, nessuna licenza di terzi), in numpy.

DeepFilterNet3 (provato su 5 voci cantate di MUSDB18-HQ, Tools/prova_canto.py) toglie anche pezzi di voce
(fino a −5,6 dB su una voce pulita) e con il rumore peggiora in media: è fatto per il parlato. Qui invece un
«noise gate» spettrale come quello dei programmi audio: il profilo del rumore è la media delle righe dello spettro
nei momenti più silenziosi della traccia (il 10% dei fotogrammi con meno energia, dove la voce tace); ogni riga
si abbassa solo dove la sua energia non supera di molto quel profilo. Una voce sopra il rumore passa intatta.
Il Mac (Swift) e Windows (JavaScript) rifanno lo stesso calcolo; stessa finestra e stessa ricostruzione di
dereverb_ref.py.
"""
import numpy as np

import dereverb_ref as D

QUIET = 0.10          # la parte più silenziosa della traccia che fa da profilo del rumore
OVER = 2.0            # quanto sopra il profilo l'energia deve stare per passare intera
FLOOR_DB = -20.0      # di quanto si abbassa al massimo il rumore
FW, SMOOTH = 2, 0.6   # media sulle righe vicine e nel tempo prima di decidere
RELEASE = 0.7         # il guadagno risale subito e scende piano (niente «rumore musicale»)
SILENT = 0.05         # oltre il 5% di fotogrammi a zero: nessun rumore di fondo
TRUST_DB = (12.0, 20.0)  # distanza tra silenzio e parte forte: sotto 12 dB non si toglie niente, da 20 dB tutto


def gains(power):
    """power [T, F] (somma dei canali) → guadagno [T, F] in [floor, 1]."""
    t, f = power.shape
    # Il profilo: la media delle righe nei fotogrammi più silenziosi (energia totale)
    # (senza i fotogrammi dei bordi, mezzi vuoti, e senza il silenzio digitale)
    total = power.sum(axis=1)
    edge = D.N // D.H
    cand = np.arange(edge, max(edge + 1, t - edge))
    alive = cand[total[cand] > 1e-10 * max(float(total.max()), 1e-30)]
    # Tanti fotogrammi di silenzio digitale: la traccia non ha un rumore di fondo da togliere
    if len(alive) < (1 - SILENT) * len(cand) or len(alive) == 0:
        return np.ones_like(power)
    k = max(1, int(round(QUIET * len(alive))))
    order = np.argsort(total[alive], kind="stable")
    quiet = alive[order[:k]]
    noise = power[quiet].mean(axis=0) + 1e-12
    # Quanto il silenzio sta sotto la parte forte: se poco, i momenti «silenziosi» sono ancora voce e il
    # profilo non è affidabile; allora si toglie meno, fino a niente
    loud = float(np.percentile(total[alive], 90))
    span = 10 * np.log10(loud / max(float(total[quiet].mean()), 1e-30))
    trust = float(np.clip((span - TRUST_DB[0]) / (TRUST_DB[1] - TRUST_DB[0]), 0, 1))
    if trust == 0:
        return np.ones_like(power)
    p = np.zeros_like(power)
    for i in range(f):
        a, b = max(0, i - FW), min(f, i + FW + 1)
        p[:, i] = power[:, a:b].sum(axis=1) / (b - a)
    for i in range(1, t):
        p[i] = SMOOTH * p[i - 1] + (1 - SMOOTH) * p[i]
    floor = 1 - trust * (1 - 10 ** (FLOOR_DB / 20))
    # Sottrazione del rumore «alla Wiener», con OVER volte il profilo
    g = np.sqrt(np.clip(1 - OVER * noise / np.maximum(p, 1e-20), 0, 1))
    g = floor + (1 - floor) * g
    out = np.empty_like(g)
    prev = np.ones(f, np.float32)
    for i in range(t):
        prev = np.maximum(g[i], RELEASE * prev + (1 - RELEASE) * g[i])
        out[i] = prev
    return out.astype(np.float32)


def denoise(channels):
    """channels: lista di tracce float32 (1 o 2) a 44,1 kHz → stesse tracce con meno rumore di fondo."""
    n = len(channels[0])
    specs = [D.stft(np.asarray(c, np.float32)) for c in channels]
    power = sum(np.abs(s) ** 2 for s in specs).astype(np.float32)
    g = gains(power)
    return [D.istft(s * g, n) for s in specs]
