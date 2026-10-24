# Banco di prova delle combinazioni: per ogni canzone di prova di MUSDB18 si calcolano una volta sola
# tutti i modelli candidati, poi si misurano molte combinazioni (voce, base, batteria, basso, altro).
# Così si sceglie con i numeri come comporre Massima e Studio.
#
#   SHARD=0/5 python Tools/benchmark_varianti.py uscita.json
#
# Ogni chiave del risultato è «traccia:ricetta», per esempio «bass:media(SW,ft)».
import sys, os, json
import numpy as np

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import benchmark as B

OUT = sys.argv[1]
shard, shards = (int(x) for x in os.environ.get("SHARD", "0/1").split("/"))

VIPERX = "model_bs_roformer_ep_317_sdr_12.9755.ckpt"
KIM = "vocals_mel_band_roformer.ckpt"
SW = "BS-Roformer-SW.ckpt"


def avg(*xs):
    return sum(xs) / len(xs)


def candidates(mix, rate):
    """Tutte le stime candidate per una canzone, come {«traccia:ricetta»: audio}."""
    e = {}
    # Massima com'è oggi: SW sulla canzone intera
    sw_mix = B.roformer(SW, mix, rate)
    vx = B.roformer(VIPERX, mix, rate)["vocals"]
    vk = B.roformer(KIM, mix, rate)["vocals"]
    e["vocals:SW"] = sw_mix["vocals"]
    e["vocals:viperx"] = vx
    e["vocals:kim"] = vk
    e["vocals:media(viperx,kim)"] = avg(vx, vk)
    e["vocals:media(viperx,SW)"] = avg(vx, sw_mix["vocals"])
    e["vocals:media(viperx,kim,SW)"] = avg(vx, vk, sw_mix["vocals"])
    for k in [k for k in e if k.startswith("vocals:")]:
        e["instrumental:" + k.split(":", 1)[1]] = mix - e[k]
    e["drums:SW"], e["bass:SW"], e["other:SW"] = sw_mix["drums"], sw_mix["bass"], sw_mix["other"]

    # Studio: gli strumenti dalla base senza la voce di viperx
    base = (mix - vx).astype(np.float32)
    sw = B.roformer(SW, base, rate)
    ft = B.demucs("htdemucs_ft", base)
    ht = B.demucs("htdemucs", base)
    e["drums:base·SW"], e["bass:base·SW"], e["other:base·SW"] = sw["drums"], sw["bass"], sw["other"]
    e["drums:base·ft"], e["bass:base·ft"], e["other:base·ft"] = ft["drums"], ft["bass"], ft["other"]
    e["bass:base·ht"] = ht["bass"]
    e["drums:base·media(SW,ft)"] = avg(sw["drums"], ft["drums"])
    e["bass:base·media(SW,ft)"] = avg(sw["bass"], ft["bass"])
    e["bass:base·media(SW,ht)"] = avg(sw["bass"], ht["bass"])
    e["bass:base·media(SW,ft,ht)"] = avg(sw["bass"], ft["bass"], ht["bass"])
    e["other:base·media(SW,ft)"] = avg(sw["other"], ft["other"])
    # «Altro» come resto: la base meno batteria e basso (così le tracce sommano sempre alla base)
    e["other:base−SW−ft"] = base - sw["drums"] - ft["bass"]
    e["other:base−media"] = base - avg(sw["drums"], ft["drums"]) - avg(sw["bass"], ft["bass"])
    return e


results = {}
for i, (name, mix, rate, refs) in enumerate(B.tracks()):
    if i % shards != shard:
        continue
    refs["instrumental"] = refs["drums"] + refs["bass"] + refs["other"]
    row = {}
    for key, est in candidates(mix, rate).items():
        stem = key.split(":", 1)[0]
        ref = refs[stem]
        if np.sum(ref ** 2) > 1e-6:
            row[key] = round(B.sdr(ref, est[:, :ref.shape[1]]), 2)
    results[name] = row
    print(name, row, flush=True)

json.dump({"shard": shard, "canzoni": results}, open(OUT, "w"), indent=1, ensure_ascii=False)
