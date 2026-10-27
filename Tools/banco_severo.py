# Banco severo: la ricetta di Studio (e Massima e Veloce per confronto) sulle canzoni INTERE di prova di MUSDB18-HQ,
# con più misure dell'SDR globale, e la stessa ricetta sul dataset Multisong di MVSep per la loro classifica.
#
#   SHARD=3/25 python Tools/banco_severo.py musdb uscita.json
#       le canzoni della parte 3 su 25 (divise per durata), scaricate a pezzi dallo zip di MUSDB18-HQ su Zenodo;
#       PROVA=1 prende solo la canzone più corta (per misurare i tempi).
#   SHARD=3/20 python Tools/banco_severo.py multisong <cartella con song_XXX_mixture.wav> <cartella di uscita>
#       separa con Studio e scrive song_XXX_{vocals,instrum,bass,drums,other}.flac come vuole mvsep.com.
#
# Ricette (come l'app):
#   Studio  voce = media(Revive, Kim, SW) sulla canzone; base = canzone − voce;
#           batteria = media(SW sulla base, HTDemucs sulla base, SW sulla canzone);
#           basso = media(SW sulla base, Demucs FT basso sulla base, HTDemucs sulla base, SW sulla canzone);
#           altro (con chitarra e piano) = media(SW base, HTDemucs altro, SW canzone).
#   Massima BS-RoFormer SW da solo sulla canzone.      Veloce  HTDemucs da solo sulla canzone.
#   In tutte la base («instrumental») è canzone − voce.
#
# Misure per strumento (più alto = meglio):
#   sdr        SDR globale della Music Demixing Challenge: 10·log10(Σref² / Σ(ref−stima)²) sulla canzone intera
#   sdr_1s     mediana dell'SDR globale calcolato su finestre di 1 s (si saltano quelle con l'originale muto)
#   museval    SDR BSSEval v4 di museval (SiSEC 2018): mediana sui riquadri da 1 s (solo voce/batteria/basso/altro)
#   si_sdr     SDR invariante alla scala (Le Roux et al. 2019)
#   bleedless, fullness  le misure di MVSep, copiate da utils/metrics.py::bleed_full di ZFTurbo
#              (Music-Source-Separation-Training, licenza MIT): spettrogrammi mel (4096/1024, 512 bande) in dB
#              con top_db 80; diff = stima − originale; bleedless = 100/(1+media dei diff>0) (energia in più =
#              rientri di altri strumenti), fullness = 100/(1+|media dei diff<0|) (energia che manca).
import sys, os, io, json, time, math, re, tempfile, gc
import numpy as np
import torch

torch.set_num_threads(os.cpu_count() or 4)
STEMS = ["vocals", "drums", "bass", "other"]
OVERLAP = int(os.environ.get("OVERLAP", "2"))          # sovrapposizione dei pezzi dei RoFormer, come l'app (2)
ZIP_HQ = "https://zenodo.org/records/3338373/files/musdb18hq.zip?download=1"
tempi = {}


def tick(key, t0, seconds):
    tempi.setdefault(key, [0.0, 0.0])
    tempi[key][0] += time.time() - t0
    tempi[key][1] += seconds


# ── Modelli ────────────────────────────────────────────────────────────────────────────────────

_sep = {}


def roformer(model_file, mix, rate):
    """Un modello del pacchetto audio-separator; chitarra e piano finiscono in «other»."""
    import soundfile as sf
    from audio_separator.separator import Separator
    t0 = time.time()
    tmp = tempfile.mkdtemp()
    if model_file not in _sep:
        sep = Separator(output_dir=tmp, output_format="WAV", log_level=40,
                        mdxc_params={"segment_size": 256, "override_model_segment_size": False,
                                     "batch_size": 1, "overlap": OVERLAP, "pitch_shift": 0})
        sep.load_model(model_filename=model_file)
        _sep[model_file] = sep
    sep = _sep[model_file]
    sep.output_dir = tmp
    if getattr(sep, "model_instance", None) is not None:
        sep.model_instance.output_dir = tmp
    path = os.path.join(tmp, "mix.wav")
    sf.write(path, mix.T, rate, subtype="FLOAT")
    found = {}
    for f in sep.separate(path):
        f = f if os.path.isabs(f) else os.path.join(tmp, f)
        a, _ = sf.read(f, dtype="float32", always_2d=True)
        os.remove(f)
        a = a.T[:, :mix.shape[1]]
        if a.shape[0] == 1:
            a = np.repeat(a, 2, 0)
        a = np.pad(a, ((0, 0), (0, mix.shape[1] - a.shape[1])))
        m = re.findall(r"\(([^)]+)\)", os.path.basename(f))
        found[(m[0] if m else os.path.basename(f)).lower()] = a
    os.remove(path)
    out = {}
    for k, a in found.items():
        if k in ("vocals", "vocal"):
            out["vocals"] = a
        elif k in ("drums", "bass"):
            out[k] = a
        elif k in ("guitar", "piano", "other"):
            out["other"] = out.get("other", 0) + a
    if "vocals" not in out:
        raise SystemExit(f"{model_file}: niente voce in {list(found)}")
    tick(model_file, t0, mix.shape[1] / rate)
    return out


