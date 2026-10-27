# Tabella del banco severo: unisce le parti (severo_*.json), calcola mediana e media per ricetta, strumento e
# misura, e le confronta con la corsa precedente (se c'è).
#
#   python Tools/banco_severo_tabella.py <cartella delle parti> <precedente.json o ""> severo.json severo.md
import sys, os, json, glob, statistics as st

src, prev_path, out_json, out_md = sys.argv[1:5]
songs, tempi, durate = {}, {}, {}
for f in sorted(glob.glob(os.path.join(src, "severo_*.json"))):
    d = json.load(open(f))
    songs.update(d["canzoni"])
    durate.update(d.get("durate", {}))
    for k, (sec, mus) in d.get("tempi", {}).items():
        a = tempi.setdefault(k, [0.0, 0.0])
        a[0] += sec
        a[1] += mus

RECIPES = ["Studio", "Studio senza Demucs", "Leggera A", "Leggera B", "Massima", "Veloce"]
STEMS = [("vocals", "Voce"), ("drums", "Batteria"), ("bass", "Basso"), ("other", "Altro"), ("instrumental", "Base")]
METRICS = [("sdr", "SDR globale (dB, canzone intera, come la Music Demixing Challenge)"),
           ("sdr_1s", "SDR su finestre da 1 s (dB, mediana delle finestre)"),
           ("museval", "SDR BSSEval v4 di museval (dB, mediana dei riquadri da 1 s, come SiSEC 2018)"),
           ("si_sdr", "SI-SDR (dB, invariante al volume)"),
           ("bleedless", "Bleedless di MVSep (meno rientri di altri strumenti = più alto)"),
           ("fullness", "Fullness di MVSep (meno suono mancante = più alto)")]

summary = {}
for r in RECIPES:
    for s, _ in STEMS:
        for m, _ in METRICS:
            v = [songs[n][r][s][m] for n in songs if r in songs[n] and s in songs[n][r] and songs[n][r][s].get(m) is not None]
            if v:
                summary[f"{r}|{s}|{m}"] = {"mediana": round(st.median(v), 3), "media": round(st.mean(v), 3), "canzoni": len(v)}

prev = {}
if prev_path and os.path.exists(prev_path):
    try:
        prev = json.load(open(prev_path)).get("riepilogo", {})
    except Exception:  # noqa: BLE001
        prev = {}


def cell(key, field):
    if key not in summary:
        return "—"
    v = summary[key][field]
    t = f"{v:.2f}"
    if key in prev and field in prev[key]:
        d = v - prev[key][field]
        t += f" ({d:+.2f})"
    return t


n_songs = len(songs)
tot = sum(durate.values())
md = [f"**{n_songs} canzoni intere** di prova di MUSDB18-HQ ({tot / 60:.0f} minuti di musica). Più alto = meglio.",
      "Per ogni ricetta: mediana e media sulle canzoni" + (" — tra parentesi la differenza dalla corsa precedente." if prev else "."),
      "", "Studio = voce media(Revive, Kim, SW), strumenti dalle medie sulla base; Massima = BS-RoFormer SW da solo; Veloce = HTDemucs da solo. Leggera A = voce media(Revive, SW), strumenti media(SW sulla canzone, SW sulla base); Leggera B = voce media(Revive, SW), strumenti da SW.", ""]
for m, title in METRICS:
    if not any(k.endswith("|" + m) for k in summary):
        continue
    md += [f"### {title}", "", "| Strumento | " + " | ".join(f"{r} mediana | {r} media" for r in RECIPES) + " |",
           "|---|" + "---|---|" * len(RECIPES)]
    for s, name in STEMS:
        if not any(f"{r}|{s}|{m}" in summary for r in RECIPES):
            continue
        md.append(f"| {name} | " + " | ".join(f"{cell(f'{r}|{s}|{m}', 'mediana')} | {cell(f'{r}|{s}|{m}', 'media')}" for r in RECIPES) + " |")
    md.append("")
if tempi:
    md += ["### Tempo (CPU del server, secondi per secondo di musica)", "", "| Passaggio | Tempo |", "|---|---|"]
    md += [f"| {k} | {v[0] / max(v[1], 1):.2f} |" for k, v in sorted(tempi.items(), key=lambda x: -x[1][0] / max(x[1][1], 1))]
    md.append("")
missing = [n for n in songs if not all(r in songs[n] for r in RECIPES)]
if n_songs < 50 or missing:
    md.append(f"Attenzione: {n_songs} canzoni misurate su 50" + (f"; incomplete: {', '.join(missing)}" if missing else "") + ".")

text = "\n".join(md)
open(out_md, "w").write(text)
json.dump({"riepilogo": summary, "tempi": tempi, "durate": durate, "canzoni": songs}, open(out_json, "w"), ensure_ascii=False)
print(text)
