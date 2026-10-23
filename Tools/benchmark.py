# Banco di prova della qualità: le 50 canzoni di prova di MUSDB18 (estratti da 7 secondi, con le tracce
# originali separate) passano da un metodo di separazione, e per ogni strumento si misura l'SDR:
# quanto la traccia separata somiglia all'originale, in dB (più alto = più pulito; +1 dB si sente).
#
#   python Tools/benchmark.py <metodo> <uscita.json>
#
# Metodi:
#   htdemucs, htdemucs_ft          Demucs (quelli di AudioLR: Veloce e Massima qualità)
#   htdemucs_ft_s2                 Massima qualità con 2 «spostamenti» (media di due passaggi sfasati)
#   roformer:<file>                un modello del pacchetto audio-separator (RoFormer voce/base, o a 6 strumenti)
#   ibrido:<voce>+<strumenti>      voce dal primo modello; batteria/basso/altro dal secondo, applicato alla base
#   cartella:<percorso>            tracce già separate da un'altra app (es. Fadr), <percorso>/<canzone>/<strumento>.wav
import sys, os, json, math, tempfile
import numpy as np

METHOD, OUT = sys.argv[1], sys.argv[2]
STEMS = ["vocals", "drums", "bass", "other"]


def sdr(ref, est):
    """SDR «globale» come nella Music Demixing Challenge: 10·log10(Σref² / Σ(ref−est)²)."""
    num = np.sum(ref.astype(np.float64) ** 2) + 1e-8
    den = np.sum((ref.astype(np.float64) - est.astype(np.float64)) ** 2) + 1e-8
    return 10 * math.log10(num / den)


def tracks():
    import musdb
    db = musdb.DB(root=os.environ.get("MUSDB_ROOT", "musdb"), download=True, subsets="test")
    for t in db:
        refs = {s: t.targets[s].audio.T.astype(np.float32) for s in STEMS}
        yield t.name, t.audio.T.astype(np.float32), t.rate, refs


# ── Metodi ─────────────────────────────────────────────────────────────────────────────────────

_demucs = {}


def demucs(name, mix, shifts=0):
    import torch
    from demucs.pretrained import get_model
    from demucs.apply import apply_model
    if name not in _demucs:
        _demucs[name] = get_model(name).eval()
    bag = _demucs[name]
    wav = torch.from_numpy(mix)
    ref = wav.mean(0)
    wav = (wav - ref.mean()) / (ref.std() + 1e-8)
    with torch.no_grad():
        out = apply_model(bag, wav[None], shifts=shifts, split=True, overlap=0.25, progress=False)[0]
    out = out * (ref.std() + 1e-8) + ref.mean()
    return {s: out[bag.sources.index(s)].numpy() for s in STEMS}


_roformer = {}


def roformer(model_file, mix, rate):
    """Separazione con un modello del pacchetto audio-separator (RoFormer e simili).
    Restituisce gli strumenti che il modello conosce; chitarra e pianoforte finiscono in «other»;
    nei modelli a due tracce l'altra traccia è la base («instrumental»)."""
    import re
    import soundfile as sf
    from audio_separator.separator import Separator
    tmp = tempfile.mkdtemp()
    if model_file not in _roformer:
        sep = Separator(output_dir=tmp, output_format="WAV", log_level=40)
        sep.load_model(model_filename=model_file)
        _roformer[model_file] = sep
    sep = _roformer[model_file]
    sep.output_dir = tmp
    if getattr(sep, "model_instance", None) is not None:
        sep.model_instance.output_dir = tmp
    path = os.path.join(tmp, "mix.wav")
    sf.write(path, mix.T, rate, subtype="FLOAT")
    files = sep.separate(path)
    found = {}
    for f in files:
        f = f if os.path.isabs(f) else os.path.join(tmp, f)
        audio, _ = sf.read(f, dtype="float32", always_2d=True)
        audio = audio.T[:, :mix.shape[1]]
        if audio.shape[0] == 1:
            audio = np.repeat(audio, 2, 0)
        audio = np.pad(audio, ((0, 0), (0, mix.shape[1] - audio.shape[1])))
        m = re.findall(r"\(([^)]+)\)", os.path.basename(f))
        found[(m[0] if m else os.path.basename(f)).lower()] = audio
    out = {}
    for k, a in found.items():
        if k in ("vocals", "vocal"):
            out["vocals"] = a
        elif k in ("instrumental", "no vocals", "no_vocals"):
            out["instrumental"] = a
        elif k in ("drums", "bass"):
            out[k] = a
        elif k in ("guitar", "piano", "other"):
            out["other"] = out.get("other", 0) + a
    if "vocals" in out and len(found) == 2 and "instrumental" not in out:
        # Modello voce/resto: il «resto» è la base
        out["instrumental"] = out.pop("other", mix - out["vocals"])
    if "vocals" in out and "instrumental" not in out and not all(s in out for s in ("drums", "bass", "other")):
        out["instrumental"] = mix - out["vocals"]
    if "instrumental" in out and "vocals" not in out:
        out["vocals"] = mix - out["instrumental"]
    return out


