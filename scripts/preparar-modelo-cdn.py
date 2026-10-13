#!/usr/bin/env python3
"""Prepara uma pasta de modelo para o cdn (o app baixa daqui quando o modelo não está no iPhone).
Copia TODOS os arquivos da pasta, com o mesmo caminho relativo que o app usa.

Alinhador (no GT-SRV, no WSL; <pasta> = a pasta "Alinhador" do workflow, com Alinhador.mlmodelc e vocab.json):
    python3 preparar-modelo-cdn.py <pasta> ~/sites-frx9/sites/cdn/modelos/alinhador
Arquivos acima de 19 MB viram partes (.part00, .part01...): não junte. Grava manifesto.json.
"""
import hashlib, json, os, shutil, sys

PARTE = 19 * 1024 * 1024


def main():
    if len(sys.argv) != 3:
        sys.exit(__doc__)
    origem, destino = os.path.expanduser(sys.argv[1]), os.path.expanduser(sys.argv[2])
    itens = []
    for atual, _, arqs in os.walk(origem):
        for a in sorted(arqs):
            if a.startswith("."):
                continue
            completo = os.path.join(atual, a)
            itens.append((os.path.relpath(completo, origem).replace(os.sep, "/"), completo))
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
