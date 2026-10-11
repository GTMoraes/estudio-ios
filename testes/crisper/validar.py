"""Confere se o CrisperWhisper convertido para o formato do iPhone (Core ML) dá o mesmo
resultado que o modelo original.

Para cada trecho de 30 s do áudio de teste:
  - referência: o pacote oficial (crisperwhisper, motor PyTorch) decodifica com o prompt
    "verbatim" em português;
  - Core ML: os três modelos convertidos (MelSpectrogram, AudioEncoder, TextDecoder) fazem a
    mesma decodificação, token a token, como o iPhone fará.
Compara os tokens, o texto e a atenção usada para os tempos das palavras.

Uso: python validar.py <pasta-com-os-.mlmodelc> audio16k.wav saida.json
"""
import json, sys, time, wave
from pathlib import Path

import numpy as np
import coremltools as ct

from crisperwhisper.transformers_engine import TransformersEngine
from crisperwhisper.prompt import PromptBuilder, strip_prompt_artifacts

PASTA, WAV, SAIDA = Path(sys.argv[1]), sys.argv[2], sys.argv[3]
MODELO = "nyralabs/CrisperWhisper2.0_turbo"
MAX_NOVOS = 256
JANELA = 480000


def esquema(mlmodelc):
    m = json.load(open(mlmodelc / "metadata.json"))[0]
    def lista(chave):
        r = {}
        for e in m.get(chave, []):
            forma = e.get("shape") or "[]"
            try: forma = json.loads(forma)
            except Exception: pass
            r[e["name"]] = {"forma": forma, "tipo": e.get("dataType", "")}
        return r
    return lista("inputSchema"), lista("outputSchema")


def tipo_np(t):
    t = t.lower()
    if "float16" in t: return np.float16
    if "int32" in t: return np.int32
    return np.float32


def carregar(nome):
    p = PASTA / f"{nome}.mlmodelc"
    ent, sai = esquema(p)
    print(f"[{nome}] entradas: {json.dumps(ent)}")
    print(f"[{nome}] saídas:   {json.dumps(sai)}")
    return ct.models.CompiledMLModel(str(p), compute_units=ct.ComputeUnit.CPU_ONLY), ent, sai


with wave.open(WAV) as w:
    audio = np.frombuffer(w.readframes(w.getnframes()), dtype=np.int16).astype(np.float32) / 32768.0
print(f"áudio: {len(audio) / 16000:.1f} s")

t0 = time.time()
eng = TransformersEngine(MODELO, device="cpu", compute_type="float32")
eng.enable_attention(None)
prompt = PromptBuilder(eng, language="pt").verbatim()
supr = eng._resolve_suppress(None)
print("prompt:", prompt, repr(eng.tokenizer.decode(prompt)))
print("cabeças de alinhamento (referência):", eng.default_alignment_heads)
print(f"referência carregada em {time.time() - t0:.0f} s")

mel_m, mel_e, mel_s = carregar("MelSpectrogram")
enc_m, enc_e, enc_s = carregar("AudioEncoder")
dec_m, dec_e, dec_s = carregar("TextDecoder")

kc = dec_e["key_cache"]["forma"]
L = kc[-1]
tipo_cache = tipo_np(dec_e["key_cache"]["tipo"])
print(f"decodificador: cache {kc}, até {L} posições")