def four(name, mix, rate):
    """Batteria, basso e altro con un modello a 4+ strumenti (Demucs o RoFormer)."""
    if name.startswith("htdemucs"):
        return demucs(name, mix)
    return roformer(name, mix, rate)


def separate(mix, rate, name):
    if METHOD in ("htdemucs", "htdemucs_ft"):
        return demucs(METHOD, mix)
    if METHOD == "htdemucs_ft_s2":
        return demucs("htdemucs_ft", mix, shifts=2)
    if METHOD.startswith("roformer:"):
        return roformer(METHOD.split(":", 1)[1], mix, rate)
    if METHOD.startswith("ibrido:"):
        # ibrido:<modello voce>+<modello strumenti>: voce dal primo, il resto dal secondo applicato alla base
        voice, rest = METHOD.split(":", 1)[1].split("+")
        r = roformer(voice, mix, rate)
        base = (mix - r["vocals"]).astype(np.float32)
        d = four(rest, base, rate)
        return {"vocals": r["vocals"], "instrumental": base, "drums": d["drums"], "bass": d["bass"], "other": d["other"]}
    if METHOD.startswith("cartella:"):
        import soundfile as sf
        base = os.path.join(METHOD.split(":", 1)[1], name)
        out = {}
        for s in STEMS + ["instrumental"]:
            p = os.path.join(base, s + ".wav")
            if os.path.exists(p):
                a, _ = sf.read(p, dtype="float32", always_2d=True)
                a = a.T
                if a.shape[0] == 1:
                    a = np.repeat(a, 2, 0)
                n = mix.shape[1]
                out[s] = np.pad(a[:, :n], ((0, 0), (0, max(0, n - a.shape[1]))))
        return out if out else None
    raise SystemExit("metodo sconosciuto: " + METHOD)


# ── Misura ─────────────────────────────────────────────────────────────────────────────────────

results = {}
for name, mix, rate, refs in tracks():
    refs["instrumental"] = refs["drums"] + refs["bass"] + refs["other"]
    est = separate(mix, rate, name)
    if est is None:
        continue
    if "instrumental" not in est and all(s in est for s in ("drums", "bass", "other")):
        est["instrumental"] = est["drums"] + est["bass"] + est["other"]
    row = {}
    for s, ref in refs.items():
        # Le tracce mute (es. niente basso in quel pezzo) non si possono misurare
        if s in est and np.sum(ref ** 2) > 1e-6:
            row[s] = round(sdr(ref, est[s][:, :ref.shape[1]]), 2)
    results[name] = row
    print(name, row, flush=True)

summary = {}
for s in STEMS + ["instrumental"]:
    v = [r[s] for r in results.values() if s in r]
    if v:
        summary[s] = {"mediana": round(float(np.median(v)), 2), "media": round(float(np.mean(v)), 2), "canzoni": len(v)}
json.dump({"metodo": METHOD, "riepilogo": summary, "canzoni": results}, open(OUT, "w"), indent=1, ensure_ascii=False)
print("RIEPILOGO", METHOD, json.dumps(summary, ensure_ascii=False))
