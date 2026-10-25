# Banco «al massimo»: tutti i modelli candidati, da soli e in squadra, sulle canzoni di prova di MUSDB18.
# Ogni modello si carica una volta e passa tutte le canzoni della sua parte, poi si cancella dal disco
# (sono decine di GB in tutto). Alla fine si misurano tutte le medie fino a 4 modelli per traccia,
# la «pulizia dei silenzi» e il tempo di ogni modello.
#
#   SHARD=0/10 python Tools/banco_massimo.py uscita.json
#
# Chiavi del risultato: «traccia:ricetta», per esempio «vocals:media(viperx,beta6x)».
import sys, os, json, time, shutil, itertools, gc
import numpy as np

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import benchmark as B

OUT = sys.argv[1]
shard, shards = (int(x) for x in os.environ.get("SHARD", "0/1").split("/"))
MAX_SQUADRA = int(os.environ.get("SQUADRA", "4"))

# Modelli voce (sulla canzone intera): nome breve → file del pacchetto audio-separator
VOCE = {
    "viperx": "model_bs_roformer_ep_317_sdr_12.9755.ckpt",
    "kim": "vocals_mel_band_roformer.ckpt",
    "SW": "BS-Roformer-SW.ckpt",
    "kimft": "mel_band_roformer_kim_ft_unwa.ckpt",
    "kimft2": "mel_band_roformer_kim_ft2_unwa.ckpt",
    "kimft3": "mel_band_roformer_kim_ft3_unwa.ckpt",
    "beta5e": "melband_roformer_big_beta5e.ckpt",
    "beta6": "melband_roformer_big_beta6.ckpt",
    "beta6x": "melband_roformer_big_beta6x.ckpt",
    "bigsyh": "MelBandRoformerBigSYHFTV1.ckpt",
    "becruily": "mel_band_roformer_vocals_becruily.ckpt",
    "fv4": "mel_band_roformer_vocals_fv4_gabox.ckpt",
    "bsgabox": "bs_roformer_vocals_gabox.ckpt",
    "resurr": "bs_roformer_vocals_resurrection_unwa.ckpt",
    "revive3e": "bs_roformer_vocals_revive_v3e_unwa.ckpt",
}
# Modelli fatti per la base (canzone senza voce)
BASE = {
    "i_becruily": "mel_band_roformer_instrumental_becruily.ckpt",
    "i_fv8": "mel_band_roformer_instrumental_fv8_gabox.ckpt",
    "i_v8": "mel_band_roformer_instrumental_instv8_gabox.ckpt",
    "i_resurr": "bs_roformer_instrumental_resurrection_unwa.ckpt",
}
STRUMENTI = ["drums", "bass", "other"]

songs = [t for i, t in enumerate(B.tracks()) if i % shards == shard]
est = {name: {} for name, *_ in songs}     # canzone → {«traccia:modello»: audio}
tempi = {}                                  # modello → secondi per secondo di musica


def libera():
    """Toglie i modelli dalla memoria e dal disco."""
    B._roformer.clear()
    B._demucs.clear()
    gc.collect()
    shutil.rmtree("/tmp/audio-separator-models", ignore_errors=True)


def misura(nome, fn):
    t0, durata = time.time(), 0.0
    for name, mix, rate, refs in songs:
        try:
            for k, a in fn(name, mix, rate).items():
                est[name][k] = a.astype(np.float32)
        except Exception as e:
            print(f"!! {nome} su {name}: {e}", flush=True)
        durata += mix.shape[1] / rate
    tempi[nome] = round((time.time() - t0) / max(durata, 1), 3)
    print(f"== {nome}: {tempi[nome]} s per secondo di musica", flush=True)
    libera()


def swap(x):
    return x[::-1].copy()


# 1. Voce: ogni modello sulla canzone intera (viperx anche con i canali scambiati, per la prova «due passate»)
for short, f in VOCE.items():
    def run(name, mix, rate, f=f, short=short):
        r = B.roformer(f, mix, rate)
        out = {"vocals:" + short: r["vocals"]}
        if short == "SW":
            for s in STRUMENTI:
                out[s + ":mix·SW"] = r[s]
        if short == "viperx":
            out["vocals:viperx~"] = swap(B.roformer(f, swap(mix), rate)["vocals"])
        return out
    misura(short, run)

# 2. Base: modelli dedicati
for short, f in BASE.items():
    misura(short, lambda name, mix, rate, f=f, short=short: {"instrumental:" + short: B.roformer(f, mix, rate)["instrumental"]})

# 3. Strumenti dalla base senza voce (la voce di Studio oggi: media di viperx e kim)
bases = {}
for name, mix, rate, refs in songs:
    v = est[name]
    if "vocals:viperx" in v and "vocals:kim" in v:
        bases[name] = (mix - 0.5 * (v["vocals:viperx"] + v["vocals:kim"])).astype(np.float32)


def on_base(fn):
    def run(name, mix, rate):
        return fn(bases[name], rate) if name in bases else {}
    return run


def sw_base(base, rate):
    r = B.roformer(VOCE["SW"], base, rate)
    s = B.roformer(VOCE["SW"], swap(base), rate)
    out = {}
    for k in STRUMENTI:
        out[k + ":SW"] = r[k]
        out[k + ":SW~"] = swap(s[k])
    return out


