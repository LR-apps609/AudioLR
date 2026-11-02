"""«Togli rumore»: DeepFilterNet3 (Hendrik Schröter, MIT o Apache 2.0) in Core ML (Mac) e ONNX (Windows).

Uso: python Tools/convert_deepfilter.py <cartella DeepFilterNet3 con config.ini e checkpoints>
Esce: DeepFilter.mlpackage, DeepFilter.onnx, DeepFilter.json, DeepFilter-prova.f32.
Si converte solo la rete (codificatore e due decodificatori), a pezzi fissi di FRAMES fotogrammi; il calcolo intorno
è in deepfilter_ref.py ed è rifatto uguale in Swift e JavaScript. Le prove confrontano tutto con l'«enhance»
originale del pacchetto deepfilternet.
"""
import json
import os
import sys

import numpy as np
import torch

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import deepfilter_ref as R  # noqa: E402
from df import modules as dfm  # noqa: E402
from df.enhance import enhance, init_df  # noqa: E402


def snr(ref, x):
    ref, x = np.asarray(ref, np.float64), np.asarray(x, np.float64)
    return 10 * np.log10(np.sum(ref ** 2) / max(np.sum((ref - x) ** 2), 1e-20))


# L'einsum dei livelli lineari a gruppi come moltiplicazione di matrici a lotti: Core ML e ONNX la fanno meglio
def _grouped(self, x):
    shape = list(x.shape)
    new = shape[:-1] + [self.groups, self.ws]
    x = x.view(new)
    b = x.shape[:-2]
    x = x.reshape(-1, self.groups, self.ws).transpose(0, 1)          # [G, N, I]
    x = torch.bmm(x, self.weight).transpose(0, 1)                     # [N, G, H]
    return x.reshape(list(b) + [self.groups * self.weight.shape[-1]])


dfm.GroupedLinearEinsum.forward = _grouped


class Net(torch.nn.Module):
    """Le entrate già pronte (feat_erb [1,1,T,32], feat_spec [1,2,T,96]) → maschera ERB e coefficienti del filtro."""

    def __init__(self, model):
        super().__init__()
        self.enc, self.erb_dec, self.df_dec = model.enc, model.erb_dec, model.df_dec

    def forward(self, feat_erb, feat_spec):
        # Come pad_feat: la rete guarda 2 fotogrammi avanti
        k = R.CONV_LOOK
        fe = torch.cat([feat_erb[:, :, k:], torch.zeros_like(feat_erb[:, :, :k])], 2)
        fs = torch.cat([feat_spec[:, :, k:], torch.zeros_like(feat_spec[:, :, :k])], 2)
        e0, e1, e2, e3, emb, c0, _ = self.enc(fe, fs)
        m = self.erb_dec(emb, e3, e2, e1, e0)
        c = self.df_dec(emb, c0)
        return m, c


