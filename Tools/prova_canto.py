"""«Pulisci la voce» su voci cantate vere: le voci isolate di 5 canzoni di prova di MUSDB18-HQ (solo misura, non si
pubblica niente). Togli rumore (DeepFilterNet3 originale, a pezzi come IsoLR) su:
  a) la voce di studio pulita: quanto ne resta (una voce senza rumore non deve sparire)
  b) la stessa voce con rumore rosa a 10 dB: quanto migliora
Togli riverbero (dereverb_ref) sulla voce pulita: quanto cambia il livello mentre canta.
Uso: python Tools/prova_canto.py <cartella DeepFilterNet3>
"""
import os
import sys

import numpy as np
import torch
from scipy.signal import resample_poly

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import deepfilter_ref as R  # noqa: E402
import dereverb_ref as D  # noqa: E402
import denoise_ref as Z  # noqa: E402
from convert_deepfilter import Net, snr  # noqa: E402
from df.enhance import init_df  # noqa: E402

ZIP = "https://zenodo.org/records/3338373/files/musdb18hq.zip?download=1"
SONGS = ["Al James - Schoolboy Facination", "Ben Carrigan - We'll Talk About It All Tonight", "BKS - Bulldozer",
         "Cristina Vane - So Easy", "Forkupines - Semantics"]


def level(x, mask):
    return 10 * np.log10(np.mean(x[mask] ** 2) + 1e-20)


def main():
    import io

    import soundfile as sf
    from remotezip import RemoteZip
    model, _, *_ = init_df(model_base_dir=sys.argv[1], post_filter=False, log_level="ERROR")
    net = Net(model).eval()

    def run(fe, fs):
        with torch.no_grad():
            m, c = net(torch.from_numpy(fe), torch.from_numpy(fs))
        return m.numpy(), c.numpy()

    z = RemoteZip(ZIP)
    rows, isolr = [], []
    for name in SONGS:
        try:
            v, sr = sf.read(io.BytesIO(z.read(f"test/{name}/vocals.wav")), dtype="float32")
        except Exception as e:  # noqa: BLE001
            print(f"{name}: non letta ({e})")
            continue
        mono = v.mean(axis=1)
        mid = len(mono) // 2
        x44 = mono[mid - 15 * sr:mid + 15 * sr]
        x = resample_poly(x44, 160, 147).astype(np.float32)
        # Dove canta: 50 ms sopra −40 dB dal massimo
        env = np.sqrt(np.convolve(x ** 2, np.ones(2400) / 2400, "same"))
        sing = env > env.max() * 10 ** (-40 / 20)
        y = R.enhance(x, run)
        keep = level(y, sing) - level(x, sing)
        rng = np.random.default_rng(0)
        pink = np.fft.irfft(np.fft.rfft(rng.standard_normal(len(x))) / np.sqrt(np.maximum(np.arange(len(x) // 2 + 1), 1)), len(x))
        pink *= np.sqrt(np.mean(x[sing] ** 2) / np.mean(pink ** 2)) / 10 ** (10 / 20)
        noisy = (x + pink).astype(np.float32)
        yn = R.enhance(noisy, run)
        dr = D.dereverb([x44.astype(np.float32)])[0]
        s44 = resample_poly(sing.astype(float), 147, 160) > 0.5
        n44 = min(len(s44), len(dr))
        drk = level(dr[:n44], s44[:n44]) - level(x44[:n44], s44[:n44])
        line = (f"{name}: voce pulita {keep:+.1f} dB (SNR {snr(x, y):.1f} dB) · con rumore a 10 dB: {snr(x, noisy):.1f} → "
                f"{snr(x, yn):.1f} dB · riverbero: voce {drk:+.1f} dB")
        print(line)
        # Con un limite all'abbassamento (come atten_lim di DeepFilterNet): uscita = lim·entrata + (1 − lim)·pulita
        lims = []
        for db in (18, 12, 9, 6):
            g = 10 ** (-db / 20)
            yl, ynl = g * x + (1 - g) * y, g * noisy + (1 - g) * yn
            lims.append((level(yl, sing) - level(x, sing), snr(x, yl), snr(x, ynl)))
        # Solo la maschera sulle bande (senza il filtro profondo sulle righe basse)
        full = R.apply
        R.apply = lambda spec, m, c: spec * np.repeat(m, R.WIDTHS, axis=1)
        ym, ynm = R.enhance(x, run), R.enhance(noisy, run)
        R.apply = full
        print(f"   solo maschera: voce {level(ym, sing) - level(x, sing):+.1f} dB (SNR {snr(x, ym):.1f}), rumore → {snr(x, ynm):.1f} dB")
        print("   limiti 18/12/9/6 dB: " + " | ".join(f"voce {a:+.1f} dB, SNR {b:.1f}, rumore → {c:.1f}" for a, b, c in lims))
        rows.append((keep, snr(x, noisy), snr(x, yn), drk) + tuple(v for t in lims for v in t))
        # Il calcolo di IsoLR (denoise_ref) a 44,1 kHz: voce pulita, e fruscio a 30 e a 20 dB (sopra 100 Hz)
        from scipy.signal import butter, sosfiltfilt
        hp = butter(4, 100, "hp", fs=44100, output="sos")
        x44f = x44.astype(np.float32)
        s44 = resample_poly(sing.astype(float), 147, 160)[:len(x44f)] > 0.5
        z0 = Z.denoise([x44f])[0]
        parts = [f"voce pulita {level(z0, s44) - level(x44f, s44):+.2f} dB (SNR {snr(x44f, z0):.1f})"]
        for db in (30, 20):
            w = sosfiltfilt(hp, np.random.default_rng(1).standard_normal(len(x44f)))
            w *= np.sqrt(np.mean(x44f[s44] ** 2) / np.mean(w ** 2)) / 10 ** (db / 20)
            nz = (x44f + w).astype(np.float32)
            zz = Z.denoise([nz])[0]
            parts.append(f"fruscio a {db} dB: {snr(x44f, nz):.1f} → {snr(x44f, zz):.1f} dB")
        print("   IsoLR Togli rumore: " + " · ".join(parts))
        isolr.append([level(z0, s44) - level(x44f, s44)] + [float(p.split("→ ")[1].split(" dB")[0]) - float(p.split(": ")[1].split(" →")[0]) for p in parts[1:]])
    if isolr:
        b = np.array(isolr)
        print(f"Media IsoLR Togli rumore su {len(isolr)} voci: voce pulita {b[:, 0].mean():+.2f} dB · fruscio a 30 dB "
              f"{b[:, 1].mean():+.1f} dB · a 20 dB {b[:, 2].mean():+.1f} dB")
    if rows:
        a = np.array(rows)
        print(f"Media su {len(rows)} voci: voce pulita {a[:, 0].mean():+.1f} dB · rumore {a[:, 1].mean():.1f} → {a[:, 2].mean():.1f} dB · "
              f"riverbero {a[:, 3].mean():+.1f} dB")
        for i, db in enumerate((18, 12, 9, 6)):
            k = 4 + 3 * i
            print(f"Media con limite {db} dB: voce pulita {a[:, k].mean():+.1f} dB (SNR {a[:, k + 1].mean():.1f}) · rumore "
                  f"{a[:, 1].mean():.1f} → {a[:, k + 2].mean():.1f} dB")


if __name__ == "__main__":
    main()
