import SwiftUI
import WebKit

/// Conta do Instagram usada pela nuvem para baixar fotos e carrosséis. O login acontece na página
/// do próprio Instagram, dentro do app; só os cookies da sessão vão para a nuvem (nunca a senha).
struct CartaoInstagram: View {
    @Environment(Estudio.self) private var estudio
    @State private var estado: Nuvem.EstadoInstagram?
    @State private var falha: String?
    @State private var entrando = false
    @State private var confirmar: Confirmacao?

    var body: some View {
        Cartao(titulo: "Instagram", icone: "camera.circle") {
            Text("Fotos e carrosséis do Instagram só baixam com uma conta conectada. Prefira uma conta secundária.")
                .font(.footnote).foregroundStyle(Tema.texto2)
            if let e = estado {
                if e.temConta, e.valida == false {
                    Label("A sessão venceu: entre de novo", systemImage: "exclamationmark.triangle.fill")
                        .font(.subheadline).foregroundStyle(.yellow)
                } else {
                    Label(e.temConta ? "Conta conectada" + (e.atualizado.map { " em " + $0.formatted(.dateTime.day().month().year()) } ?? "")
                                     : "Nenhuma conta conectada",
                          systemImage: e.temConta ? "checkmark.circle.fill" : "circle")
                        .font(.subheadline)
                    if e.temConta, e.valida == nil {
                        Text("Não consegui confirmar com o Instagram se a sessão ainda vale.")
                            .font(.caption).foregroundStyle(Tema.texto2)
                    }
                }
                if e.podeGerenciar {
                    Button { entrando = true } label: {
                        Label(e.temConta ? "Entrar de novo" : "Entrar no Instagram", systemImage: "person.crop.circle.badge.plus")
                            .frame(maxWidth: .infinity).padding(.vertical, 4)
                    }
                    .buttonStyle(.glass)
                    if e.temConta {
                        Button(role: .destructive) {
                            confirmar = Confirmacao(titulo: "Desconectar o Instagram?",
                                                    mensagem: "A sessão guardada na nuvem é apagada. Fotos e carrosséis deixam de baixar até você entrar de novo.",
                                                    botao: "Desconectar") {
                                Task {
                                    do { try await estudio.nuvem.removerInstagram() }
                                    catch { falha = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription }
                                    await atualizar()
                                }
                            }
                        } label: {
                            Label("Desconectar", systemImage: "trash").frame(maxWidth: .infinity).padding(.vertical, 4)
                        }
                        .buttonStyle(.glass)
                    }
                } else {
                    Text("Só o administrador da nuvem pode trocar a conta.").font(.caption).foregroundStyle(Tema.texto2)
                }
            } else {
                Text(falha ?? "Consultando a nuvem…").font(.subheadline).foregroundStyle(Tema.texto2)
            }
            if estado != nil, let falha {
                Text(falha).font(.caption).foregroundStyle(.yellow)
            }
        }
        .task { await atualizar() }
        .confirmar($confirmar)
        .background {
            // a folha fica fora dos botões de vidro
            Color.clear.sheet(isPresented: $entrando) {
                LoginInstagram { Task { await atualizar() } }
            }
        }
    }

    private func atualizar() async {
        do { estado = try await estudio.nuvem.estadoInstagram(); falha = nil }
        catch { falha = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription }
    }
}

/// A página de login do Instagram. "Concluir" manda os cookies da sessão para a nuvem.
struct LoginInstagram: View {
    @Environment(Estudio.self) private var estudio
    @Environment(\.dismiss) private var fechar
    @State private var pagina = PaginaInstagram()
    @State private var enviando = false
    @State private var erro: String?
    var aoConcluir: () -> Void

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Text(erro ?? "Entre com a conta. Quando aparecer o feed, toque em Concluir.")
                    .font(.footnote)
                    .foregroundStyle(erro == nil ? Tema.texto2 : .yellow)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal).padding(.vertical, 8)
                NavegadorWeb(webView: pagina.webView)
            }
            .navigationTitle("Instagram")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancelar") { fechar() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(enviando ? "Enviando…" : "Concluir") { concluir() }
                        .disabled(enviando)
                }
            }
        }
        .preferredColorScheme(.dark)
        .tint(Tema.acento)
    }

    private func concluir() {
        enviando = true
        Task {
            let cookies = await pagina.cookies()
            let temSessao = cookies.contains { ($0["name"] as? String) == "sessionid" }
            guard temSessao else {
                erro = "O login ainda não terminou. Entre com a conta e toque em Concluir quando aparecer o feed."
                enviando = false
                return
            }
            do {
                try await estudio.nuvem.enviarCookiesInstagram(cookies)
                aoConcluir()
                fechar()
            } catch {
                erro = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                enviando = false
            }
        }
    }
}

/// O navegador do login: sessão própria, que some quando a folha fecha (nada fica guardado no iPhone).
@MainActor
final class PaginaInstagram {
    let webView: WKWebView

    init() {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        webView = WKWebView(frame: .zero, configuration: config)
        if let u = URL(string: "https://www.instagram.com/accounts/login/") { webView.load(URLRequest(url: u)) }
    }

    func cookies() async -> [[String: Any]] {
        let todos = await webView.configuration.websiteDataStore.httpCookieStore.allCookies()
        var lista: [[String: Any]] = []
        for c in todos where c.domain.hasSuffix("instagram.com") {
            lista.append(["name": c.name, "value": c.value, "domain": c.domain,
                          "expires": c.expiresDate?.timeIntervalSince1970 ?? 0])
        }
        return lista
    }
}

struct NavegadorWeb: UIViewRepresentable {
    let webView: WKWebView
    func makeUIView(context: Context) -> WKWebView { webView }
    func updateUIView(_ v: WKWebView, context: Context) {}
}
