import SwiftUI
import WebKit

/// Site com conta conectada na nuvem (Instagram, Reddit). O login acontece na página do próprio site,
/// dentro do app; só os cookies da sessão vão para a nuvem (nunca a senha).
struct SiteConta: Equatable {
    var nome: String              // "Instagram"
    var api: String               // caminho na nuvem: api/<api>/status
    var icone: String
    var login: String             // página de login
    var dominio: String           // cookies deste domínio
    var sessao: String            // cookie que prova o login
    var explicacao: String
    var depoisDoLogin: String     // "quando aparecer o feed"

    static let instagram = SiteConta(nome: "Instagram", api: "instagram", icone: "camera.circle",
                                     login: "https://www.instagram.com/accounts/login/", dominio: "instagram.com",
                                     sessao: "sessionid",
                                     explicacao: "Fotos e carrosséis do Instagram só baixam com uma conta conectada. Prefira uma conta secundária.",
                                     depoisDoLogin: "quando aparecer o feed")
    static let reddit = SiteConta(nome: "Reddit", api: "reddit", icone: "bubble.left.and.text.bubble.right",
                                  login: "https://www.reddit.com/login/", dominio: "reddit.com",
                                  sessao: "reddit_session",
                                  explicacao: "O Reddit passou a exigir conta para baixar vídeos e imagens. Prefira uma conta secundária.",
                                  depoisDoLogin: "quando aparecer a página inicial do Reddit")
}

struct CartaoInstagram: View {
    var body: some View { CartaoConta(site: .instagram) }
}

struct CartaoReddit: View {
    var body: some View { CartaoConta(site: .reddit) }
}

struct CartaoConta: View {
    let site: SiteConta
    @Environment(Estudio.self) private var estudio
    @State private var estado: Nuvem.EstadoInstagram?
    @State private var falha: String?
    @State private var entrando = false
    @State private var confirmar: Confirmacao?

    var body: some View {
        Cartao(titulo: site.nome, icone: site.icone) {
            Text(site.explicacao)
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
                        Text("Não consegui confirmar com o \(site.nome) se a sessão ainda vale.")
                            .font(.caption).foregroundStyle(Tema.texto2)
                    }
                }
                if e.podeGerenciar {
                    Button { entrando = true } label: {
                        Label(e.temConta ? "Entrar de novo" : "Entrar no \(site.nome)", systemImage: "person.crop.circle.badge.plus")
                            .frame(maxWidth: .infinity).padding(.vertical, 4)
                    }
                    .buttonStyle(.glass)
                    if e.temConta {
                        Button(role: .destructive) {
                            confirmar = Confirmacao(titulo: "Desconectar o \(site.nome)?",
                                                    mensagem: "A sessão guardada na nuvem é apagada. Os links do \(site.nome) que pedem conta deixam de baixar até você entrar de novo.",
                                                    botao: "Desconectar") {
                                Task {
                                    do { try await estudio.nuvem.removerConta(site.api) }
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
                LoginInstagram(site: site) { Task { await atualizar() } }
            }
        }
    }

    private func atualizar() async {
        do { estado = try await estudio.nuvem.estadoConta(site.api); falha = nil }
        catch { falha = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription }
    }
}

/// A página de login do site. "Concluir" manda os cookies da sessão para a nuvem.
struct LoginInstagram: View {
    @Environment(Estudio.self) private var estudio
    @Environment(\.dismiss) private var fechar
    let site: SiteConta
    @State private var pagina: PaginaInstagram
    @State private var enviando = false
    @State private var erro: String?
    var aoConcluir: () -> Void

    init(site: SiteConta = .instagram, aoConcluir: @escaping () -> Void) {
        self.site = site
        self.aoConcluir = aoConcluir
        _pagina = State(initialValue: PaginaInstagram(site: site))
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Text(erro ?? "Entre com a conta e toque em Concluir \(site.depoisDoLogin).")
                    .font(.footnote)
                    .foregroundStyle(erro == nil ? Tema.texto2 : .yellow)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal).padding(.vertical, 8)
                NavegadorWeb(webView: pagina.webView)
            }
            .navigationTitle(site.nome)
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
            let temSessao = cookies.contains { ($0["name"] as? String) == site.sessao }
            guard temSessao else {
                erro = "O login ainda não terminou. Entre com a conta e toque em Concluir \(site.depoisDoLogin)."
                enviando = false
                return
            }
            do {
                try await estudio.nuvem.enviarCookies(site.api, cookies)
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
    let dominio: String

    init(site: SiteConta = .instagram) {
        dominio = site.dominio
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        webView = WKWebView(frame: .zero, configuration: config)
        if let u = URL(string: site.login) { webView.load(URLRequest(url: u)) }
    }

    func cookies() async -> [[String: Any]] {
        let todos = await webView.configuration.websiteDataStore.httpCookieStore.allCookies()
        var lista: [[String: Any]] = []
        for c in todos where c.domain.hasSuffix(dominio) {
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
