#!/usr/bin/env python3
"""Assinatura do Estúdio para o TestFlight, pela API do App Store Connect (sem Mac).

Usa os secrets do GitHub (variáveis de ambiente): ASC_KEY_ID, ASC_ISSUER_ID, ASC_KEY_P8.

  python3 scripts/asc.py certificado <pasta> <senha>
      Cria UM certificado "Apple Distribution" (uma vez só) e grava <pasta>/distribuicao.p12
      (protegido pela senha) e <pasta>/distribuicao.p12.base64.txt (o texto para o secret DIST_P12).
  python3 scripts/asc.py perfis <p12> <senha> <bundle>...
      Para cada bundle, recria o perfil "GH Estudio <bundle>" (App Store) com o certificado do p12,
      instala no Mac e imprime "bundle=nome do perfil" (uma linha por bundle).
"""
import base64, json, os, sys, time, urllib.error, urllib.parse, urllib.request
import jwt   # PyJWT (com cryptography)

API = "https://api.appstoreconnect.apple.com/v1"


def token():
    chave = os.environ["ASC_KEY_P8"].strip().replace("\\n", "\n")
    agora = int(time.time())
    return jwt.encode({"iss": os.environ["ASC_ISSUER_ID"].strip(), "iat": agora, "exp": agora + 1100,
                       "aud": "appstoreconnect-v1"}, chave, algorithm="ES256",
                      headers={"kid": os.environ["ASC_KEY_ID"].strip(), "typ": "JWT"})


def chamar(metodo, caminho, corpo=None):
    url = caminho if caminho.startswith("http") else API + caminho
    dados = json.dumps(corpo).encode() if corpo is not None else None
    req = urllib.request.Request(url, data=dados, method=metodo,
                                 headers={"Authorization": "Bearer " + token(), "Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(req) as r:
            txt = r.read()
            return json.loads(txt) if txt else {}
    except urllib.error.HTTPError as e:
        sys.exit(f"API da Apple recusou {metodo} {caminho}: HTTP {e.code}\n{e.read().decode(errors='replace')}")


def certificado(pasta, senha):
    from cryptography import x509
    from cryptography.x509.oid import NameOID
    from cryptography.hazmat.primitives import hashes, serialization
    from cryptography.hazmat.primitives.asymmetric import rsa
    from cryptography.hazmat.primitives.serialization import pkcs12
    os.makedirs(pasta, exist_ok=True)
    chave = rsa.generate_private_key(public_exponent=65537, key_size=2048)
    csr = (x509.CertificateSigningRequestBuilder()
           .subject_name(x509.Name([x509.NameAttribute(NameOID.COMMON_NAME, "Estudio GitHub"),
                                    x509.NameAttribute(NameOID.COUNTRY_NAME, "BR")]))
           .sign(chave, hashes.SHA256()))
    r = chamar("POST", "/certificates", {"data": {"type": "certificates", "attributes": {
        "certificateType": "DISTRIBUTION", "csrContent": csr.public_bytes(serialization.Encoding.PEM).decode()}}})
    a = r["data"]["attributes"]
    cert = x509.load_der_x509_certificate(base64.b64decode(a["certificateContent"]))
    # algoritmos antigos de propósito: o chaveiro do macOS não abre o p12 com AES do padrão novo
    cifra = (serialization.PrivateFormat.PKCS12.encryption_builder().kdf_rounds(50000)
             .key_cert_algorithm(pkcs12.PBES.PBESv1SHA1And3KeyTripleDESCBC)
             .hmac_hash(hashes.SHA1()).build(senha.encode()))
    dados = pkcs12.serialize_key_and_certificates(b"Estudio GitHub", chave, cert, None, cifra)
    p12 = os.path.join(pasta, "distribuicao.p12")
    open(p12, "wb").write(dados)
    open(p12 + ".base64.txt", "w").write(base64.b64encode(dados).decode())
    print(f"Certificado criado: {a.get('name')} (série {a.get('serialNumber')}, vence {a.get('expirationDate')})")


def serie_do_p12(p12, senha):
    from cryptography.hazmat.primitives.serialization import pkcs12
    _, cert, _ = pkcs12.load_key_and_certificates(open(p12, "rb").read(), senha.encode())
    return cert.serial_number


def perfis(p12, senha, bundles):
    serie = serie_do_p12(p12, senha)
    certs = chamar("GET", "/certificates?limit=200")["data"]
    cert = next((c for c in certs if int(c["attributes"]["serialNumber"], 16) == serie), None)
    if not cert:
        sys.exit("O certificado do secret DIST_P12 não existe mais na conta (revogado?). Rode o workflow "
                 "'Preparar assinatura' de novo e troque o secret.")
    destino = os.path.expanduser("~/Library/MobileDevice/Provisioning Profiles")
    os.makedirs(destino, exist_ok=True)
    for b in bundles:
        ids = chamar("GET", f"/bundleIds?filter[identifier]={b}&limit=200")["data"]
        bid = next((x for x in ids if x["attributes"]["identifier"] == b), None)
        if not bid:
            sys.exit(f"O identificador {b} não está registrado em developer.apple.com › Identifiers.")
        nome = f"GH Estudio {b}"
        for p in chamar("GET", f"/profiles?filter[name]={urllib.parse.quote(nome)}&limit=200")["data"]:
            chamar("DELETE", f"/profiles/{p['id']}")
        r = chamar("POST", "/profiles", {"data": {"type": "profiles",
            "attributes": {"name": nome, "profileType": "IOS_APP_STORE"},
            "relationships": {"bundleId": {"data": {"type": "bundleIds", "id": bid["id"]}},
                              "certificates": {"data": [{"type": "certificates", "id": cert["id"]}]}}}})
        a = r["data"]["attributes"]
        open(os.path.join(destino, a["uuid"] + ".mobileprovision"), "wb").write(base64.b64decode(a["profileContent"]))
        print(f"{b}={nome}")


if __name__ == "__main__":
    if len(sys.argv) >= 4 and sys.argv[1] == "certificado":
        certificado(sys.argv[2], sys.argv[3])
    elif len(sys.argv) >= 5 and sys.argv[1] == "perfis":
        perfis(sys.argv[2], sys.argv[3], sys.argv[4:])
    else:
        sys.exit(__doc__)
