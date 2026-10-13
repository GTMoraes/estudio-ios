#!/usr/bin/env python3
"""Prepara o CrisperWhisper (Core ML) para o cdn: o app baixa daqui quando o modelo não está no iPhone.

Uso (no GT-SRV, no WSL):
    python3 preparar-crisper-cdn.py <pasta-do-modelo> ~/sites-frx9/sites/cdn/modelos/crisperwhisper

<pasta-do-modelo> é a mesma pasta copiada para o iPhone: precisa ter (em qualquer subpasta)
MelSpectrogram.mlmodelc, AudioEncoder.mlmodelc, TextDecoder.mlmodelc, tokenizer.json e
generation_config.json. Arquivos acima de 19 MB viram partes (.part00, .part01...): não junte.
Grava manifesto.json (caminho, tamanho, SHA-256 e número de partes de cada arquivo).
"""
import hashlib, json, os, shutil, sys

PARTE = 19 * 1024 * 1024
MODELOS = ["MelSpectrogram", "AudioEncoder", "TextDecoder"]
JSONS = ["tokenizer.json", "generation_config.json"]


def achar_pasta(raiz):
    for atual, dirs, _ in os.walk(raiz):
        if all(m + ".mlmodelc" in dirs for m in MODELOS):
            return atual
    sys.exit("Não achei MelSpectrogram/AudioEncoder/TextDecoder .mlmodelc dentro de " + raiz)


def achar_arquivo(raiz, nome):
    for atual, _, arqs in os.walk(raiz):
        if nome in arqs:
            return os.path.join(atual, nome)
    sys.exit("Não achei " + nome + " dentro de " + raiz)


def main():
    if len(sys.argv) != 3:
        sys.exit(__doc__)
    origem, destino = os.path.expanduser(sys.argv[1]), os.path.expanduser(sys.argv[2])
    pasta = achar_pasta(origem)
    itens = []  # (caminho relativo no cdn, arquivo de origem)
    for m in MODELOS:
        base = os.path.join(pasta, m + ".mlmodelc")
        for atual, _, arqs in os.walk(base):
            for a in sorted(arqs):
                if a.startswith("."):
                    continue
                completo = os.path.join(atual, a)
                rel = os.path.relpath(completo, pasta).replace(os.sep, "/")
                itens.append((rel, completo))
    for j in JSONS:
        itens.append((j, achar_arquivo(origem, j)))

    if os.path.exists(destino):
        shutil.rmtree(destino)
    os.makedirs(destino)
    arquivos = []
    for rel, completo in itens:
        tam = os.path.getsize(completo)
        h = hashlib.sha256()
        alvo = os.path.join(destino, rel)
        os.makedirs(os.path.dirname(alvo), exist_ok=True)
        partes = 0 if tam <= PARTE else (tam + PARTE - 1) // PARTE
        with open(completo, "rb") as f:
            if partes == 0:
                dados = f.read()
                h.update(dados)
                with open(alvo, "wb") as g:
                    g.write(dados)
            else:
                for k in range(partes):
                    dados = f.read(PARTE)
                    h.update(dados)
                    with open("%s.part%02d" % (alvo, k), "wb") as g:
                        g.write(dados)
        arquivos.append({"caminho": rel, "bytes": tam, "sha256": h.hexdigest(), "partes": partes})
        print("%-60s %12d bytes %s" % (rel, tam, "(%d partes)" % partes if partes else ""))
    manifesto = {"versao": 1, "parte": PARTE, "arquivos": arquivos}
    with open(os.path.join(destino, "manifesto.json"), "w") as g:
        json.dump(manifesto, g, indent=1)
    total = sum(a["bytes"] for a in arquivos)
    print("\n%d arquivos, %.2f GB. manifesto.json gravado em %s" % (len(arquivos), total / 1e9, destino))
    print("Agora: chmod -R a+rX " + destino)


if __name__ == "__main__":
    main()
