import SwiftUI
import UIKit

/// Áudio, vídeo ou imagem: o que dá para abrir de novo como entrada.
func ehMidia(_ u: URL) -> Bool {
    ehImagem(u) || ehVideoArquivo(u) || ["mp3", "m4a", "wav", "aac", "flac", "ogg", "opus"].contains(u.pathExtension.lowercased())
}

struct ArquivoPronto: Identifiable {
    let id = UUID()
    let url: URL
}

/// .zip feito pelo próprio iPhone (sem biblioteca). Os arquivos entram como estão, sem recodificar.
enum Zip {
    static func criar(_ urls: [URL], nome: String) async throws -> URL {
        try await Task.detached(priority: .userInitiated) { try montar(urls, nome: nome) }.value
    }

    private static func montar(_ urls: [URL], nome: String) throws -> URL {
        let fm = FileManager.default
        let raiz = fm.temporaryDirectory.appendingPathComponent("Zips", isDirectory: true)
        try? fm.removeItem(at: raiz)                       // o .zip anterior já foi entregue
        let limpo = nome.components(separatedBy: CharacterSet(charactersIn: "/\\:?%*|\"<>"))
            .joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        let base = limpo.isEmpty ? "Estudio" : String(limpo.prefix(80))
        let pasta = raiz.appendingPathComponent(base, isDirectory: true)
        try fm.createDirectory(at: pasta, withIntermediateDirectories: true)
        for u in urls {
            let d = Nuvem.semColisao(pasta.appendingPathComponent(u.lastPathComponent))
            do { try fm.linkItem(at: u, to: d) } catch { try fm.copyItem(at: u, to: d) }
        }
        let destino = raiz.appendingPathComponent(base + ".zip")
        var erroLeitura: NSError?
        var erroCopia: Error?
        NSFileCoordinator().coordinate(readingItemAt: pasta, options: .forUploading, error: &erroLeitura) { tmp in
            do { try fm.moveItem(at: tmp, to: destino) } catch { erroCopia = error }
        }
        try? fm.removeItem(at: pasta)
        if let erroLeitura { throw erroLeitura }
        if let erroCopia { throw erroCopia }
        return destino
    }
}

/// A folha de compartilhar do sistema, para um arquivo que acabou de ser criado.
struct FolhaCompartilhar: UIViewControllerRepresentable {
    let itens: [URL]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: itens, applicationActivities: nil)
    }
    func updateUIViewController(_ c: UIActivityViewController, context: Context) {}
}

/// Botão "Compartilhar": os arquivos como estão, ou todos dentro de um .zip.
struct MenuCompartilhar: View {
    let urls: [URL]
    let nome: String
    let titulo: String
    @Binding var aviso: String?
    @State private var compactando = false
    @State private var zipado: ArquivoPronto?

    var body: some View {
        Menu {
            ShareLink(items: urls) {
                Label(urls.count == 1 ? "Compartilhar o arquivo" : "Compartilhar os \(urls.count) arquivos",
                      systemImage: "square.and.arrow.up")
            }
            Button { compactar() } label: { Label("Compartilhar como .zip", systemImage: "doc.zipper") }
        } label: {
            Label(compactando ? "Compactando…" : titulo, systemImage: "square.and.arrow.up")
                .frame(maxWidth: .infinity).padding(.vertical, 4)
        }
        .buttonStyle(.glass)
        .disabled(compactando)
        .background {
            // a folha fica fora do botão de vidro
            Color.clear.sheet(item: $zipado) { z in
                FolhaCompartilhar(itens: [z.url]).presentationDetents([.medium, .large])
            }
        }
    }

    private func compactar() {
        compactando = true
        Task {
            do { let z = try await Zip.criar(urls, nome: nome); zipado = ArquivoPronto(url: z) }
            catch { aviso = "Não consegui criar o .zip: \(error.localizedDescription)" }
            compactando = false
        }
    }
}
