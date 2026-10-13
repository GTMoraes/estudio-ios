"""Alinhamento de referência (o mesmo algoritmo do app, em numpy), para conferir o modelo convertido.
emissoes(): log-probabilidades a cada 20 ms em janelas de 24 s (20 s úteis + 2 s de contexto de cada lado).
alinhar(): CTC Viterbi por grupos de ~20 s; cada grupo começa onde o anterior terminou."""
import unicodedata
import numpy as np

AMOSTRAS = 384000          # 24 s a 16 kHz (entrada fixa do modelo)
JAN, CTX, QUADRO = 20.0, 2.0, 0.02


def janela(audio, a, b):
    """Trecho [a, b) normalizado (média 0, desvio 1) e completado com zeros até 24 s."""
    x = audio[int(a * 16000):int(b * 16000)].astype(np.float32)
    x = (x - x.mean()) / (x.std() + 1e-7) if len(x) else x
    out = np.zeros(AMOSTRAS, np.float32)
    out[:min(len(x), AMOSTRAS)] = x[:AMOSTRAS]
    return out


def emissoes(audio, rodar):
    """rodar(x[384000]) -> logprobs [quadros, V]."""
    dur = len(audio) / 16000
    blocos, s = [], 0.0
    while s < dur:
        a, b = max(0.0, s - CTX), min(dur, s + JAN + CTX)
        lp = rodar(janela(audio, a, b))
        q0 = int(round((s - a) / QUADRO))
        q1 = q0 + int(round(min(JAN, dur - s) / QUADRO))
        blocos.append(lp[q0:min(q1, lp.shape[0])])
        s += JAN
    return np.concatenate(blocos)


def letras(p, vocab, especiais):
    s = unicodedata.normalize("NFC", p.lower())
    return [c for c in s if c in vocab and c not in especiais]


def viterbi(e, alvo, branco):
    """CTC forçado: e [T, V] log-probs, alvo [L] ids. Devolve, por símbolo do alvo, (quadro inicial, final+1)."""
    T, L = e.shape[0], len(alvo)
    S = 2 * L + 1
    rot = np.full(S, branco, np.int64); rot[1::2] = alvo
    pode2 = np.zeros(S, bool)
    for s in range(3, S, 2):
        pode2[s] = rot[s] != rot[s - 2]
    NEG = -1e30
    a = np.full(S, NEG); a[0] = e[0, branco]
    if S > 1: a[1] = e[0, rot[1]]
    volta = np.zeros((T, S), np.int8)
    for t in range(1, T):
        f0 = a
        f1 = np.concatenate(([NEG], a[:-1]))
        f2 = np.where(pode2, np.concatenate(([NEG, NEG], a[:-2])), NEG)
        m = np.maximum(np.maximum(f0, f1), f2)
        volta[t] = np.where(m == f0, 0, np.where(m == f1, 1, 2))
        a = m + e[t, rot]
    s = S - 1 if S == 1 or a[S - 1] >= a[S - 2] else S - 2
    estados = np.zeros(T, np.int64)
    for t in range(T - 1, -1, -1):
        estados[t] = s
        s -= volta[t, s]
    spans = [[-1, -1] for _ in range(L)]
    for t, s in enumerate(estados):
        if s % 2 == 1:
            j = s // 2
            if spans[j][0] < 0: spans[j][0] = t
            spans[j][1] = t + 1
    return spans


def grupos(idx, w, dur, alvo_seg=20.0):
    gs, k = [], 0
    while k < len(idx):
        ini = w[idx[k]]["i"]
        j = k
        while j < len(idx) and w[idx[j]]["i"] - ini <= alvo_seg: j += 1
        if j < len(idx):
            # corta no maior silêncio (pelos tempos do CrisperWhisper) nos últimos 8 s do grupo
            melhor, corte = -1.0, j
            for m in range(k + 1, j):
                if w[idx[m]]["i"] - ini < alvo_seg - 8: continue
                gap = w[idx[m]]["i"] - w[idx[m - 1]]["f"]
                if gap > melhor: melhor, corte = gap, m
            j = corte
        gs.append(idx[k:j]); k = j
    return gs


def alinhar(w, e, dur, vocab, branco, sep, especiais):
    T = e.shape[0]
    idx = [k for k, x in enumerate(w) if x.get("i") is not None and not x["p"].strip().startswith("[")
           and letras(x["p"], vocab, especiais)]
    novos, fimAnt = {}, None
    for g in grupos(idx, w, dur):
        a = max(0.0, w[g[0]]["i"] - 1.5) if fimAnt is None else fimAnt
        b = min(dur, max(w[g[-1]]["f"] + 1.5, a + 1.0))
        q0, q1 = int(a / QUADRO), min(T, int(np.ceil(b / QUADRO)))
        alvo, dono = [], []
        for n, k in enumerate(g):
            if n: alvo.append(sep); dono.append(-1)
            for c in letras(w[k]["p"], vocab, especiais): alvo.append(vocab[c]); dono.append(k)
        if q1 - q0 < len(alvo) + 1:
            continue
        spans = viterbi(e[q0:q1], alvo, branco)
        for (s0, s1), k in zip(spans, dono):
            if k < 0 or s0 < 0: continue
            i0, f0 = (q0 + s0) * QUADRO, (q0 + s1) * QUADRO
            i, f = novos.get(k, (i0, f0)); novos[k] = (min(i, i0), max(f, f0))
        if g[-1] in novos: fimAnt = novos[g[-1]][1]
    out = []
    for k, x in enumerate(w):
        y = dict(x)
        if k in novos: y["i"], y["f"] = round(novos[k][0], 3), round(novos[k][1], 3)
        out.append(y)
    for k, y in enumerate(out):
        if k not in novos:
            ant = next((out[j]["f"] for j in range(k - 1, -1, -1) if j in novos), 0.0)
            prox = next((out[j]["i"] for j in range(k + 1, len(out)) if j in novos), dur)
            y["i"], y["f"] = round(ant, 3), round(max(ant, prox), 3)
    return out, len(novos)