def test_signal(seconds=6.0, seed=1):
    """Una «voce» sintetica (armoniche con vibrato e frasi) dentro un rumore rosa a circa 5 dB."""
    rng = np.random.default_rng(seed)
    n = int(seconds * R.SR)
    t = np.arange(n) / R.SR
    f0 = 220 * 2 ** (np.floor(t * 1.5) % 5 / 12) * (1 + 0.01 * np.sin(2 * np.pi * 5.5 * t))
    ph = 2 * np.pi * np.cumsum(f0) / R.SR
    voice = sum(np.sin(k * ph) / k for k in range(1, 12))
    env = (np.sin(2 * np.pi * 0.75 * t) > -0.2).astype(float)
    env = np.convolve(env, np.ones(2400) / 2400, "same")
    voice = 0.15 * voice * env
    white = rng.standard_normal(n)
    pink = np.fft.irfft(np.fft.rfft(white) / np.sqrt(np.maximum(np.arange(n // 2 + 1), 1)), n)
    pink *= np.sqrt(np.mean(voice ** 2) / np.mean(pink ** 2)) / 10 ** (5 / 20)
    return voice.astype(np.float32), (voice + pink).astype(np.float32)


def main():
    base = sys.argv[1]
    model, state, *_ = init_df(model_base_dir=base, post_filter=False, log_level="ERROR")
    model.eval()
    assert list(state.erb_widths()) == R.WIDTHS, "bande ERB diverse da deepfilter_ref"
    net = Net(model).eval()

    clean, noisy = test_signal()
    with torch.no_grad():
        official = enhance(model, state, torch.from_numpy(noisy)[None], pad=True)[0].numpy()

        def torch_net(fe, fs):
            m, c = net(torch.from_numpy(fe), torch.from_numpy(fs))
            return m.numpy(), c.numpy()

        # 1) Il calcolo intorno alla rete, sull'intera traccia in un pezzo solo, uguale all'originale
        def whole(fe, fs):
            return torch_net(fe, fs)
        n = len(noisy)
        xp = np.concatenate([noisy, np.zeros(R.FFT, np.float32)])
        spec = R.analysis(xp)
        erb, low = R.features(spec)
        m, c = whole(*R.net_inputs(erb, low))
        y_whole = R.synthesis(R.apply(spec, m[0, 0], c[0]))[R.FFT - R.HOP:R.FFT - R.HOP + n]
        print(f"STFT e caratteristiche come l'originale: {snr(official, y_whole):.1f} dB")
        assert snr(official, y_whole) > 50
        # 2) A pezzi di FRAMES fotogrammi
        y_torch = R.enhance(noisy, torch_net)
        print(f"A pezzi di {R.FRAMES} fotogrammi contro l'originale: {snr(official, y_torch):.1f} dB")
        assert snr(official, y_torch) > 25
    print(f"Rumore: prima {snr(clean, noisy):.1f} dB, dopo {snr(clean, official):.1f} dB (originale), {snr(clean, y_torch):.1f} dB (IsoLR)")

    fe0 = torch.zeros(1, 1, R.FRAMES, R.NB_ERB)
    fs0 = torch.zeros(1, 2, R.FRAMES, R.NB_DF)
    # ONNX per Windows
    torch.onnx.export(net, (fe0, fs0), "DeepFilter.onnx", input_names=["feat_erb", "feat_spec"], output_names=["m", "coefs"],
                      opset_version=17)
    import onnxruntime as ort
    sess = ort.InferenceSession("DeepFilter.onnx", providers=["CPUExecutionProvider"])
    y_onnx = R.enhance(noisy, lambda fe, fs: sess.run(None, {"feat_erb": fe, "feat_spec": fs}))
    print(f"ONNX contro torch: {snr(y_torch, y_onnx):.1f} dB")
    assert snr(y_torch, y_onnx) > 50

    # Core ML per il Mac, a 32 bit (la rete è piccola; le GRU a 16 bit sbagliano)
    import coremltools as ct
    traced = torch.jit.trace(net, (fe0, fs0))
    ml = ct.convert(traced, convert_to="mlprogram",
                    inputs=[ct.TensorType(name="feat_erb", shape=fe0.shape), ct.TensorType(name="feat_spec", shape=fs0.shape)],
                    outputs=[ct.TensorType(name="m"), ct.TensorType(name="coefs")],
                    compute_precision=ct.precision.FLOAT32, minimum_deployment_target=ct.target.macOS14)
    ml.short_description = "DeepFilterNet3 (Hendrik Schröter, MIT o Apache 2.0): la rete di «Togli rumore»"
    ml.save("DeepFilter.mlpackage")
    if sys.platform == "darwin":
        ml2 = ct.models.MLModel("DeepFilter.mlpackage", compute_units=ct.ComputeUnit.CPU_ONLY)

        def coreml(fe, fs):
            o = ml2.predict({"feat_erb": fe, "feat_spec": fs})
            return o["m"], o["coefs"]
        y_ml = R.enhance(noisy, coreml)
        print(f"Core ML contro torch: {snr(y_torch, y_ml):.1f} dB")
        assert snr(y_torch, y_ml) > 40

    json.dump({"kind": "deepfilter", "sr": R.SR, "fft": R.FFT, "hop": R.HOP, "nb_erb": R.NB_ERB, "nb_df": R.NB_DF,
               "order": R.ORDER, "lookahead": R.LOOK, "alpha": R.ALPHA, "frames": R.FRAMES, "ctx": R.CTX,
               "widths": R.WIDTHS, "license": "DeepFilterNet3, Hendrik Schröter, MIT o Apache 2.0",
               "db": round(float(snr(clean, y_torch) - snr(clean, noisy)), 2)}, open("DeepFilter.json", "w"))
    # La prova per l'app: 3 s di entrata a 48 kHz e l'uscita attesa (quella di torch a pezzi)
    k = 3 * R.SR
    y3 = R.enhance(noisy[:k], torch_net)
    with open("DeepFilter-prova.f32", "wb") as f:
        np.array([k], np.float32).tofile(f)
        noisy[:k].astype(np.float32).tofile(f)
        y3.astype(np.float32).tofile(f)
    print("Fatto: DeepFilter.mlpackage, DeepFilter.onnx, DeepFilter.json, DeepFilter-prova.f32")


if __name__ == "__main__":
    main()
