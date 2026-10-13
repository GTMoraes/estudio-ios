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
    def __init__(self, m): super().__init__(); self.m = m
    def forward(self, audio): return torch.log_softmax(self.m(audio).logits, dim=-1)

t0 = time.time()
with torch.no_grad():
    tr = torch.jit.trace(Saida(modelo), torch.zeros(1, AMOSTRAS), strict=False)
ml = ct.convert(tr, inputs=[ct.TensorType(name="audio", shape=(1, AMOSTRAS), dtype=np.float32)],
                outputs=[ct.TensorType(name="logprobs", dtype=np.float32)],
                convert_to="mlprogram", compute_precision=ct.precision.FLOAT16,
                minimum_deployment_target=ct.target.iOS17)
ml.save("saida/Alinhador.mlpackage")
log("convertido em %.0f s" % (time.time() - t0))

# conferência no áudio de teste: emissões e alinhamento, PyTorch (float32) x Core ML (float16)
w = wave.open("testes/crisper/audio16k.wav")
audio = np.frombuffer(w.readframes(w.getnframes()), dtype=np.int16).astype(np.float32) / 32768
dur = len(audio) / 16000
palavras = json.load(open("testes/crisper/referencia-gtpc.json"))["palavras"]

def rodar_torch(x):
    with torch.no_grad(): return Saida(modelo)(torch.from_numpy(x)[None])[0].numpy()
e_ref = emissoes(audio, rodar_torch)
ref, n_ref = alinhar(palavras, e_ref, dur, vocab, tok.pad_token_id, vocab["|"], set(especiais))
log("PyTorch: %d quadros, %d palavras alinhadas" % (e_ref.shape[0], n_ref))
json.dump({"palavras": ref}, open("saida/alinhado-pytorch.json", "w"), ensure_ascii=False)

for nome, unid in [("processador", ct.ComputeUnit.CPU_ONLY), ("GPU", ct.ComputeUnit.CPU_AND_GPU)]:
    try:
        m = ct.models.MLModel("saida/Alinhador.mlpackage", compute_units=unid)
        e = emissoes(audio, lambda x: m.predict({"audio": x[None]})["logprobs"][0])
        if not np.isfinite(e).all():
            log(nome, ": saída com NaN/infinito"); continue
        acordo = (e.argmax(1) == e_ref.argmax(1)).mean() * 100
        dif = np.abs(np.exp(e) - np.exp(e_ref)).max()
        out, n = alinhar(palavras, e, dur, vocab, tok.pad_token_id, vocab["|"], set(especiais))
        d = np.array([max(abs(a["i"] - b["i"]), abs(a["f"] - b["f"])) for a, b in zip(out, ref)])
        log("%s: símbolo mais provável igual em %.2f%% dos quadros; maior diferença de probabilidade %.3f; "
            "fronteiras das palavras: média %.1f ms, máx %.0f ms, %d de %d idênticas"
            % (nome, acordo, dif, d.mean() * 1000, d.max() * 1000, int((d < 0.001).sum()), len(d)))
    except Exception as ex:
        log(nome, ": falhou:", repr(ex))
rel.close()