def coreml_trecho(trecho):
    a = np.zeros(JANELA, dtype=np.float32); a[:len(trecho)] = trecho
    mel_nome = list(mel_e)[0]
    mel = mel_m.predict({mel_nome: a.astype(tipo_np(mel_e[mel_nome]["tipo"]))})
    mel_saida = mel[list(mel_s)[0]]
    enc_nome = list(enc_e)[0]
    enc = enc_m.predict({enc_nome: mel_saida.astype(tipo_np(enc_e[enc_nome]["tipo"]))})

    kcache = np.zeros(kc, dtype=tipo_cache); vcache = np.zeros(kc, dtype=tipo_cache)
    gerados, linhas = [], []
    seq = list(prompt)
    pos = 0
    while pos < L - 1:
        tok = seq[pos]
        feed = {
            "input_ids": np.array([tok], dtype=np.int32),
            "cache_length": np.array([pos], dtype=np.int32),
            "key_cache": kcache, "value_cache": vcache,
        }
        if "kv_cache_update_mask" in dec_e:
            m = np.zeros((1, L), dtype=tipo_np(dec_e["kv_cache_update_mask"]["tipo"])); m[0, pos] = 1
            feed["kv_cache_update_mask"] = m
        if "decoder_key_padding_mask" in dec_e:
            m = np.full((1, L), -10000, dtype=tipo_np(dec_e["decoder_key_padding_mask"]["tipo"])); m[0, :pos + 1] = 0
            feed["decoder_key_padding_mask"] = m
        for nome in dec_e:                                  # o que vem do codificador, pelo nome
            if nome not in feed and nome in enc:
                feed[nome] = enc[nome].astype(tipo_np(dec_e[nome]["tipo"]))
        faltando = [n for n in dec_e if n not in feed]
        if faltando: raise SystemExit(f"entradas do decodificador que não sei preencher: {faltando}")
        out = dec_m.predict(feed)
        kcache[..., pos] = out["key_cache_updates"][..., 0]
        vcache[..., pos] = out["value_cache_updates"][..., 0]
        if pos >= len(prompt) - 1:
            logits = np.array(out["logits"], dtype=np.float32).reshape(-1)
            if supr: logits[[s for s in supr if s < len(logits)]] = -np.inf
            prox = int(np.argmax(logits))
            if "alignment_heads_weights" in out:
                linhas.append(np.array(out["alignment_heads_weights"], dtype=np.float32).reshape(-1))
            if prox == eng.eot_id or len(gerados) >= MAX_NOVOS: break
            gerados.append(prox); seq.append(prox)
        pos += 1
    return gerados, (np.stack(linhas[:len(gerados)]) if linhas else None), np.array(mel_saida, dtype=np.float32)


resultado = {"trechos": [], "prompt": prompt}
iguais = total = 0
for k in range(0, len(audio), JANELA):
    trecho = audio[k:k + JANELA]
    feats, mel_ref = eng.extract_features_with_mel(trecho)
    t1 = time.time()
    ref_ids, ref_att = eng._run_generate_with_attention(feats, prompt, MAX_NOVOS, suppress_tokens=None)
    t2 = time.time()
    cm_ids, cm_att, cm_mel = coreml_trecho(trecho)
    t3 = time.time()
    n = min(len(ref_ids), len(cm_ids))
    primeiro_dif = next((i for i in range(n) if ref_ids[i] != cm_ids[i]), None if len(ref_ids) == len(cm_ids) else n)
    igual = primeiro_dif is None
    iguais += igual; total += 1
    corr = None
    if cm_att is not None and ref_att.size and igual:
        a, b = ref_att.reshape(-1), cm_att.reshape(-1)
        corr = float(np.corrcoef(a, b)[0, 1])
    mel_dif = float(np.abs(mel_ref[:, :3000] - cm_mel.reshape(mel_ref.shape[0], -1)[:, :3000]).max())
    item = {
        "inicio_s": k / 16000,
        "tokens_iguais": igual, "primeira_diferenca": primeiro_dif,
        "ref_texto": strip_prompt_artifacts(eng.decode_tokens(ref_ids)),
        "coreml_texto": strip_prompt_artifacts(eng.decode_tokens(cm_ids)),
        "ref_tokens": len(ref_ids), "coreml_tokens": len(cm_ids),
        "correlacao_atencao": corr, "mel_maior_diferenca": mel_dif,
        "seg_ref": round(t2 - t1, 1), "seg_coreml": round(t3 - t2, 1),
    }
    resultado["trechos"].append(item)
    print(json.dumps(item, ensure_ascii=False))
    if cm_att is not None:
        np.save(Path(SAIDA).with_suffix(f".att{k // JANELA:02d}.npy"), cm_att)

resultado["resumo"] = f"{iguais} de {total} trechos com tokens idênticos"
print("RESUMO:", resultado["resumo"])
json.dump(resultado, open(SAIDA, "w", encoding="utf-8"), ensure_ascii=False, indent=1)
