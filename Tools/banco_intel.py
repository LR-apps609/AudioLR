# Banco del Mac Intel: quanto ci mette UN pezzo (8 s) del modello strumenti con i diversi motori di calcolo.
#   coreml-tutto   Core ML come oggi nell'app (modello a 16 bit, «tutti i motori»)
#   coreml-cpu     Core ML solo processore (16 bit)
#   onnx-32        ONNX Runtime sul processore, modello a 32 bit (quello di Windows)
#   onnx-8         ONNX Runtime, pesi a 8 bit (quantizzazione dinamica), più leggero
# La fedeltà di ogni variante si misura sulla maschera rispetto a ONNX 32 bit, sullo stesso pezzo di canzone vera
# (il file «-prova.f32»). Nessun dato va fuori: i numeri finiscono nel registro di questa prova.
import json, os, sys, time
import numpy as np

cartella = sys.argv[1]
giri = int(os.environ.get("GIRI", "3"))
cfg = json.load(open(f"{cartella}/StrumentiSW.json"))
N, HOP, T, FI = cfg["n_fft"], cfg["hop"], cfg["frames"], cfg["freq_indices"]
raw = np.fromfile(f"{cartella}/StrumentiSW2-prova.f32", dtype="<f4")
chunk = int(raw[0])
mix = raw[2:2 + 2 * chunk].reshape(2, chunk)

# Ingresso come nell'app: STFT centrata con finestra di Hann, poi le frequenze delle bande (reale, immaginaria)
win = np.hanning(N + 1)[:-1].astype(np.float64)
def stft(x):
    p = np.pad(x.astype(np.float64), N // 2, mode="reflect")
    fr = np.lib.stride_tricks.sliding_window_view(p, N)[::HOP][:T]
    return np.fft.rfft(fr * win, axis=1).T  # [frequenze, istanti]
z = [stft(mix[c]) for c in range(2)]
x = np.zeros((1, T, len(FI) * 2), dtype=np.float32)
for j, g in enumerate(FI):
    f, s = g // 2, g % 2
    x[0, :, j * 2] = z[s][f].real
    x[0, :, j * 2 + 1] = z[s][f].imag

def snr(ref, out):
    ref, out = ref.astype(np.float64).ravel(), out.astype(np.float64).ravel()
    return 10 * np.log10(np.sum(ref ** 2) / max(np.sum((ref - out) ** 2), 1e-20))

def cronometro(nome, run):
    t0 = time.time(); out = run(); prima = time.time() - t0
    tempi = []
    for _ in range(giri):
        t0 = time.time(); out = run(); tempi.append(time.time() - t0)
    print(f"RISULTATO {nome}: primo {prima:.1f} s · poi {min(tempi):.1f}–{max(tempi):.1f} s a pezzo", flush=True)
    return out, min(tempi)

risultati = {}
import onnxruntime as ort
print("ONNX Runtime", ort.__version__, "· processori", os.cpu_count(), flush=True)
opz = ort.SessionOptions()
opz.graph_optimization_level = ort.GraphOptimizationLevel.ORT_ENABLE_ALL
s32 = ort.InferenceSession(f"{cartella}/StrumentiSW.onnx", opz, providers=["CPUExecutionProvider"])
nome_in = s32.get_inputs()[0].name
print("ingresso ONNX", s32.get_inputs()[0].shape, "· uscite", [o.name for o in s32.get_outputs()], flush=True)
rif, t = cronometro("onnx-32", lambda: s32.run(None, {nome_in: x})[0])
risultati["onnx-32"] = (t, None)
del s32

if not os.environ.get("SENZA_8"):
    from onnxruntime.quantization import quantize_dynamic, QuantType
    t0 = time.time()
    quantize_dynamic(f"{cartella}/StrumentiSW.onnx", f"{cartella}/StrumentiSW-8.onnx", weight_type=QuantType.QInt8,
                     op_types_to_quantize=["MatMul", "Gemm"], extra_options={"MatMulConstBOnly": True})
    print(f"quantizzazione a 8 bit: {time.time() - t0:.0f} s · {os.path.getsize(f'{cartella}/StrumentiSW-8.onnx') / 1e6:.0f} MB", flush=True)
    s8 = ort.InferenceSession(f"{cartella}/StrumentiSW-8.onnx", opz, providers=["CPUExecutionProvider"])
    out, t = cronometro("onnx-8", lambda: s8.run(None, {nome_in: x})[0])
    risultati["onnx-8"] = (t, snr(rif, out))
    del s8

import coremltools as ct
for nome, unita in [("coreml-tutto", ct.ComputeUnit.ALL), ("coreml-cpu", ct.ComputeUnit.CPU_ONLY)]:
    t0 = time.time()
    m = ct.models.MLModel(f"{cartella}/StrumentiSW2.mlpackage", compute_units=unita)
    print(f"{nome}: apertura {time.time() - t0:.0f} s", flush=True)
    # Il modello del Mac ha qualche istante in più o in meno: si confronta sulla parte comune
    tm = m.get_spec().description.input[0].type.multiArrayType.shape
    xm = np.zeros(tuple(tm), dtype=np.float32)
    k = min(xm.shape[1], x.shape[1])
    xm[:, :k] = x[:, :k]
    out, t = cronometro(nome, lambda: m.predict({"x": xm})["mask"])
    o = np.asarray(out)
    q = snr(rif, o) if o.shape == rif.shape else None
    if q is None: print(f"{nome}: uscita {o.shape} diversa da ONNX {rif.shape}, fedeltà non confrontabile")
    risultati[nome] = (t, q)
    del m

base = risultati["coreml-tutto"][0]
print("\nTABELLA (secondi per pezzo da 8 s · quanto più veloce di oggi · fedeltà rispetto a ONNX 32 bit)")
for k, (t, q) in risultati.items():
    print(f"TABELLA {k:14s} {t:7.1f} s   ×{base / t:4.1f}   {'' if q is None else f'{q:.1f} dB'}")
