"""Converte o alinhador (wav2vec2 large, português) para Core ML e confere contra o PyTorch.
Saída em saida/Alinhador: Alinhador.mlmodelc (compilado depois, no workflow) + vocab.json; relatorio.txt."""
import json, os, sys, time, wave
import numpy as np
import torch
torch.backends.mps.is_available = lambda: False      # a GPU virtual do runner calcula errado: tudo no processador
torch.backends.mps.is_built = lambda: False
import coremltools as ct
from transformers import Wav2Vec2ForCTC, Wav2Vec2Processor
sys.path.insert(0, os.path.dirname(__file__))
from alinhar_ref import AMOSTRAS, emissoes, alinhar

MODELO = "jonatasgrosman/wav2vec2-large-xlsr-53-portuguese"
os.makedirs("saida/Alinhador", exist_ok=True)
rel = open("saida/relatorio.txt", "w")
def log(*a):
    s = " ".join(str(x) for x in a); print(s, flush=True); rel.write(s + "\n"); rel.flush()

log("torch", torch.__version__, "coremltools", ct.__version__)
proc = Wav2Vec2Processor.from_pretrained(MODELO)
modelo = Wav2Vec2ForCTC.from_pretrained(MODELO, attn_implementation="eager").eval()
tok = proc.tokenizer
vocab = tok.get_vocab()
especiais = [tok.pad_token, tok.unk_token, "|", tok.bos_token, tok.eos_token]
json.dump({"vocab": vocab, "branco": tok.pad_token_id, "separador": vocab["|"],
           "especiais": [e for e in especiais if e]}, open("saida/Alinhador/vocab.json", "w"), ensure_ascii=False)
log("vocabulário:", len(vocab), "símbolos; branco", tok.pad_token_id, "separador", vocab["|"])

class Saida(torch.nn.Module):
    """Sai o logit cru: o log-softmax é feito depois, em float32 (no app também). Em float16 ele dava -infinito."""
    def __init__(self, m): super().__init__(); self.m = m
    def forward(self, audio): return self.m(audio).logits

def log_softmax(x):
    x = x.astype(np.float64); m = x.max(-1, keepdims=True)
    return (x - m - np.log(np.exp(x - m).sum(-1, keepdims=True))).astype(np.float32)

with torch.no_grad():
    tr = torch.jit.trace(Saida(modelo).eval(), torch.zeros(1, AMOSTRAS), strict=False)

# conferência no áudio de teste: emissões e alinhamento, PyTorch (float32) x Core ML
w = wave.open("testes/crisper/audio16k.wav")
audio = np.frombuffer(w.readframes(w.getnframes()), dtype=np.int16).astype(np.float32) / 32768
dur = len(audio) / 16000
palavras = json.load(open("testes/crisper/referencia-gtpc.json"))["palavras"]

def rodar_torch(x):
    with torch.no_grad(): return log_softmax(Saida(modelo)(torch.from_numpy(x)[None])[0].numpy())
e_ref = emissoes(audio, rodar_torch)
ref, n_ref = alinhar(palavras, e_ref, dur, vocab, tok.pad_token_id, vocab["|"], set(especiais))
log("PyTorch: %d quadros, %d palavras alinhadas" % (e_ref.shape[0], n_ref))
json.dump({"palavras": ref}, open("saida/alinhado-pytorch.json", "w"), ensure_ascii=False)

# float16 nas contas pesadas e float32 nas sensíveis (normalizações, médias, raízes, softmax)
SENSIVEIS = {"layer_norm", "instance_norm", "batch_norm", "reduce_mean", "reduce_sum", "reduce_l2_norm",
             "pow", "sqrt", "rsqrt", "real_div", "softmax", "exp", "log", "gelu", "erf"}
variantes = [
    ("float16", ct.precision.FLOAT16),
    ("misto", ct.transform.FP16ComputePrecision(op_selector=lambda op: op.op_type not in SENSIVEIS)),
    ("float32", ct.precision.FLOAT32),
]
resultados = []
for nome_v, prec in variantes:
    t0 = time.time()
    try:
        ml = ct.convert(tr, inputs=[ct.TensorType(name="audio", shape=(1, AMOSTRAS), dtype=np.float32)],
                        outputs=[ct.TensorType(name="logits", dtype=np.float32)],
                        convert_to="mlprogram", compute_precision=prec,
                        minimum_deployment_target=ct.target.iOS17)
        caminho = "saida/v-%s.mlpackage" % nome_v
        ml.save(caminho)
    except Exception as ex:
        log(nome_v, ": conversão falhou:", repr(ex)); continue
    log("%s: convertido em %.0f s" % (nome_v, time.time() - t0))
    for nome, unid in [("processador", ct.ComputeUnit.CPU_ONLY), ("GPU", ct.ComputeUnit.CPU_AND_GPU)]:
        try:
            m = ct.models.MLModel(caminho, compute_units=unid)
            brutos = []
            def rodar(x):
                y = m.predict({"audio": x[None]})["logits"][0]; brutos.append(y); return log_softmax(y)
            e = emissoes(audio, rodar)
            b = np.concatenate(brutos)
            if not np.isfinite(e).all():
                log("  %s/%s: saída inválida (%d NaN, %d infinitos de %d valores)"
                    % (nome_v, nome, int(np.isnan(b).sum()), int(np.isinf(b).sum()), b.size)); continue
            acordo = (e.argmax(1) == e_ref.argmax(1)).mean() * 100
            dif = np.abs(np.exp(e) - np.exp(e_ref)).max()
            out, n = alinhar(palavras, e, dur, vocab, tok.pad_token_id, vocab["|"], set(especiais))
            d = np.array([max(abs(a["i"] - b2["i"]), abs(a["f"] - b2["f"])) for a, b2 in zip(out, ref)])
            log("  %s/%s: símbolo mais provável igual em %.2f%% dos quadros; maior diferença de probabilidade %.3f; "
                "fronteiras das palavras: média %.1f ms, máx %.0f ms, %d de %d idênticas"
                % (nome_v, nome, acordo, dif, d.mean() * 1000, d.max() * 1000, int((d < 0.001).sum()), len(d)))
            if nome == "processador":
                resultados.append((nome_v, caminho, d.mean(), d.max()))
        except Exception as ex:
            log("  %s/%s: falhou: %r" % (nome_v, nome, ex))

# escolhe: a primeira (menor) que bate com o PyTorch (média < 5 ms e máximo < 60 ms); senão a mais fiel
ok = [r for r in resultados if r[2] < 0.005 and r[3] < 0.06]
escolhida = ok[0] if ok else (min(resultados, key=lambda r: r[2]) if resultados else None)
if escolhida is None:
    log("NENHUMA variante deu saída válida"); rel.close(); sys.exit(1)
import shutil
shutil.copytree(escolhida[1], "saida/Alinhador.mlpackage")
log("escolhida: %s (média %.1f ms, máx %.0f ms)" % (escolhida[0], escolhida[2] * 1000, escolhida[3] * 1000))
rel.close()