_dem = {}


def demucs(name, mix, rate, only=None):
    """Come Tools/benchmark.py: normalizzazione, pezzi con sovrapposizione 0.25, nessuno spostamento.
    only="bass" su htdemucs_ft usa solo il modello del basso del gruppo (identico al gruppo per il basso)."""
    from demucs.pretrained import get_model
    from demucs.apply import apply_model, BagOfModels
    t0 = time.time()
    if name not in _dem:
        _dem[name] = get_model(name).eval()
    model = _dem[name]
    sources = model.sources
    if only and isinstance(model, BagOfModels):
        j = sources.index(only)
        who = [i for i, w in enumerate(model.weights) if w[j] != 0]
        if len(who) == 1:
            model = model.models[who[0]]
    wav = torch.from_numpy(np.ascontiguousarray(mix))
    ref = wav.mean(0)
    wav = (wav - ref.mean()) / (ref.std() + 1e-8)
    with torch.no_grad():
        out = apply_model(model, wav[None], shifts=0, split=True, overlap=0.25, progress=False)[0]
    out = out * (ref.std() + 1e-8) + ref.mean()
    tick(name + (":" + only if only else ""), t0, mix.shape[1] / rate)
    return {s: out[sources.index(s)].numpy() for s in STEMS if s in sources}


def recipes(mix, rate, studio_only=False):
    """Le tre ricette dell'app; ognuna dà voce, batteria, basso, altro e base."""
    revive = roformer("bs_roformer_vocals_revive_v3e_unwa.ckpt", mix, rate)["vocals"]
    kim = roformer("vocals_mel_band_roformer.ckpt", mix, rate)["vocals"]
    sw = roformer("BS-Roformer-SW.ckpt", mix, rate)
    voice = (revive + kim + sw["vocals"]) / 3
    base = (mix - voice).astype(np.float32)
    swb = roformer("BS-Roformer-SW.ckpt", base, rate)
    htb = demucs("htdemucs", base, rate)
    ftb = demucs("htdemucs_ft", base, rate, only="bass")["bass"]
    out = {"Studio": {
        "vocals": voice,
        "drums": (swb["drums"] + htb["drums"] + sw["drums"]) / 3,
        "bass": (swb["bass"] + ftb + htb["bass"] + sw["bass"]) / 4,
        "other": (swb["other"] + htb["other"] + sw["other"]) / 3,
        "instrumental": base,
    }}
    # Ricette leggere per i computer lenti (Mac Intel, PC senza scheda grafica): stessi modelli, meno passaggi
    v2 = (revive + sw["vocals"]) / 2
    out["Leggera A"] = {          # niente Kim e niente Demucs: Revive + SW sulla canzone + SW sulla base
        "vocals": v2,
        "drums": (swb["drums"] + sw["drums"]) / 2, "bass": (swb["bass"] + sw["bass"]) / 2,
        "other": (swb["other"] + sw["other"]) / 2, "instrumental": (mix - v2).astype(np.float32)}
    out["Leggera B"] = {          # due modelli: Revive + SW sulla canzone
        "vocals": v2, **{k: sw[k] for k in ("drums", "bass", "other")}, "instrumental": (mix - v2).astype(np.float32)}
    out["Studio senza Demucs"] = {
        "vocals": voice,
        "drums": (swb["drums"] + sw["drums"]) / 2, "bass": (swb["bass"] + sw["bass"]) / 2,
        "other": (swb["other"] + sw["other"]) / 2, "instrumental": base}
    if not studio_only:
        out["Massima"] = {**{s: sw[s] for s in STEMS}, "instrumental": mix - sw["vocals"]}
        ht = demucs("htdemucs", mix, rate)
        out["Veloce"] = {**{s: ht[s] for s in STEMS}, "instrumental": mix - ht["vocals"]}
    return out


# ── Misure ─────────────────────────────────────────────────────────────────────────────────────

def sdr(ref, est):
    num = np.sum(ref ** 2) + 1e-8
    den = np.sum((ref - est) ** 2) + 1e-8
    return 10 * math.log10(num / den)


