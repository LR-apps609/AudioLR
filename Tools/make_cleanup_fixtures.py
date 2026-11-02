"""Le uscite attese di «Pulisci la voce» per le prove di Windows (node) e del Mac (XCTest), da deepfilter_ref e
dereverb_ref: stesso ingresso deterministico, una rete finta al posto di DeepFilterNet (si prova il calcolo intorno).
Uso: python3 Tools/make_cleanup_fixtures.py windows/ui/core/test/fixtures
"""
import os
import sys

import numpy as np

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import deepfilter_ref as R  # noqa: E402
import dereverb_ref as D  # noqa: E402


def signal(n, sr, seed):
    """Somma di toni e rumore da un generatore lineare congruente (uguale in JS e Swift)."""
    s = seed
    out = np.zeros(n, np.float64)
    for i in range(n):
        s = (s * 1103515245 + 12345) % 2147483648
        noise = s / 2147483648 * 2 - 1
        t = i / sr
        out[i] = 0.3 * np.sin(2 * np.pi * 220 * t) + 0.2 * np.sin(2 * np.pi * 1330 * t) * (t % 0.25 < 0.12) + 0.05 * noise
    return out.astype(np.float32)


def fake_net(fe, fs):
    """Una «rete» che dipende solo dal fotogramma: m = sigmoide(3·erb), coefficienti dallo spettro basso."""
    f = fe.shape[2]
    m = 1 / (1 + np.exp(-3 * fe))
    c = np.zeros((1, f, R.NB_DF, R.ORDER * 2), np.float32)
    for o in range(R.ORDER):
        c[0, :, :, 2 * o] = 0.1 * (o + 1) * fs[0, 0]
        c[0, :, :, 2 * o + 1] = 0.05 * fs[0, 1]
    return m.astype(np.float32), c


def main():
    out = sys.argv[1]
    R.FRAMES, R.CTX = 30, 5
    x = signal(19200, 48000, 7)
    y = R.enhance(x, fake_net)
    y.astype("<f4").tofile(os.path.join(out, "denoise-finta.f32"))
    a, b = signal(22050, 44100, 11), signal(22050, 44100, 13)
    l, r = D.dereverb([a, b])
    np.concatenate([l, r]).astype("<f4").tofile(os.path.join(out, "dereverb.f32"))
    print("fatto", y[:4], l[:4])


if __name__ == "__main__":
    main()
