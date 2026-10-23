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
                                     explicacao: "Fotos, carrosséis e stories do Instagram só baixam com uma conta conectada. Prefira uma conta secundária.",
                                     depoisDoLogin: "quando aparecer o feed")
    static let reddit = SiteConta(nome: "Reddit", api: "reddit", icone: "bubble.left.and.text.bubble.right",
                                  login: "https://www.reddit.com/login/", dominio: "reddit.com",
                                  sessao: "reddit_session",
                                  explicacao: "O Reddit passou a exigir conta para baixar vídeos e imagens. Prefira uma conta secundária.",
                                  depoisDoLogin: "quando aparecer a página inicial do Reddit")
}

extension SiteConta {
    /// O site de um link (para saber qual conta o download vai usar).
    static func para(link: String) -> SiteConta? {
        guard let h = URL(string: link.trimmingCharacters(in: .whitespacesAndNewlines))?.host?.lowercased() else { return nil }
        if h == "instagram.com" || h.hasSuffix(".instagram.com") { return .instagram }
        if h == "reddit.com" || h.hasSuffix(".reddit.com") || h == "redd.it" { return .reddit }
        return nil
    }
}

/// As contas do usuário na nuvem (Instagram e Reddit), compartilhadas entre Ajustes e a tela do link.
@MainActor @Observable
final class ContasNuvem {
    static let shared = ContasNuvem()
    enum Validade { case valida, vencida, desconhecida, conferindo }

    private(set) var contas: [Nuvem.ContaServico] = []
    private(set) var carregado = false
    var erro: String?
    private(set) var validade: [Int: Validade] = [:]

    func de(_ servico: String) -> [Nuvem.ContaServico] { contas.filter { $0.servico == servico } }
    func ativa(_ servico: String) -> Nuvem.ContaServico? { de(servico).first { $0.ativa } }

    func atualizar() async {
        do { contas = try await Nuvem.shared.contas(); erro = nil; carregado = true }
        catch { erro = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription }
    }

    func conferir(_ servico: String) async {
        for c in de(servico) where validade[c.id] == nil {
            validade[c.id] = .conferindo
            let v = try? await Nuvem.shared.validadeConta(c.id)
            validade[c.id] = v == true ? .valida : v == false ? .vencida : .desconhecida
        }
    }

    func ativar(_ c: Nuvem.ContaServico) async {
        do { try await Nuvem.shared.ativarConta(c.id) }
        catch { erro = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription }
        await atualizar()
    }

    func remover(_ c: Nuvem.ContaServico) async {
        do { try await Nuvem.shared.removerConta(id: c.id); validade[c.id] = nil }
        catch { erro = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription }
        await atualizar()
    }

    /// Depois de entrar de novo numa conta, a validade antiga não vale mais.
    func esquecerValidade() { validade = [:] }
}

struct CartaoInstagram: View {
    var body: some View { CartaoConta(site: .instagram) }
}

struct CartaoReddit: View {
    var body: some View { CartaoConta(site: .reddit) }
}

struct CartaoConta: View {
    let site: SiteConta
    @State private var contas = ContasNuvem.shared
    @State private var entrando = false
    @State private var confirmar: Confirmacao?

    var body: some View {
        Cartao(titulo: site.nome, icone: site.icone) {
            Text(site.explicacao + " Cada pessoa usa só as próprias contas; toque numa conta para usá-la nos downloads.")
                .font(.footnote).foregroundStyle(Tema.texto2)
            if !contas.carregado {
                Text(contas.erro ?? "Consultando a nuvem…").font(.subheadline).foregroundStyle(Tema.texto2)
            } else {
                let lista = contas.de(site.api)
                if lista.isEmpty {
                    Label("Nenhuma conta sua conectada", systemImage: "circle").font(.subheadline)
                }
                ForEach(lista) { c in linha(c) }
                Button { entrando = true } label: {
                    Label(lista.isEmpty ? "Entrar no \(site.nome)" : "Adicionar outra conta", systemImage: "person.crop.circle.badge.plus")
                        .frame(maxWidth: .infinity).padding(.vertical, 4)
                }
                .buttonStyle(.glass)
                if let e = contas.erro { Text(e).font(.caption).foregroundStyle(.yellow) }
            }
        }
        .task {
            await contas.atualizar()
            await contas.conferir(site.api)
        }
        .confirmar($confirmar)
        .background {
            // a folha fica fora dos botões de vidro
            Color.clear.sheet(isPresented: $entrando) {
                LoginInstagram(site: site) {
                    Task { contas.esquecerValidade(); await contas.atualizar(); await contas.conferir(site.api) }
                }
            }
        }
    }

