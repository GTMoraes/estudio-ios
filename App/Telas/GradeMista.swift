import SwiftUI

/// Grade de um resultado com fotos e vídeos juntos (carrossel do Instagram), na ordem dos arquivos.
/// O filtro mostra tudo, só as fotos ou só os vídeos. Tocar abre a tela cheia, que passa por todos.
struct GradeMista: View {
    let item: Item

    enum Filtro: String, CaseIterable, Identifiable {
        case tudo = "Tudo", fotos = "Fotos", videos = "Vídeos"
        var id: String { rawValue }
    }
    struct Aberto: Identifiable { let id: Int }

    @State private var filtro = Filtro.tudo
    @State private var aberto: Aberto?

    private var fotos: [String] { item.arquivos.filter { ehImagem(item.url($0)) } }
    private var videos: [String] { item.arquivos.filter { !ehImagem(item.url($0)) } }

    private var visiveis: [String] {
        switch filtro {
        case .tudo: return item.arquivos
        case .fotos: return fotos
        case .videos: return videos
        }
    }

    var body: some View {
        Picker("Mostrar", selection: $filtro) {
            ForEach(Filtro.allCases) { f in Text(f.rawValue).tag(f) }
        }
        .pickerStyle(.segmented)
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 92), spacing: 6)], spacing: 6) {
            ForEach(visiveis, id: \.self) { nome in
                Button { abrir(nome) } label: {
                    if ehImagem(item.url(nome)) { MiniaturaQuadrada(url: item.url(nome)) }
                    else { MiniaturaVideo(url: item.url(nome)) }
                }
                .buttonStyle(.plain)
            }
        }
        Text("Toque para ver em tela cheia, com as informações.")
            .font(.footnote).foregroundStyle(Tema.texto2)
            .fullScreenCover(item: $aberto) { a in
                // um visualizador só: deslizar passa por fotos e vídeos, no que o filtro estiver mostrando
                VisualizadorVideos(item: soCom(visiveis), inicio: a.id)
            }
    }

    private func abrir(_ nome: String) {
        if let k = visiveis.firstIndex(of: nome) { aberto = Aberto(id: k) }
    }

    private func soCom(_ nomes: [String]) -> Item {
        var c = item
        c.arquivos = nomes
        return c
    }
}