misura("SW (base, due passate)", on_base(sw_base))


def demucs_all(model):
    def fn(base, rate):
        import torch
        from demucs.pretrained import get_model
        from demucs.apply import apply_model
        if model not in B._demucs:
            B._demucs[model] = get_model(model).eval()
        bag = B._demucs[model]
        wav = torch.from_numpy(base)
        ref = wav.mean(0)
        wav = (wav - ref.mean()) / (ref.std() + 1e-8)
        with torch.no_grad():
            o = apply_model(bag, wav[None], split=True, overlap=0.25, progress=False)[0]
        o = (o * (ref.std() + 1e-8) + ref.mean()).numpy()
        src = list(bag.sources)
        other = sum(o[src.index(s)] for s in src if s in ("other", "guitar", "piano"))
        return {"drums:" + model: o[src.index("drums")], "bass:" + model: o[src.index("bass")], "other:" + model: other}
    return fn


for m in ["htdemucs_ft", "htdemucs", "hdemucs_mmi", "htdemucs_6s"]:
    misura(m, on_base(demucs_all(m)))

# ── Misure ─────────────────────────────────────────────────────────────────────────────────────


def gate(e, mix, soglia):
    """Pulizia dei silenzi: dove la traccia è molto più debole della canzone (fondo che filtra), si abbassa."""
    hop = 2048
    n = e.shape[1]
    frames = (n + hop - 1) // hop
    pe = np.pad(e, ((0, 0), (0, frames * hop - n))).reshape(2, frames, hop)
    pm = np.pad(mix, ((0, 0), (0, frames * hop - n))).reshape(2, frames, hop)
    re = np.sqrt((pe ** 2).mean(axis=(0, 2))) + 1e-9
    rm = np.sqrt((pm ** 2).mean(axis=(0, 2))) + 1e-9
    g = np.clip((re / rm - soglia) / soglia, 0, 1)            # 0 sotto la soglia, 1 al doppio
    g = np.convolve(g, np.ones(3) / 3, mode="same")              # niente scatti
    g = np.repeat(g, hop)[:n]
    return e * g


results = {}
for name, mix, rate, refs in songs:
    refs["instrumental"] = refs["drums"] + refs["bass"] + refs["other"]
    e = est[name]
    row = {}

    def put(key, a):
        stem = key.split(":", 1)[0]
        ref = refs[stem]
        if np.sum(ref ** 2) > 1e-6 and a is not None:
            row[key] = round(B.sdr(ref, a[:, :ref.shape[1]]), 2)

    # Voce: da soli e in squadra
    voci = {k.split(":", 1)[1]: a for k, a in e.items() if k.startswith("vocals:")}
    nomi = sorted(voci)
    for r in range(1, MAX_SQUADRA + 1):
        for combo in itertools.combinations(nomi, r):
            if "viperx~" in combo and "viperx" not in combo and r > 1:
                continue
            v = sum(voci[c] for c in combo) / r
            lab = combo[0] if r == 1 else "media(" + ",".join(combo) + ")"
            put("vocals:" + lab, v)
            put("instrumental:" + lab, mix - v)
    # Base: modelli dedicati, e in squadra con le basi «canzone meno voce» migliori
    basi = {k.split(":", 1)[1]: a for k, a in e.items() if k.startswith("instrumental:")}
    for c in ["viperx", "kim", "beta6x", "becruily", "resurr"]:
        if c in voci:
            basi["−" + c] = mix - voci[c]
    bn = sorted(basi)
    for r in range(1, 4):
        for combo in itertools.combinations(bn, r):
            lab = combo[0] if r == 1 else "media(" + ",".join(combo) + ")"
            put("instrumental:" + lab, sum(basi[c] for c in combo) / r)
    # Strumenti: da soli e in squadra (tutte le combinazioni)
    for s in STRUMENTI:
        st = {k.split(":", 1)[1]: a for k, a in e.items() if k.startswith(s + ":")}
        sn = sorted(st)
        for r in range(1, len(sn) + 1):
            for combo in itertools.combinations(sn, r):
                lab = combo[0] if r == 1 else "media(" + ",".join(combo) + ")"
                put(s + ":" + lab, sum(st[c] for c in combo) / r)
    # Pulizia dei silenzi sulle ricette di oggi
    oggi = {"vocals": voci.get("viperx") if "kim" not in voci else 0.5 * (voci["viperx"] + voci["kim"]),
            "drums": e.get("drums:SW"),
            "bass": None if "bass:SW" not in e or "bass:htdemucs_ft" not in e else 0.5 * (e["bass:SW"] + e["bass:htdemucs_ft"]),
            "other": e.get("other:SW")}
    for s, a in oggi.items():
        if a is None:
            continue
        put(f"{s}:OGGI", a)
        for th in (0.003, 0.01, 0.03):
            put(f"{s}:OGGI+silenzi{th}", gate(a, mix, th))
    results[name] = row
    print(name, len(row), "misure", flush=True)

json.dump({"shard": shard, "tempi": tempi, "canzoni": results}, open(OUT, "w"), ensure_ascii=False)