def sdr_1s(ref, est, rate):
    n = ref.shape[1] // rate
    r = ref[:, :n * rate].reshape(2, n, rate)
    e = est[:, :n * rate].reshape(2, n, rate)
    num = np.sum(r ** 2, axis=(0, 2))
    den = np.sum((r - e) ** 2, axis=(0, 2))
    ok = num > 1e-8
    if not ok.any():
        return None
    return float(np.median(10 * np.log10(num[ok] / (den[ok] + 1e-12))))


def si_sdr(ref, est):
    r, e = ref.ravel(), est.ravel()
    a = np.dot(e, r) / (np.dot(r, r) + 1e-12)
    t = a * r
    return 10 * math.log10((np.sum(t ** 2) + 1e-12) / (np.sum((e - t) ** 2) + 1e-12))


_mel = {}


def bleed_full(reference, estimate, sr=44100, n_fft=4096, hop_length=1024, n_mels=512):
    """utils/metrics.py::bleed_full di ZFTurbo/Music-Source-Separation-Training (MIT), su CPU."""
    import librosa
    from torchaudio.transforms import AmplitudeToDB
    reference = torch.from_numpy(np.ascontiguousarray(reference)).float()
    estimate = torch.from_numpy(np.ascontiguousarray(estimate)).float()
    window = torch.hann_window(n_fft)
    D1 = torch.abs(torch.stft(reference, n_fft=n_fft, hop_length=hop_length, window=window, return_complex=True, pad_mode="constant"))
    D2 = torch.abs(torch.stft(estimate, n_fft=n_fft, hop_length=hop_length, window=window, return_complex=True, pad_mode="constant"))
    if (sr, n_fft, n_mels) not in _mel:
        _mel[(sr, n_fft, n_mels)] = torch.from_numpy(librosa.filters.mel(sr=sr, n_fft=n_fft, n_mels=n_mels))
    mel = _mel[(sr, n_fft, n_mels)]
    S1_db = AmplitudeToDB(stype="magnitude", top_db=80)(torch.matmul(mel, D1))
    S2_db = AmplitudeToDB(stype="magnitude", top_db=80)(torch.matmul(mel, D2))
    diff = S2_db - S1_db
    pos, neg = diff[diff > 0], diff[diff < 0]
    ap = torch.mean(pos) if pos.numel() > 0 else torch.tensor(0.0)
    an = torch.mean(neg) if neg.numel() > 0 else torch.tensor(0.0)
    return float(100 * 1 / (ap + 1)), float(100 * 1 / (-an + 1))


def museval_v4(refs, ests, rate):
    """SDR BSSEval v4 (museval, come SiSEC 2018): mediana sui riquadri di 1 s, per voce/batteria/basso/altro."""
    from museval.metrics import bss_eval
    R = np.stack([refs[s].T for s in STEMS]).astype(np.float64)
    E = np.stack([ests[s][:, :refs[s].shape[1]].T for s in STEMS]).astype(np.float64)
    SDR, ISR, SIR, SAR, _ = bss_eval(R, E, compute_permutation=False, window=rate, hop=rate,
                                     framewise_filters=False, bsseval_sources_version=False)
    out = {}
    for i, s in enumerate(STEMS):
        v = SDR[i][np.isfinite(SDR[i])]
        out[s] = float(np.median(v)) if v.size else None
    return out


def measure(refs, ests, rate, use_museval=True):
    row = {}
    mv = {}
    if use_museval:
        t0 = time.time()
        try:
            mv = museval_v4(refs, ests, rate)
        except Exception as e:  # noqa: BLE001
            print("::warning::museval:", repr(e)[:300], flush=True)
        tick("museval", t0, refs["vocals"].shape[1] / rate)
    for s, ref in refs.items():
        if np.sum(ref.astype(np.float64) ** 2) < 1e-6 or s not in ests:
            continue
        r = ref.astype(np.float64)
        e = ests[s][:, :ref.shape[1]].astype(np.float64)
        b, f = bleed_full(ref, ests[s][:, :ref.shape[1]], sr=rate)
        m = {"sdr": sdr(r, e), "sdr_1s": sdr_1s(r, e, rate), "si_sdr": si_sdr(r, e), "bleedless": b, "fullness": f}
        if mv.get(s) is not None:
            m["museval"] = mv[s]
        row[s] = {k: (round(v, 3) if v is not None else None) for k, v in m.items()}
    return row


# ── MUSDB18-HQ, a pezzi da Zenodo ──────────────────────────────────────────────────────────────

def lpt(sizes, shards):
    """Divide le canzoni in parti di durata simile (la più lunga alla parte più scarica)."""
    load = [0.0] * shards
    part = {}
    for name, size in sorted(sizes.items(), key=lambda x: (-x[1], x[0])):
        i = min(range(shards), key=lambda k: (load[k], k))
        part[name] = i
        load[i] += size
    return part


