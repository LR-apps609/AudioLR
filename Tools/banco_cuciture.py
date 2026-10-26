# Banco delle cuciture: come l'app taglia la canzone in pezzi e li ricuce (VoiceRoFormer.stitch), con
# varianti: più sovrapposizione, bordi della canzone imbottiti a specchio, pezzi della misura di addestramento.
# Le canzoni di prova di MUSDB18 durano 7 s (meno di un pezzo): qui si uniscono a gruppi di 5 (~35 s),
# così le cuciture e i bordi contano davvero. Misure: SDR per traccia e «fantasma» (quanta voce stimata
# c'è dove la voce vera tace, in dB rispetto alla canzone).
#
#   SHARD=0/10 python Tools/banco_cuciture.py uscita.json
import sys, os, json, time, urllib.request
import numpy as np, torch, yaml

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import benchmark as B
from roformer.bs_roformer import BSRoformer
from roformer.mel_band_roformer import MelBandRoformer

OUT = sys.argv[1]
shard, shards = (int(x) for x in os.environ.get("SHARD", "0/1").split("/"))
BASE = "https://github.com/nomadkaraoke/python-audio-separator/releases/download/model-configs/"
MODELS = {
    "revive": ("bs_roformer_vocals_revive_v3e_unwa.ckpt", "config_bs_roformer_vocals_revive_unwa.yaml"),
    "kim": ("vocals_mel_band_roformer.ckpt", "vocals_mel_band_roformer.yaml"),
    "SW": ("BS-Roformer-SW.ckpt", "BS-Roformer-SW.yaml"),
}
# Varianti: (pezzo in campioni, sovrapposizione, bordi imbottiti)
VARIANTI = {
    "app (8 s, ×2)": (352800, 2, False),
    "×4": (352800, 4, False),
    "bordi": (352800, 2, True),
    "×4+bordi": (352800, 4, True),
    "11 s ×4+bordi": (485100, 4, True),
}
PER_MODELLO = {"revive": list(VARIANTI), "kim": ["app (8 s, ×2)", "×4+bordi"], "SW": ["app (8 s, ×2)", "×4", "bordi", "×4+bordi"]}
torch.set_num_threads(os.cpu_count() or 4)


def load(name):
    ck, cf = MODELS[name]
    for f in (ck, cf):
        if not os.path.exists("/tmp/" + f):
            urllib.request.urlretrieve(BASE + f, "/tmp/" + f)

    class L(yaml.SafeLoader):
        pass
    L.add_constructor("tag:yaml.org,2002:python/tuple", lambda l, n: tuple(l.construct_sequence(n)))
    cfg = yaml.load(open("/tmp/" + cf), Loader=L)
    mc = dict(cfg["model"])
    m = (BSRoformer if "freqs_per_bands" in mc else MelBandRoformer)(**mc).eval()
    st = torch.load("/tmp/" + ck, map_location="cpu")
    if isinstance(st, dict) and "state_dict" in st:
        st = st["state_dict"]
    m.load_state_dict(st, strict=False)
    if hasattr(m, "match_input_audio_length"):
        m.match_input_audio_length = True
    stems = list(cfg["training"]["instruments"]) if not cfg["training"].get("target_instrument") else [cfg["training"]["target_instrument"]]
    return m, [s.lower() for s in stems]


def stitch(m, mix, chunk, overlap, pad):
    """Come VoiceRoFormer.stitch: pezzi da `chunk`, passo chunk/overlap, finestra di Hamming, media pesata.
    Con `pad` la canzone si allunga a specchio di (chunk − passo) per lato: anche inizio e fine
    finiscono al centro di più pezzi (come audio-separator)."""
    n0 = mix.shape[1]
    step = max(1, int(round(chunk / overlap)))
    border = chunk - step if pad else 0
    if border:
        mode = "reflect" if n0 > 2 * border else "constant"
        mix = np.pad(mix, ((0, 0), (border, border)), mode=mode)
    n = mix.shape[1]
    w = np.hamming(chunk).astype(np.float32)
    out, count = None, np.zeros(n, np.float32)
    for start in range(0, n, step):
        ln = min(chunk, n - start)
        piece = np.zeros((2, chunk), np.float32)
        piece[:, :ln] = mix[:, start:start + ln]
        with torch.no_grad():
            v = m(torch.from_numpy(piece)[None]).numpy()
        v = v.reshape(-1, 2, v.shape[-1])[:, :, :chunk]
        if v.shape[-1] < chunk:
            v = np.pad(v, ((0, 0), (0, 0), (0, chunk - v.shape[-1])))
        if out is None:
            out = np.zeros((v.shape[0], 2, n), np.float32)
        out[:, :, start:start + ln] += v[:, :, :ln] * w[:ln]
        count[start:start + ln] += w[:ln]
        if start + chunk >= n:
            break
    out /= np.maximum(count, 1e-10)
    return out[:, :, border:border + n0]


def ghost(est, ref, mix, hop=4410):
    """Voce stimata dove la voce vera tace (sotto −45 dB rispetto alla canzone), in dB rispetto alla canzone."""
    n = (ref.shape[1] // hop) * hop
    f = lambda a: np.sqrt((a[:, :n].reshape(2, -1, hop) ** 2).mean(axis=(0, 2))) + 1e-9
    r, e, x = f(ref), f(est), f(mix)
    quiet = r / x < 10 ** (-45 / 20)
    if quiet.sum() < 5:
        return None
    return round(float(20 * np.log10(np.sqrt((e[quiet] ** 2).mean()) / np.sqrt((x[quiet] ** 2).mean()))), 2)


tracks = list(B.tracks())
groups = [tracks[i:i + 5] for i in range(0, len(tracks), 5)]
results, tempi = {}, {}
mine = [g for i, g in enumerate(groups) if i % shards == shard]
for name in PER_MODELLO:
    m, stems = load(name)
    for g in mine:
        key = " + ".join(t[0].split(" - ")[0] for t in g)
        mix = np.concatenate([t[1] for t in g], axis=1)
        refs = {s: np.concatenate([t[3][s] for t in g], axis=1) for s in ["vocals", "drums", "bass", "other"]}
        row = results.setdefault(key, {})
        for var in PER_MODELLO[name]:
            chunk, ov, pad = VARIANTI[var]
            t0 = time.time()
            est = stitch(m, mix, chunk, ov, pad)
            tempi[f"{name} {var}"] = round((time.time() - t0) / (mix.shape[1] / 44100), 2)
            parts = dict(zip(stems, est))
            if "vocals" in parts:
                row[f"vocals:{name} {var}"] = round(B.sdr(refs["vocals"], parts["vocals"]), 2)
                row[f"fantasma:{name} {var}"] = ghost(parts["vocals"], refs["vocals"], mix)
            if name == "SW":
                rest = sum(parts[s] for s in ("other", "guitar", "piano") if s in parts)
                for s, e in (("drums", parts["drums"]), ("bass", parts["bass"]), ("other", rest)):
                    row[f"{s}:SW {var}"] = round(B.sdr(refs[s], e), 2)
            print(key, name, var, {k: v for k, v in row.items() if f"{name} {var}" in k}, flush=True)
    del m
json.dump({"shard": shard, "tempi": tempi, "canzoni": results}, open(OUT, "w"), ensure_ascii=False)