    @ViewBuilder private func linha(_ c: Nuvem.ContaServico) -> some View {
        HStack(spacing: 10) {
            Button { Task { await contas.ativar(c) } } label: {
                HStack(spacing: 10) {
                    Image(systemName: c.ativa ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(c.ativa ? Color.green : Tema.texto2).font(.title3)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(c.nome).font(.subheadline.weight(c.ativa ? .semibold : .regular)).foregroundStyle(.primary)
                        Text(textoValidade(c)).font(.caption).foregroundStyle(corValidade(c))
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Button(role: .destructive) {
                confirmar = Confirmacao(titulo: "Tem certeza?",
                                        mensagem: "Remove \(c.nome) da nuvem. Para usar essa conta de novo, será preciso entrar outra vez.",
                                        botao: "Remover") {
                    Task { await contas.remover(c) }
                }
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.glass)
        }
        .padding(10)
        .background(.white.opacity(0.05), in: .rect(cornerRadius: 14))
    }

    private func textoValidade(_ c: Nuvem.ContaServico) -> String {
        let quando = c.atualizada.map { " · entrou em " + $0.formatted(.dateTime.day().month().year()) } ?? ""
        switch contas.validade[c.id] {
        case .vencida: return "A sessão venceu: entre de novo nesta conta"
        case .valida: return (c.ativa ? "Em uso" : "Sessão válida") + quando
        case .desconhecida: return (c.ativa ? "Em uso" : "Guardada") + quando + " · não deu para conferir agora"
        case .conferindo, nil: return (c.ativa ? "Em uso" : "Guardada") + quando
        }
    }

    private func corValidade(_ c: Nuvem.ContaServico) -> Color {
        contas.validade[c.id] == .vencida ? .yellow : (c.ativa ? .green : Tema.texto2)
    }
}

/// Na tela do link: qual conta vai ser usada, com atalho para trocar ou entrar.
struct LinhaContaLink: View {
    let site: SiteConta
    var aoTrocar: () -> Void
    @State private var contas = ContasNuvem.shared
    @State private var entrando = false

    var body: some View {
        let lista = contas.de(site.api)
        VStack(spacing: 0) {
            if !contas.carregado {
                Color.clear.frame(height: 0)
            } else if lista.isEmpty {
                Cartao {
                    Label("Você não tem conta do \(site.nome) conectada", systemImage: "person.crop.circle.badge.exclamationmark")
                        .font(.subheadline).foregroundStyle(.orange)
                    Text("Se o \(site.nome) pedir login, o download falha. Entre com uma conta sua (de preferência secundária).")
                        .font(.footnote).foregroundStyle(Tema.texto2)
                    Button { entrando = true } label: {
                        Label("Entrar no \(site.nome)", systemImage: "person.crop.circle.badge.plus")
                            .frame(maxWidth: .infinity).padding(.vertical, 4)
                    }
                    .buttonStyle(.glass)
                }
            } else {
                Menu {
                    ForEach(lista) { c in
                        Button {
                            guard !c.ativa else { return }
                            Task { await contas.ativar(c); aoTrocar() }
                        } label: {
                            if c.ativa { Label(c.nome, systemImage: "checkmark") } else { Text(c.nome) }
                        }
                    }
                    Divider()
                    Button("Adicionar outra conta", systemImage: "person.crop.circle.badge.plus") { entrando = true }
                } label: {
                    HStack {
                        Label("Conta do \(site.nome): \(contas.ativa(site.api)?.nome ?? "nenhuma ativa")", systemImage: site.icone)
                            .font(.subheadline)
                        Spacer()
                        Image(systemName: "chevron.up.chevron.down").font(.caption)
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity)
                    .glassEffect(.regular, in: .rect(cornerRadius: 18))
                }
                .tint(.primary)
            }
        }
        .task { if !contas.carregado { await contas.atualizar() } }
        .background {
            // a folha fica fora dos botões de vidro
            Color.clear.sheet(isPresented: $entrando) {
                LoginInstagram(site: site) {
                    Task { contas.esquecerValidade(); await contas.atualizar(); aoTrocar() }
                }
            }
        }
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
                try await estudio.nuvem.adicionarConta(site.api, cookies)
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
