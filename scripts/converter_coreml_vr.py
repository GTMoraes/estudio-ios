"""Converte UVR-DeEcho-DeReverb.pth (PyTorch) direto para Core ML (.mlpackage), float32.
Uso: python converter_coreml_vr.py <UVR-DeEcho-DeReverb.pth> <pasta de saída> <UVR-DeEcho-DeReverb.onnx para conferir>
O ONNX desse modelo tem LSTM, que o caminho ONNX->PyTorch não converte; por isso parte do .pth."""
import sys, os, numpy as np, torch, coremltools as ct
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "tratar-voz", "exportar"))  # rede_vr.py do motor_voz
from rede_vr import CascadedNet

class Mascara(torch.nn.Module):
    def __init__(self, n): super().__init__(); self.n = n
    def forward(self, x): return self.n.predict_mask(x)

pth, saida = sys.argv[1], sys.argv[2]
net = CascadedNet(672 * 2, 218409, nout=32, nout_lstm=128)
net.load_state_dict(torch.load(pth, map_location="cpu")); net.eval()
m = Mascara(net).eval()
x = torch.rand(1, 2, 673, 512)
with torch.no_grad():
    tr = torch.jit.trace(m, x)
    import onnxruntime as ort
    ref = ort.InferenceSession(sys.argv[3]).run(["mask"], {"input": x.numpy()})[0]
    yt = tr(x).numpy()
    print("trace x onnx: %.1f dB" % (10*np.log10((ref.astype(np.float64)**2).sum()/((ref-yt)**2).sum())), yt.shape, flush=True)
# numpy 2: o coremltools falha ao converter um tamanho de 1 elemento em int; corrige aqui
from coremltools.converters.mil.frontend.torch import ops as _ops
from coremltools.converters.mil import Builder as mb
_cast_orig = _ops._cast
def _cast(context, node, dtype, dtype_name):
    x = _ops._get_inputs(context, node, expected=1)[0]
    if x.can_be_folded_to_const() and not isinstance(x.val, dtype):
        context.add(mb.const(val=dtype(np.asarray(x.val).item()), name=node.name), node.name)
        return
    _cast_orig(context, node, dtype, dtype_name)
_ops._cast = _cast
ml = ct.convert(tr, inputs=[ct.TensorType(name="input", shape=(1, 2, 673, 512), dtype=np.float32)],
                outputs=[ct.TensorType(name="output", dtype=np.float32)],
                convert_to="mlprogram", compute_precision=ct.precision.FLOAT32,
                minimum_deployment_target=ct.target.iOS17)
ml.short_description = "UVR-DeEcho-DeReverb (motor de voz do Estúdio, float32)"
ml.save(os.path.join(saida, "UVR-DeEcho-DeReverb.mlpackage"))
print("salvo", flush=True)
