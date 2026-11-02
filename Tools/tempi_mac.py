# Il banco dei tempi del Mac (workflow «Tempi Mac»).
#
#   python Tools/tempi_mac.py canzone <uscita.wav>
#       La canzone di prova: gli estratti da 7 s di MUSDB18 (canzoni vere, con licenza per la ricerca) uno dopo
#       l'altro, 35 secondi. Sempre la stessa: «prima» e «dopo» separano esattamente lo stesso audio.
#
#   python Tools/tempi_mac.py confronto <cartella> <riepilogo.md>
#       <cartella>/banco-<macchina>-<versione>/ con audiolr-banco.json, avvio.json e tracce/<prova>/<traccia>.wav.
#       Scrive la tabella prima/dopo e il confronto delle tracce: SDR del «dopo» rispetto al «prima»
#       (identica, oppure almeno 60 dB: differenze che non si sentono, come tra due calcoli sulla grafica).
import sys, os, json, math, glob, wave
import numpy as np

RATE = 44100


def song(out):
    import musdb
    db = musdb.DB(root=os.environ.get("MUSDB_ROOT", "musdb"), download=True, subsets="test")
    parts = []
    for t in sorted(db, key=lambda t: t.name)[:5]:
        a = t.audio.astype(np.float32)
        assert t.rate == RATE
        parts.append(a)
    mix = np.concatenate(parts)
    mix = np.clip(mix, -1, 1)
    pcm = (mix * 32767).astype("<i2")
    with wave.open(out, "wb") as w:
        w.setnchannels(2); w.setsampwidth(2); w.setframerate(RATE)
        w.writeframes(pcm.tobytes())
    print(f"Canzone di prova: {len(mix) / RATE:.1f} s da {len(parts)} estratti di MUSDB18")


def read(path):
    import soundfile as sf
    a, _ = sf.read(path, dtype="float64", always_2d=True)
    return a


def sdr(ref, est):
    n = min(len(ref), len(est))
    ref, est = ref[:n], est[:n]
    den = np.sum((ref - est) ** 2)
    if den == 0:
        return math.inf
    return 10 * math.log10((np.sum(ref ** 2) + 1e-12) / den)


def load(folder):
    def j(name):
        p = os.path.join(folder, name)
        return json.load(open(p)) if os.path.exists(p) else {}
    return j("audiolr-banco.json"), j("avvio.json")


def fmt(x, unit="", d=1):
    return "—" if x is None else f"{x:.{d}f}{unit}"


def compare(root, out):
    lines = ["## Tempi Mac: prima e dopo", ""]
    machines = sorted({os.path.basename(p).split("-", 1)[1].rsplit("-", 1)[0] for p in glob.glob(os.path.join(root, "banco-*"))})
    worst = []
    for m in machines:
        a_dir, b_dir = os.path.join(root, f"banco-{m}-prima"), os.path.join(root, f"banco-{m}-dopo")
        (a, a_start), (b, b_start) = load(a_dir), load(b_dir)
        info = (b or a).get("macchina", {})
        lines += [f"### {m} · {info.get('processore', '?')} · {fmt(info.get('memoriaGB'), ' GB', 0)} · Neural Engine: {'sì' if info.get('neuralEngine') else 'no'}", ""]
        lines += ["| Prova | Secondi prima | Secondi dopo | Memoria max prima (MB) | dopo | Ritardo finestra max prima (ms) | dopo | Blocchi >50 ms prima | dopo |",
                  "|---|---|---|---|---|---|---|---|---|"]
        ra, rb = a.get("prove", {}), b.get("prove", {})
        for k in sorted(set(ra) | set(rb)):
            if k == "apertura":
                continue
            x, y = ra.get(k, {}), rb.get(k, {})
            lines.append(f"| {k} | {fmt(x.get('secondi'))} | {fmt(y.get('secondi'))} | {fmt(x.get('memoriaMassimaMB'), d=0)} | {fmt(y.get('memoriaMassimaMB'), d=0)} | "
                         f"{fmt(x.get('ritardoMassimoFinestraMs'), d=0)} | {fmt(y.get('ritardoMassimoFinestraMs'), d=0)} | {x.get('blocchiOltre50ms', '—')} | {y.get('blocchiOltre50ms', '—')} |")
        for name in sorted(set(ra.get("apertura", {})) | set(rb.get("apertura", {}))):
            x, y = ra.get("apertura", {}).get(name, {}), rb.get("apertura", {}).get(name, {})
            lines.append(f"| apertura {name} (prima / seconda volta) | {fmt(x.get('primaApertura'))} / {fmt(x.get('secondaApertura'))} | "
                         f"{fmt(y.get('primaApertura'))} / {fmt(y.get('secondaApertura'))} | | | | | | |")
        lines.append(f"| avvio (prima finestra, mediana di 3) | {fmt(a_start.get('mediana'), d=2)} | {fmt(b_start.get('mediana'), d=2)} | | | | | | |")
        lines.append("")
        # Passi della seconda separazione (modelli già aperti): dove va il tempo
        for k in sorted(set(ra) | set(rb)):
            if k == "apertura":
                continue
            for label, r in (("prima", ra), ("dopo", rb)):
                steps = r.get(k, {}).get("passi", [])
                if steps:
                    lines.append(f"- {k} {label}: " + ", ".join(f"{s['nome']} {s['secondi']:.1f} s" for s in steps) + f" · {r[k].get('motore', '')}")
        lines.append("")
        # Le tracce: il «dopo» rispetto al «prima»
        rows = []
        for tdir in sorted(glob.glob(os.path.join(a_dir, "tracce", "*", "*"))):
            rel = os.path.relpath(tdir, os.path.join(a_dir, "tracce"))
            other = os.path.join(b_dir, "tracce", rel)
            if not os.path.exists(other):
                rows.append((rel, None)); continue
            v = sdr(read(tdir), read(other))
            rows.append((rel, v))
            worst.append((m, rel, v))
        if rows:
            lines.append("Tracce dopo rispetto a prima: " + ", ".join(f"{r} {'identica' if v == math.inf else ('mancante' if v is None else f'{v:.0f} dB')}" for r, v in rows))
            lines.append("")
    bad = [(m, r, v) for m, r, v in worst if v is not None and v < 60]
    lines.append("**Qualità: " + ("tutte le tracce identiche o oltre 60 dB rispetto a prima.**" if worst and not bad
                                  else "nessuna traccia da confrontare.**" if not worst
                                  else "ATTENZIONE: " + ", ".join(f"{m} {r} {v:.1f} dB" for m, r, v in bad) + "**"))
    text = "\n".join(lines) + "\n"
    open(out, "w").write(text)
    print(text)
    json.dump({"tracce": [{"macchina": m, "traccia": r, "sdr": (None if v is None else ("identica" if v == math.inf else v))} for m, r, v in worst]},
              open(os.path.join(root, "confronto.json"), "w"), indent=1)
    if bad:
        print("::warning::Tracce diverse da prima: " + ", ".join(f"{m} {r} {v:.1f} dB" for m, r, v in bad))


if __name__ == "__main__":
    if sys.argv[1] == "canzone":
        song(sys.argv[2])
    else:
        compare(sys.argv[2], sys.argv[3])