def musdb_songs(shard, shards):
    import soundfile as sf
    from remotezip import RemoteZip
    for attempt in range(5):
        try:
            z = RemoteZip(ZIP_HQ)
            break
        except Exception as e:  # noqa: BLE001
            print("Zenodo:", e, flush=True)
            time.sleep(30 * (attempt + 1))
    names = [n for n in z.namelist() if n.startswith("test/") and n.endswith("/mixture.wav")]
    sizes = {n.split("/")[1]: z.getinfo(n).file_size for n in names}
    if os.environ.get("PROVA"):
        mine = [min(sizes, key=sizes.get)]
    else:
        part = lpt(sizes, shards)
        mine = sorted(n for n, p in part.items() if p == shard)
    print("canzoni di questa parte:", mine, flush=True)
    for name in mine:
        audio = {}
        for s in ["mixture"] + STEMS:
            for attempt in range(5):
                try:
                    data = z.read(f"test/{name}/{s}.wav")
                    break
                except Exception as e:  # noqa: BLE001
                    print("Zenodo:", e, flush=True)
                    time.sleep(30 * (attempt + 1))
                    z = RemoteZip(ZIP_HQ)
            a, rate = sf.read(io.BytesIO(data), dtype="float32", always_2d=True)
            audio[s] = a.T
        yield name, audio.pop("mixture"), rate, audio


def run_musdb(out_path):
    shard, shards = (int(x) for x in os.environ.get("SHARD", "0/1").split("/"))
    results, durate = {}, {}
    for name, mix, rate, refs in musdb_songs(shard, shards):
        t0 = time.time()
        refs["instrumental"] = refs["drums"] + refs["bass"] + refs["other"]
        est = recipes(mix, rate)
        results[name] = {r: measure(refs, e, rate) for r, e in est.items()}
        durate[name] = round(mix.shape[1] / rate, 1)
        s = results[name]
        print(f"::notice title={name}::" + " · ".join(
            f"{r} " + "/".join(f"{s[r][k]['sdr']:.2f}" for k in STEMS if k in s[r]) for r in s)
            + f" (voce/batteria/basso/altro, SDR; {time.time() - t0:.0f} s)", flush=True)
        del est
        gc.collect()
        json.dump({"shard": shard, "tempi": tempi, "durate": durate, "canzoni": results}, open(out_path, "w"), ensure_ascii=False)
    t = {k: round(v[0] / max(v[1], 1), 2) for k, v in tempi.items()}
    print("::notice title=Tempi (s per s di musica)::" + ", ".join(f"{k} {v}" for k, v in t.items()), flush=True)
    json.dump({"shard": shard, "tempi": tempi, "durate": durate, "canzoni": results}, open(out_path, "w"), ensure_ascii=False)


# ── Multisong di MVSep ─────────────────────────────────────────────────────────────────────────

def run_multisong(src, dst):
    import soundfile as sf
    shard, shards = (int(x) for x in os.environ.get("SHARD", "0/1").split("/"))
    files = sorted(f for f in os.listdir(src) if f.endswith("_mixture.wav"))
    os.makedirs(dst, exist_ok=True)
    clipped = 0
    for i, f in enumerate(files):
        if i % shards != shard:
            continue
        t0 = time.time()
        mix, rate = sf.read(os.path.join(src, f), dtype="float32", always_2d=True)
        mix = mix.T
        st = recipes(mix, rate, studio_only=True)["Studio"]
        song = f[: -len("_mixture.wav")]
        for stem, key in (("vocals", "vocals"), ("instrum", "instrumental"), ("bass", "bass"), ("drums", "drums"), ("other", "other")):
            a = st[key]
            clipped += int(np.sum(np.abs(a) > 1.0))
            sf.write(os.path.join(dst, f"{song}_{stem}.flac"), np.clip(a, -1, 1).T, rate, subtype="PCM_16")
        print(song, f"{time.time() - t0:.0f} s", flush=True)
    t = {k: round(v[0] / max(v[1], 1), 2) for k, v in tempi.items()}
    print(f"::notice title=Multisong parte {shard}::campioni tagliati oltre ±1: {clipped}; tempi " + ", ".join(f"{k} {v}" for k, v in t.items()), flush=True)


if __name__ == "__main__":
    if sys.argv[1] == "musdb":
        run_musdb(sys.argv[2])
    elif sys.argv[1] == "multisong":
        run_multisong(sys.argv[2], sys.argv[3])
    else:
        raise SystemExit("uso: banco_severo.py musdb <uscita.json> | multisong <origine> <uscita>")
