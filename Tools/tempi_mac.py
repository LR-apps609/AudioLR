# Il banco dei tempi del Mac (workflow «Tempi Mac»).
#
#   python Tools/tempi_mac.py canzone <uscita.wav>
#       La canzone di prova: gli estratti da 7 s di MUSDB18 (canzoni vere, con licenza per la ricerca) uno dopo
#       l'altro, 35 secondi. Sempre la stessa: «prima» e «dopo» separano esattamente lo stesso audio.
#
#   python Tools/tempi_mac.py confronto <cartella> <riepilogo.md>
#       <cartella>/banco-<macchina>/ con banco-prima.json, banco-dopo.json, avvio-<versione>-*.json e
#       tracce-<versione>/<prova>/<traccia>.wav: le due versioni misurate a turno sullo stesso Mac.
#       Scrive la tabella prima/dopo (media dei giri) e il confronto delle tracce: SDR del «dopo» rispetto al
#       «prima» (identica, oppure almeno 60 dB: differenze che non si sentono).
import sys, os, re, json, math, glob, wave
import numpy as np

RATE = 44100


def song(out):
    import musdb
    db = musdb.DB(root=os.environ.get("MUSDB_ROOT", "musdb"), download=True, subsets="test")
    parts = []
    for t in sorted(db, key=lambda t: t.name)[:5]:
        assert t.rate == RATE
        parts.append(t.audio.astype(np.float32))
    mix = np.clip(np.concatenate(parts), -1, 1)
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


def jload(p):
    try:
        return json.load(open(p))
    except Exception:
        return {}


def fmt(x, d=1):
    return "—" if x is None else f"{x:.{d}f}"


def mean(xs):
    xs = [x for x in xs if x is not None]
    return sum(xs) / len(xs) if xs else None


def pct(a, b):
    return "—" if a is None or b is None or a == 0 else f"{(b - a) / a * 100:+.0f}%"


def compare(root, out):
    lines = ["## Tempi Mac: prima e dopo, a turno sullo stesso Mac", ""]
    worst = []
    for mdir in sorted(glob.glob(os.path.join(root, "banco-*"))):
        m = os.path.basename(mdir)[len("banco-"):]
        runs = {v: jload(os.path.join(mdir, f"banco-{v}.json")) for v in ("prima", "dopo")}
        info = runs["dopo"].get("macchina") or runs["prima"].get("macchina") or {}
        lines += [f"### {m} · {info.get('processore', '?')} · {fmt(info.get('memoriaGB'), 0)} GB · "
                  f"Neural Engine: {'sì' if info.get('neuralEngine') else 'no'}", ""]
        # Le prove raggruppate per tipo (rapida-1, massima-2…), mediate sui giri
        kinds = {}
        for v in ("prima", "dopo"):
            for key, r in runs[v].get("prove", {}).items():
                kind = re.sub(r"^g\d+-", "", key)
                kinds.setdefault(kind, {"prima": [], "dopo": []})[v].append(r)
        lines += ["| Prova | giri | Secondi prima | dopo | diff | Memoria max prima (MB) | dopo | Ritardo finestra max prima (ms) | dopo | Blocchi >50 ms prima | dopo |",
                  "|---|---|---|---|---|---|---|---|---|---|---|"]
        for kind in sorted(kinds):
            if kind == "apertura":
                continue
            a, b = kinds[kind]["prima"], kinds[kind]["dopo"]
            g = lambda rs, k: mean([r.get(k) for r in rs])
            sa, sb = g(a, "secondi"), g(b, "secondi")
            lines.append(f"| {kind} | {len(a)}/{len(b)} | {fmt(sa)} | {fmt(sb)} | {pct(sa, sb)} | {fmt(g(a, 'memoriaMassimaMB'), 0)} | {fmt(g(b, 'memoriaMassimaMB'), 0)} | "
                         f"{fmt(g(a, 'ritardoMassimoFinestraMs'), 0)} | {fmt(g(b, 'ritardoMassimoFinestraMs'), 0)} | {fmt(g(a, 'blocchiOltre50ms'), 0)} | {fmt(g(b, 'blocchiOltre50ms'), 0)} |")
        for name in ("HTDemucs", "StrumentiSW2"):
            a = [r.get(name, {}) for r in kinds.get("apertura", {}).get("prima", [])]
            b = [r.get(name, {}) for r in kinds.get("apertura", {}).get("dopo", [])]
            if a or b:
                lines.append(f"| apertura {name}: prima volta / seconda | | {fmt(mean([x.get('primaApertura') for x in a]))} / {fmt(mean([x.get('secondaApertura') for x in a]))} | "
                             f"{fmt(mean([x.get('primaApertura') for x in b]))} / {fmt(mean([x.get('secondaApertura') for x in b]))} | | | | | | | |")
        starts = {}
        for v in ("prima", "dopo"):
            meds = [jload(p).get("mediana") for p in glob.glob(os.path.join(mdir, f"avvio-{v}-*.json"))]
            starts[v] = mean([x for x in meds if x is not None and x >= 0])
        lines.append(f"| avvio (prima finestra, mediana) | | {fmt(starts['prima'], 2)} | {fmt(starts['dopo'], 2)} | {pct(starts['prima'], starts['dopo'])} | | | | | | |")
        lines.append("")
        # Dove va il tempo, per ogni prova
        for v in ("prima", "dopo"):
            for key, r in sorted(runs[v].get("prove", {}).items()):
                if "passi" in r:
                    lines.append(f"- {v} {key}: " + ", ".join(f"{s['nome']} {s['secondi']:.1f} s" for s in r["passi"]) + f" · {r.get('motore', '')}")
        lines.append("")
        # Le tracce: il «dopo» rispetto al «prima», prova per prova
        rows = []
        for tpath in sorted(glob.glob(os.path.join(mdir, "tracce-prima", "*", "*"))):
            rel = os.path.relpath(tpath, os.path.join(mdir, "tracce-prima"))
            other = os.path.join(mdir, "tracce-dopo", rel)
            v = sdr(read(tpath), read(other)) if os.path.exists(other) else None
            rows.append((rel, v))
            if v is not None:
                worst.append((m, rel, v))
        if rows:
            same = sum(1 for _, v in rows if v == math.inf)
            lines.append(f"Tracce dopo rispetto a prima: {same} identiche su {len(rows)}; " +
                         ", ".join(f"{r} {'mancante' if v is None else f'{v:.0f} dB'}" for r, v in rows if v != math.inf))
            lines.append("")
    bad = [(m, r, v) for m, r, v in worst if v < 60]
    lines.append("**Qualità: " + ("tutte le tracce identiche o oltre 60 dB rispetto a prima.**" if worst and not bad
                                  else "nessuna traccia da confrontare.**" if not worst
                                  else "ATTENZIONE: " + ", ".join(f"{m} {r} {v:.1f} dB" for m, r, v in bad) + "**"))
    text = "\n".join(lines) + "\n"
    open(out, "w").write(text)
    print(text)
    json.dump({"tracce": [{"macchina": m, "traccia": r, "sdr": ("identica" if v == math.inf else v)} for m, r, v in worst]},
              open(os.path.join(root, "confronto.json"), "w"), indent=1)
    if bad:
        print("::warning::Tracce diverse da prima: " + ", ".join(f"{m} {r} {v:.1f} dB" for m, r, v in bad))


if __name__ == "__main__":
    if sys.argv[1] == "canzone":
        song(sys.argv[2])
    else:
        compare(sys.argv[2], sys.argv[3])
