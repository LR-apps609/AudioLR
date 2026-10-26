# Banco della voce maschile e femminile: duetti finti fatti con le voci separate di MUSDB18 (una voce
# di uomo più una di donna, stesso volume), poi i due modelli pubblici che le dividono:
#   • BS-RoFormer «Chorus Male-Female» di Sucial
#   • BS-RoFormer «Male-Female» di aufr33
# Uomo o donna si decide dall'altezza media della voce (sotto 165 Hz uomo, sopra 210 Hz donna).
#
#   python Tools/banco_duetti.py uscita.json
import sys, os, json, time, tempfile, itertools, re
import numpy as np, soundfile as sf, librosa

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import benchmark as B

OUT = sys.argv[1]
MODELS = ["model_chorus_bs_roformer_ep_267_sdr_24.1275.ckpt", "bs_roformer_male_female_by_aufr33_sdr_7.2889.ckpt"]


def pitch(v, rate):
    m = librosa.to_mono(v)
    f0, voiced, _ = librosa.pyin(m, fmin=65, fmax=1000, sr=rate, frame_length=2048)
    f = f0[voiced & ~np.isnan(f0)]
    return float(np.median(f)) if len(f) > 20 else 0.0


voices = []
for name, mix, rate, refs in B.tracks():
    v = refs["vocals"]
    if np.sqrt(np.mean(v ** 2)) < 0.01:
        continue
    p = pitch(v, rate)
    kind = "uomo" if 0 < p < 165 else "donna" if p > 210 else ""
    print(name, round(p), kind, flush=True)
    if kind:
        voices.append((name, kind, p, v))
men = [x for x in voices if x[1] == "uomo"]
women = [x for x in voices if x[1] == "donna"]
pairs = list(itertools.product(men, women))
rng = np.random.default_rng(7)
rng.shuffle(pairs)
pairs = pairs[:40]
print(len(men), "uomini,", len(women), "donne,", len(pairs), "duetti", flush=True)

from audio_separator.separator import Separator
res, tempi, nomi = {}, {}, {}
for model in MODELS:
    tmp = tempfile.mkdtemp()
    sep = Separator(output_dir=tmp, output_format="WAV", log_level=40)
    sep.load_model(model_filename=model)
    t0, dur = time.time(), 0.0
    for (mn, _, mp, mv), (wn, _, wp, wv) in pairs:
        n = min(mv.shape[1], wv.shape[1])
        a, b = mv[:, :n], wv[:, :n]
        b = b * (np.sqrt(np.mean(a ** 2)) / (np.sqrt(np.mean(b ** 2)) + 1e-9))
        mix = (a + b) * 0.5
        a, b = a * 0.5, b * 0.5
        d = tempfile.mkdtemp()
        sep.output_dir = d
        if getattr(sep, "model_instance", None) is not None:
            sep.model_instance.output_dir = d
        path = os.path.join(d, "duetto.wav")
        sf.write(path, mix.T, 44100, subtype="FLOAT")
        out = {}
        for f in sep.separate(path):
            f = f if os.path.isabs(f) else os.path.join(d, f)
            x, _ = sf.read(f, dtype="float32", always_2d=True)
            x = x.T[:, :n]
            x = np.pad(x, ((0, 0), (0, n - x.shape[1])))
            k = re.findall(r"\(([^)]+)\)", os.path.basename(f))
            out[(k[-1] if k else os.path.basename(f)).lower()] = x
        dur += n / 44100
        keys = sorted(out)
        nomi[model] = keys
        # Ogni uscita contro la voce di uomo e quella di donna: l'abbinamento migliore
        best = None
        for km, kw in itertools.permutations(keys, 2):
            s = (B.sdr(a, out[km]), B.sdr(b, out[kw]))
            if best is None or sum(s) > sum(best[0]):
                best = (s, km, kw)
        (sm, sw), km, kw = best
        base = (B.sdr(a, mix * 0.5 * 2 / 2), B.sdr(b, mix * 0.5 * 2 / 2))   # senza separare: metà del duetto
        res.setdefault(model, []).append({"uomo": mn, "donna": wn, "sdr_uomo": sm, "sdr_donna": sw,
                                          "uscita_uomo": km, "uscita_donna": kw, "base_uomo": base[0], "base_donna": base[1]})
        print(model[:30], mn[:20], wn[:20], round(sm, 2), round(sw, 2), km, kw, flush=True)
    tempi[model] = (time.time() - t0) / max(dur, 1)

json.dump({"risultati": res, "tempi": tempi, "uscite": nomi,
           "voci": [(n, k, p) for n, k, p, _ in voices]}, open(OUT, "w"), ensure_ascii=False)
