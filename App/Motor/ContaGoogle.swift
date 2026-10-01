import Foundation
import Security
import CryptoKit
import AuthenticationServices
import UIKit

/// Login na conta Google (OAuth com PKCE, cliente do tipo iOS, sem segredo).
/// O ID do cliente, o refresh token e o e-mail ficam no Keychain do iPhone; o token de acesso só na memória.
actor ContaGoogle {
    static let shared = ContaGoogle()

    static let escopos = "openid email https://www.googleapis.com/auth/drive.readonly"
    private static let servico = "com.gtm.estudio.google"

    private var acesso: String?
    private var validade = Date.distantPast
    private var renovando: Task<String, Error>?

    // MARK: Keychain (síncrono, para a interface)

    static func ler(_ conta: String) -> String? {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                kSecAttrService as String: servico,
                                kSecAttrAccount as String: conta,
                                kSecReturnData as String: true,
                                kSecMatchLimit as String: kSecMatchLimitOne]
        var r: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &r) == errSecSuccess, let d = r as? Data,
              let s = String(data: d, encoding: .utf8), !s.isEmpty else { return nil }
        return s
    }

    static func gravar(_ conta: String, _ valor: String?) {
        SecItemDelete([kSecClass as String: kSecClassGenericPassword,
                       kSecAttrService as String: servico,
                       kSecAttrAccount as String: conta] as CFDictionary)
        guard let valor, !valor.isEmpty else { return }
        SecItemAdd([kSecClass as String: kSecClassGenericPassword,
                    kSecAttrService as String: servico,
                    kSecAttrAccount as String: conta,
                    kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
                    kSecValueData as String: Data(valor.utf8)] as CFDictionary, nil)
    }

    static var clienteId: String? { ler("cliente") }
    static var email: String? { ler("email") }
    static var logado: Bool { ler("refresh") != nil }

    static func salvarCliente(_ s: String) {
        gravar("cliente", s.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// "123-abc.apps.googleusercontent.com" -> "com.googleusercontent.apps.123-abc"
    static func esquema(_ cliente: String) -> String? {
        let sufixo = ".apps.googleusercontent.com"
        guard cliente.hasSuffix(sufixo) else { return nil }
        return "com.googleusercontent.apps." + cliente.dropLast(sufixo.count)
    }

    // MARK: entrar / sair

    @MainActor
    static func entrar() async throws {
        guard let cliente = clienteId else { throw ErroApp("Cole o ID do cliente OAuth primeiro.") }
        guard let esquema = esquema(cliente) else {
            throw ErroApp("O ID do cliente deve terminar em .apps.googleusercontent.com (tipo iOS).")
        }
        let redirect = esquema + ":/oauth2redirect"
        let verificador = aleatorio(48)
        let desafio = Data(SHA256.hash(data: Data(verificador.utf8))).base64URL
        let estado = aleatorio(16)
        var c = URLComponents(string: "https://accounts.google.com/o/oauth2/v2/auth")!
        c.queryItems = [
            .init(name: "client_id", value: cliente),
            .init(name: "redirect_uri", value: redirect),
            .init(name: "response_type", value: "code"),
            .init(name: "scope", value: escopos),
            .init(name: "code_challenge", value: desafio),
            .init(name: "code_challenge_method", value: "S256"),
            .init(name: "state", value: estado),
            .init(name: "prompt", value: "select_account consent"),
        ]
        let volta = try await SessaoWeb().abrir(c.url!, esquema: esquema)
        let q = URLComponents(url: volta, resolvingAgainstBaseURL: false)?.queryItems ?? []
        if let e = q.first(where: { $0.name == "error" })?.value {
            throw ErroApp(e == "access_denied" ? "Login cancelado." : "O Google recusou: \(e)")
        }
        guard q.first(where: { $0.name == "state" })?.value == estado,
              let codigo = q.first(where: { $0.name == "code" })?.value else {
            throw ErroApp("Resposta do Google incompleta.")
        }
        let r = try await token(["client_id": cliente, "code": codigo, "code_verifier": verificador,
                                 "grant_type": "authorization_code", "redirect_uri": redirect])
        guard let refresh = r["refresh_token"] as? String else {
            throw ErroApp("O Google não devolveu o acesso permanente. Saia e entre de novo.")
        }
        gravar("refresh", refresh)
        if let idt = r["id_token"] as? String, let e = emailDoToken(idt) { gravar("email", e) }
        await shared.guardar(r)
    }

    static func sair() async {
        if let rt = ler("refresh") {
            var p = URLRequest(url: URL(string: "https://oauth2.googleapis.com/revoke?token=\(rt)")!)
            p.httpMethod = "POST"
            _ = try? await URLSession.shared.data(for: p)
        }
        gravar("refresh", nil)
        gravar("email", nil)
        await shared.esquecer()
    }

    // MARK: token de acesso

    /// nil = sem login. Renova sozinho (1 renovação por vez).
    func tokenAcesso() async throws -> String? {
        guard Self.logado else { return nil }
        if let acesso, validade > Date().addingTimeInterval(60) { return acesso }
        if let renovando { return try await renovando.value }
        let t = Task<String, Error> {
            guard let cliente = Self.clienteId, let rt = Self.ler("refresh") else {
                throw ErroApp("Entre de novo com o Google (Ajustes › Google Drive).")
            }
            do {
                let r = try await Self.token(["client_id": cliente, "refresh_token": rt, "grant_type": "refresh_token"])
                guard let a = r["access_token"] as? String else { throw ErroApp("O Google não renovou o acesso.") }
                self.guardar(r)
                return a
            } catch let e as ErroGoogle where e.codigo == "invalid_grant" {
                Self.gravar("refresh", nil)
                throw ErroApp("O login do Google expirou ou foi revogado. Entre de novo (Ajustes › Google Drive).")
            }
        }
        renovando = t
        defer { renovando = nil }
        return try await t.value
    }

    private func guardar(_ r: [String: Any]) {
        acesso = r["access_token"] as? String
        let s = (r["expires_in"] as? Double) ?? Double(r["expires_in"] as? Int ?? 3600)
        validade = Date().addingTimeInterval(s)
    }

    private func esquecer() { acesso = nil; validade = .distantPast }

    /// Token recusado (401): força renovar na próxima.
    func invalidar() { validade = .distantPast }

    // MARK: auxiliares

    struct ErroGoogle: LocalizedError {
        let codigo: String
        let texto: String
        var errorDescription: String? { "Google: \(texto)" }
    }

    private static func token(_ campos: [String: String]) async throws -> [String: Any] {
        var p = URLRequest(url: URL(string: "https://oauth2.googleapis.com/token")!)
        p.httpMethod = "POST"
        p.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var c = URLComponents()
        c.queryItems = campos.map { URLQueryItem(name: $0.key, value: $0.value) }
        p.httpBody = (c.percentEncodedQuery ?? "")
            .replacingOccurrences(of: "+", with: "%2B").data(using: .utf8)
        let (d, resp) = try await URLSession.shared.data(for: p)
        let o = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] ?? [:]
        guard (resp as? HTTPURLResponse)?.statusCode == 200 else {
            let cod = o["error"] as? String ?? "erro"
            throw ErroGoogle(codigo: cod, texto: (o["error_description"] as? String) ?? cod)
        }
        return o
    }

    private static func aleatorio(_ n: Int) -> String {
        var b = [UInt8](repeating: 0, count: n)
        _ = SecRandomCopyBytes(kSecRandomDefault, n, &b)
        return Data(b).base64URL
    }

    private static func emailDoToken(_ jwt: String) -> String? {
        let partes = jwt.split(separator: ".")
        guard partes.count >= 2 else { return nil }
        var s = String(partes[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while s.count % 4 != 0 { s += "=" }
        guard let d = Data(base64Encoded: s),
              let o = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] else { return nil }
        return o["email"] as? String
    }
}

private extension Data {
    var base64URL: String {
        base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
}

/// A tela de login do Google por cima do app (Safari do sistema, sem senha no app).
@MainActor
final class SessaoWeb: NSObject, ASWebAuthenticationPresentationContextProviding {
    private var sessao: ASWebAuthenticationSession?

    func abrir(_ url: URL, esquema: String) async throws -> URL {
        try await withCheckedThrowingContinuation { cont in
            let s = ASWebAuthenticationSession(url: url, callback: .customScheme(esquema)) { volta, erro in
                if let volta { cont.resume(returning: volta); return }
                if let e = erro as? ASWebAuthenticationSessionError, e.code == .canceledLogin {
                    cont.resume(throwing: ErroApp("Login cancelado.")); return
                }
                cont.resume(throwing: erro ?? ErroApp("O login não terminou."))
            }
            s.presentationContextProvider = self
            s.prefersEphemeralWebBrowserSession = false
            sessao = s
            if !s.start() { cont.resume(throwing: ErroApp("Não consegui abrir a tela de login.")) }
        }
    }

    nonisolated func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        MainActor.assumeIsolated {
            let cenas = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            return cenas.flatMap(\.windows).first(where: \.isKeyWindow) ?? cenas.first.map { UIWindow(windowScene: $0) } ?? UIWindow()
        }
    }
}
