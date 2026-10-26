# Banco degli strumenti: modelli nuovi per batteria, basso e «altro» (SCNet XL IHF e BS-RoFormer a 4 strumenti
# di ZFTurbo), da soli e in squadra con quelli di Studio (SW sulla base e sulla canzone, Demucs, Demucs FT).
# Base = canzone meno la voce di Studio (media di Revive, Kim e SW).
#
#   MSST=<cartella del repository Music-Source-Separation-Training> SHARD=0/5 python Tools/banco_strumenti.py uscita.json
import sys, os, json, time, itertools, urllib.request, gc
import numpy as np, torch

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import benchmark as B

OUT = sys.argv[1]
shard, shards = (int(x) for x in os.environ.get("SHARD", "0/1").split("/"))
MSST = os.environ["MSST"]
sys.path.insert(0, MSST)
REL = "https://github.com/ZFTurbo/Music-Source-Separation-Training/releases/download/"
NUOVI = {
    "scnet": ("scnet", REL + "v1.0.15/config_musdb18_scnet_xl_more_wide_v5.yaml", REL + "v1.0.15/model_scnet_ep_36_sdr_10.0891.ckpt"),
    "bs4": ("bs_roformer", REL + "v1.0.12/config_bs_roformer_384_8_2_485100.yaml", REL + "v1.0.12/model_bs_roformer_ep_17_sdr_9.6568.ckpt"),
}
STEMS = ["drums", "bass", "other"]
torch.set_num_threads(os.cpu_count() or 4)

songs = [t for i, t in enumerate(B.tracks()) if i % shards == shard]
est = {t[0]: {} for t in songs}
tempi = {}


def tot(d):
    return d["other"] + d.get("guitar", 0) + d.get("piano", 0)


# 1. La voce di Studio e la base
for name, mix, rate, refs in songs:
    v = [B.roformer(f, mix, rate)["vocals"] for f in ("bs_roformer_vocals_revive_v3e_unwa.ckpt", "vocals_mel_band_roformer.ckpt")]
    sw = B.roformer("BS-Roformer-SW.ckpt", mix, rate)
    voice = (v[0] + v[1] + sw["vocals"]) / 3
    est[name]["base"] = (mix - voice).astype(np.float32)
    for s in ("drums", "bass"):
        est[name][f"{s}:SWmix"] = sw[s]
    est[name]["other:SWmix"] = sw["other"]          # B.roformer somma già chitarra e piano in «other»
B._roformer.clear(); gc.collect()

# 2. I modelli di Studio sulla base
for name, mix, rate, refs in songs:
    base = est[name]["base"]
    sw = B.roformer("BS-Roformer-SW.ckpt", base, rate)
    for s in STEMS:
        est[name][f"{s}:SW"] = sw[s]
    ht = B.demucs("htdemucs", base)
    for s in STEMS:
        est[name][f"{s}:ht"] = ht[s]
    est[name]["bass:ft"] = B.demucs("htdemucs_ft", base)["bass"]
B._roformer.clear(); B._demucs.clear(); gc.collect()

# 3. I modelli nuovi, sulla base e sulla canzone intera
from utils.settings import get_model_from_config
from utils.model_utils import demix
for short, (kind, cfg_url, ck_url) in NUOVI.items():
    cfg_path, ck_path = "/tmp/" + os.path.basename(cfg_url), "/tmp/" + os.path.basename(ck_url)
    for u, p in ((cfg_url, cfg_path), (ck_url, ck_path)):
        if not os.path.exists(p):
            urllib.request.urlretrieve(u, p)
    model, config = get_model_from_config(kind, cfg_path)
    sd = torch.load(ck_path, map_location="cpu")
    if isinstance(sd, dict) and "state" in sd:
        sd = sd["state"]
    if isinstance(sd, dict) and "state_dict" in sd:
        sd = sd["state_dict"]
    model.load_state_dict(sd)
    model.eval()
    t0, dur = time.time(), 0.0
    for name, mix, rate, refs in songs:
        for where, audio in (("", est[name]["base"]), ("mix", mix)):
            try:
                out = demix(config, model, audio, torch.device("cpu"), model_type=kind, pbar=False)
            except TypeError:
                out = demix(config, model, audio, torch.device("cpu"), model_type=kind)
            out = {k.lower(): np.asarray(v, dtype=np.float32)[:, :mix.shape[1]] for k, v in out.items()}
            for s in STEMS:
                if s in out:
                    est[name][f"{s}:{short}{where}"] = out[s]
            dur += mix.shape[1] / rate
    tempi[short] = round((time.time() - t0) / max(dur, 1), 2)
    print("==", short, tempi[short], "s per secondo di musica", flush=True)
    del model; gc.collect()

# 4. Da soli e in squadra
results = {}
for name, mix, rate, refs in songs:
    row = {}
    for s in STEMS:
        ref = refs[s]
        if np.sum(ref ** 2) < 1e-6:
            continue
        cand = {k.split(":", 1)[1]: a for k, a in est[name].items() if k.startswith(s + ":")}
        names = sorted(cand)
        for r in range(1, len(names) + 1):
            for combo in itertools.combinations(names, r):
                lab = combo[0] if r == 1 else "media(" + ",".join(combo) + ")"
                row[f"{s}:{lab}"] = round(B.sdr(ref, sum(cand[c] for c in combo) / r), 2)
    results[name] = row
    print(name, len(row), flush=True)
json.dump({"shard": shard, "tempi": tempi, "canzoni": results}, open(OUT, "w"), ensure_ascii=False)
