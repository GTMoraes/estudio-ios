"""Converte os modelos de voz (ONNX) para Core ML nativo (.mlpackage), em float32.
Uso: python converter.py <pasta com os .onnx> <pasta de saída> [Kim_Vocal_2|UVR-DeEcho-DeReverb]"""
import sys, os, gc, numpy as np, torch, onnx, coremltools as ct
from onnx2torch import convert

MODELOS = {"Kim_Vocal_2": (1, 4, 3072, 256), "UVR-DeEcho-DeReverb": (1, 2, 673, 512)}
entrada, saida = sys.argv[1], sys.argv[2]
nomes = sys.argv[3:] or list(MODELOS)
os.makedirs(saida, exist_ok=True)
for nome in nomes:
    forma = MODELOS[nome]
    m = onnx.load(os.path.join(entrada, nome + ".onnx"))
    for v in list(m.graph.input) + list(m.graph.output):      # lote fixo = 1
        d = v.type.tensor_type.shape.dim
        if d and not d[0].dim_value: d[0].dim_value = 1
    rede = convert(m).eval()
    del m; gc.collect()
    x = torch.zeros(*forma)
    with torch.no_grad():
        ep = torch.export.export(rede, (x,))                   # sem rodar o modelo de verdade
    ep = ep.run_decompositions({})
    ml = ct.convert(ep, inputs=[ct.TensorType(name="input", shape=forma, dtype=np.float32)],
                    outputs=[ct.TensorType(name="output", dtype=np.float32)],
                    convert_to="mlprogram", compute_precision=ct.precision.FLOAT32,
                    minimum_deployment_target=ct.target.iOS17)
    ml.short_description = nome + " (motor de voz do Estúdio, float32)"
    ml.save(os.path.join(saida, nome + ".mlpackage"))
    print(f"{nome}: salvo", flush=True)
    del ml, ep, rede; gc.collect()
