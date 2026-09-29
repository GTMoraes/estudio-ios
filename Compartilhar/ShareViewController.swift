import UIKit
import SwiftUI
import UniformTypeIdentifiers

/// Extensão "Compartilhar": recebe link, vídeo ou áudio, guarda na caixa do
/// grupo de apps e abre o Estúdio para continuar. Não processa nada aqui
/// (extensões têm pouca memória e são encerradas a qualquer momento).
@objc(ShareViewController)
final class ShareViewController: UIViewController {
    private let estado = EstadoEnvio()

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
        let tela = TelaEnvio(estado: estado, fechar: { [weak self] in self?.concluir() })
        let host = UIHostingController(rootView: tela)
        host.view.backgroundColor = .clear
        addChild(host)
        host.view.frame = view.bounds
        host.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(host.view)
        host.didMove(toParent: self)
        Task { await receber() }
    }

    private func concluir() {
        extensionContext?.completeRequest(returningItems: [], completionHandler: nil)
    }

    @MainActor
    private func receber() async {
        let itens = (extensionContext?.inputItems as? [NSExtensionItem]) ?? []
        var guardados = 0
        var erro: String?
        for item in itens {
            for prov in item.attachments ?? [] {
                do {
                    let ok = try await guardar(prov)
                    if ok { guardados += 1 }
                } catch {
                    erro = error.localizedDescription
                }
            }
        }
        if guardados == 0 {
            estado.fase = .erro(erro ?? "Não encontrei link, vídeo nem áudio no que foi compartilhado.")
            return
        }
        estado.fase = .abrindo
        if abrirApp(URL(string: "estudio://caixa")!) {
            try? await Task.sleep(nanoseconds: 400_000_000)
            concluir()
        } else {
            estado.fase = .guardado(guardados)
        }
    }

    /// Guarda um anexo. Ordem: arquivo de mídia > link > texto com link.
    private func guardar(_ prov: NSItemProvider) async throws -> Bool {
        let id = UUID().uuidString
        for tipo in [UTType.movie, UTType.audio] where prov.hasItemConformingToTypeIdentifier(tipo.identifier) {
            let nome = try await copiarArquivo(prov, tipo: tipo, id: id)
            try Caixa.guardar(Recebido(id: id, tipo: .arquivo, link: nil, arquivo: nome,
                                       nome: String(nome.dropFirst(id.count + 1)), data: Date()))
            return true
        }
        if prov.hasItemConformingToTypeIdentifier(UTType.url.identifier) {
            let item = try await prov.loadItem(forTypeIdentifier: UTType.url.identifier, options: nil)
            var url: URL?
            if let u = item as? URL { url = u }
            else if let d = item as? Data { url = URL(dataRepresentation: d, relativeTo: nil) }
            else if let s = item as? String { url = URL(string: s) }
            if let u = url {
                if u.isFileURL {
                    let acesso = u.startAccessingSecurityScopedResource()
                    defer { if acesso { u.stopAccessingSecurityScopedResource() } }
                    let nome = try Caixa.copiar(u, id: id)
                    try Caixa.guardar(Recebido(id: id, tipo: .arquivo, link: nil, arquivo: nome,
                                               nome: u.lastPathComponent, data: Date()))
                } else {
                    try Caixa.guardar(Recebido(id: id, tipo: .link, link: u.absoluteString, arquivo: nil,
                                               nome: u.host ?? "link", data: Date()))
                }
                return true
            }
        }
        if prov.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) {
            let item = try await prov.loadItem(forTypeIdentifier: UTType.plainText.identifier, options: nil)
            if let s = item as? String, let u = primeiroLink(em: s) {
                try Caixa.guardar(Recebido(id: id, tipo: .link, link: u.absoluteString, arquivo: nil,
                                           nome: u.host ?? "link", data: Date()))
                return true
            }
        }
        return false
    }

    /// O arquivo entregue pelo sistema é temporário: copia dentro do callback.
    private func copiarArquivo(_ prov: NSItemProvider, tipo: UTType, id: String) async throws -> String {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<String, Error>) in
            _ = prov.loadFileRepresentation(forTypeIdentifier: tipo.identifier) { url, erro in
                if let erro { cont.resume(throwing: erro); return }
                guard let url else {
                    cont.resume(throwing: NSError(domain: "Compartilhar", code: 2,
                                                  userInfo: [NSLocalizedDescriptionKey: "arquivo não recebido"]))
                    return
                }
                do { cont.resume(returning: try Caixa.copiar(url, id: id)) }
                catch { cont.resume(throwing: error) }
            }
        }
    }

    /// Extensões não podem chamar UIApplication.open diretamente; o objeto
    /// UIApplication é achado pela cadeia de responders e o método é chamado
    /// pelo seletor. Se o sistema recusar, a tela pede para abrir o app.
    private func abrirApp(_ url: URL) -> Bool {
        var r: UIResponder? = self
        while let atual = r {
            if let app = atual as? UIApplication {
                let sel = NSSelectorFromString("openURL:options:completionHandler:")
                guard app.responds(to: sel) else { return false }
                typealias Abrir = @convention(c) (NSObject, Selector, NSURL, NSDictionary, (@convention(block) (Bool) -> Void)?) -> Void
                let f = unsafeBitCast(app.method(for: sel), to: Abrir.self)
                f(app, sel, url as NSURL, NSDictionary(), nil)
                return true
            }
            r = atual.next
        }
        return false
    }
}

@MainActor
final class EstadoEnvio: ObservableObject {
    enum Fase: Equatable { case recebendo, abrindo, guardado(Int), erro(String) }
    @Published var fase: Fase = .recebendo
}

struct TelaEnvio: View {
    @ObservedObject var estado: EstadoEnvio
    var fechar: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Spacer()
            VStack(spacing: 14) {
                switch estado.fase {
                case .recebendo, .abrindo:
                    ProgressView().controlSize(.large)
                    Text(estado.fase == .recebendo ? "Recebendo…" : "Abrindo o Estúdio…")
                        .font(.headline)
                case .guardado(let n):
                    Image(systemName: "tray.and.arrow.down.fill").font(.system(size: 36))
                        .foregroundStyle(Color(red: 0.851, green: 0.467, blue: 0.341))
                    Text(n == 1 ? "Guardado no Estúdio" : "\(n) itens guardados no Estúdio").font(.headline)
                    Text("Abra o Estúdio para escolher o que fazer.")
                        .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    Button("OK", action: fechar).buttonStyle(.glassProminent)
                case .erro(let msg):
                    Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 36))
                        .foregroundStyle(.yellow)
                    Text(msg).multilineTextAlignment(.center)
                    Button("Fechar", action: fechar).buttonStyle(.glass)
                }
            }
            .padding(28)
            .frame(maxWidth: 340)
            .glassEffect(.regular, in: .rect(cornerRadius: 28))
            Spacer()
        }
        .frame(maxWidth: .infinity)
        .padding()
        .preferredColorScheme(.dark)
        .tint(Color(red: 0.851, green: 0.467, blue: 0.341))
    }
}
