"""Le uscite attese di «Pulisci la voce» per le prove di Windows (node) e del Mac (XCTest), da denoise_ref e
dereverb_ref, con lo stesso ingresso deterministico.
Uso: python3 Tools/make_cleanup_fixtures.py windows/ui/core/test/fixtures
"""
import os
import sys

import numpy as np

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import dereverb_ref as D  # noqa: E402
import denoise_ref as Z  # noqa: E402


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


def phrases(n, sr, seed):
    """Note a pause (0,25 s sì, 0,25 s no) sopra un fruscio leggero: per Togli rumore."""
    s = seed
    out = np.zeros(n, np.float64)
    for i in range(n):
        s = (s * 1103515245 + 12345) % 2147483648
        noise = s / 2147483648 * 2 - 1
        t = i / sr
        out[i] = 0.3 * np.sin(2 * np.pi * 330 * t) * (t % 0.5 < 0.25) + 0.01 * noise
    return out.astype(np.float32)


def main():
    out = sys.argv[1]
    a, b = signal(22050, 44100, 11), signal(22050, 44100, 13)
    l, r = D.dereverb([a, b])
    np.concatenate([l, r]).astype("<f4").tofile(os.path.join(out, "dereverb.f32"))
    a, b = phrases(33075, 44100, 17), phrases(33075, 44100, 19)
    l2, r2 = Z.denoise([a, b])
    np.concatenate([l2, r2]).astype("<f4").tofile(os.path.join(out, "denoise.f32"))
    print("fatto", l[:4], l2[:4])


if __name__ == "__main__":
    main()
