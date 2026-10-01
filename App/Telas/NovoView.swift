import SwiftUI
import PhotosUI
import UniformTypeIdentifiers

struct NovoView: View {
    @Environment(Estudio.self) private var estudio
    @State private var link = ""
    @State private var escolhendoArquivo = false
    @State private var videosGaleria: [PhotosPickerItem] = []
    @State private var carregandoGaleria = false
    @State private var escolhendoImagens = false
    @State private var fotosGaleria: [PhotosPickerItem] = []
    @State private var carregandoFotos = false
    @State private var logadoGoogle = ContaGoogle.logado

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    Cartao(titulo: "Link do YouTube, Instagram, Drive…", icone: "link") {
                        HStack(spacing: 10) {
                            TextField("Cole o link aqui", text: $link)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                                .keyboardType(.URL)
                                .submitLabel(.go)
                                .onSubmit(abrirLink)
                                .padding(12)
                                .background(.white.opacity(0.06), in: .rect(cornerRadius: 14))
                            Button {
                                if let s = UIPasteboard.general.string { link = s.trimmingCharacters(in: .whitespacesAndNewlines) }
                            } label: {
                                Image(systemName: "doc.on.clipboard").frame(width: 28, height: 28)
                            }
                            .buttonStyle(.glass)
                        }
                        BotaoPrincipal(titulo: "Continuar", icone: "arrow.right",
                                       desativado: link.trimmingCharacters(in: .whitespaces).isEmpty, acao: abrirLink)
                        Text("Links do Google Drive abrem aqui mesmo, para navegar e escolher o que baixar. Os outros são baixados pela nuvem; o arquivo pronto vem para o iPhone.")
                            .font(.footnote).foregroundStyle(Tema.texto2)
                    }

                    if logadoGoogle {
                        Cartao(titulo: "Google Drive", icone: "externaldrive.fill.badge.icloud") {
                            VStack(spacing: 10) {
                                botaoDrive("Compartilhados comigo", "person.2.fill", Drive.compartilhados)
                                HStack(spacing: 10) {
                                    botaoDrive("Meu Drive", "externaldrive.fill", Drive.meuDrive)
                                    botaoDrive("Drives compartilhados", "building.2.fill", Drive.drivesCompartilhados)
                                }
                            }
                        }
                    }

                    Cartao(titulo: "Áudio ou vídeo", icone: "waveform.badge.plus") {
                        GlassEffectContainer(spacing: 12) {
                            HStack(spacing: 12) {
                                Button { escolhendoArquivo = true } label: {
                                    Label("Arquivos", systemImage: "folder.fill").frame(maxWidth: .infinity).padding(.vertical, 6)
                                }
                                .buttonStyle(.glass)
                                // .current: entrega o arquivo original (HEVC/Dolby Vision/60 fps); o padrão
                                // (.automatic) converte para H.264 SDR 30 fps antes de chegar ao app
                                PhotosPicker(selection: $videosGaleria, maxSelectionCount: 20, matching: .videos,
                                             preferredItemEncoding: .current) {
                                    Label(carregandoGaleria ? "Abrindo…" : "Galeria", systemImage: "photo.on.rectangle")
                                        .frame(maxWidth: .infinity).padding(.vertical, 6)
                                }
                                .buttonStyle(.glass)
                                .disabled(carregandoGaleria)
                            }
                        }
                        Text("Transcrever (texto e legenda .srt), tratar a voz ou converter (vídeo, MP3, OGG…).")
                            .font(.footnote).foregroundStyle(Tema.texto2)
                    }

                    Cartao(titulo: "Imagens", icone: "photo.stack") {
                        GlassEffectContainer(spacing: 12) {
                            HStack(spacing: 12) {
                                Button { escolhendoImagens = true } label: {
                                    Label("Arquivos", systemImage: "folder.fill").frame(maxWidth: .infinity).padding(.vertical, 6)
                                }
                                .buttonStyle(.glass)
                                // .current: o arquivo original (HEIC com a cor P3 e os metadados), sem o iOS converter antes
                                PhotosPicker(selection: $fotosGaleria, maxSelectionCount: 50, matching: .images,
                                             preferredItemEncoding: .current) {
                                    Label(carregandoFotos ? "Abrindo…" : "Galeria", systemImage: "photo.on.rectangle")
                                        .frame(maxWidth: .infinity).padding(.vertical, 6)
                                }
                                .buttonStyle(.glass)
                                .disabled(carregandoFotos)
                            }
                        }
                        Text("Converter para WebP, JPG, HEIC ou PNG, reduzir, cortar e limpar os metadados — uma ou várias de uma vez.")
                            .font(.footnote).foregroundStyle(Tema.texto2)
                    }

                    Cartao(titulo: "Pelo Compartilhar", icone: "square.and.arrow.up") {
                        Text("Em qualquer app, toque em Compartilhar e escolha **Estúdio** — vale para vídeos, áudios e links. Se ele não aparecer na lista, toque em “Mais” e ative.")
                            .font(.subheadline).foregroundStyle(Tema.texto2)
                    }
                }
                .padding(.horizontal)
                .padding(.bottom, 24)
            }
            .telaEscura()
            .navigationTitle("Estúdio")
            .onAppear { logadoGoogle = ContaGoogle.logado }
            // um .fileImporter só: dois na mesma tela brigam e só o último funciona
            .fileImporter(isPresented: Binding(get: { escolhendoArquivo || escolhendoImagens },
                                               set: { if !$0 { escolhendoArquivo = false; escolhendoImagens = false } }),
                          allowedContentTypes: escolhendoImagens ? [.image] : [.audio, .movie, .audiovisualContent],
                          allowsMultipleSelection: true) { r in
                // o seletor ainda está fechando quando este bloco roda; abrir a folha agora
                // faz o iOS descartá-la em silêncio. Espera o seletor sumir.
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 600_000_000)
                    switch r {
                    case .success(let urls): estudio.importarVarios(urls)
                    case .failure(let erro): estudio.aviso = "Não consegui abrir o arquivo: \(erro.localizedDescription)"
                    }
                }
            }
            .onChange(of: fotosGaleria) { _, novos in
                guard !novos.isEmpty else { return }
                carregandoFotos = true
                Task {
                    defer { carregandoFotos = false; fotosGaleria = [] }
                    var urls: [URL] = []
                    for item in novos {
                        if let f = try? await item.loadTransferable(type: ImagemDaGaleria.self) { urls.append(f.url) }
                    }
                    if urls.isEmpty { estudio.aviso = "Não consegui abrir as fotos da galeria."; return }
                    estudio.importarVarios(urls)
                    urls.forEach { try? FileManager.default.removeItem(at: $0) }
                }
            }
            .onChange(of: videosGaleria) { _, novos in
                guard !novos.isEmpty else { return }
                carregandoGaleria = true
                Task {
                    defer { carregandoGaleria = false; videosGaleria = [] }
                    var urls: [URL] = [], nomes: [String] = [], falhas = 0
                    for item in novos {
                        if let v = try? await item.loadTransferable(type: VideoDaGaleria.self) {
                            urls.append(v.url); nomes.append(v.nome)
                        } else { falhas += 1 }
                    }
                    // um vídeo abre o conversor normal; vários viram um lote
                    if !urls.isEmpty { estudio.importarVarios(urls, nomes: nomes) }
                    urls.forEach { try? FileManager.default.removeItem(at: $0) }
                    if falhas > 0 { estudio.aviso = "Não consegui abrir \(falhas) vídeo(s) da galeria." }
                }
            }
        }
    }

    private func botaoDrive(_ titulo: String, _ icone: String, _ lugar: String) -> some View {
        Button { estudio.receber(.drive(lugar)) } label: {
            Label(titulo, systemImage: icone)
                .font(.subheadline).lineLimit(1).minimumScaleFactor(0.8)
                .frame(maxWidth: .infinity).padding(.vertical, 6)
        }
        .buttonStyle(.glass)
    }

    private func abrirLink() {
        let t = link.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        let url = primeiroLink(em: t)?.absoluteString ?? (t.hasPrefix("http") ? t : "https://" + t)
        estudio.receber(.link(url))
        link = ""
    }
}

/// Vídeo da galeria copiado para um arquivo temporário do app.
struct VideoDaGaleria: Transferable {
    let url: URL
    var nome: String
    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(contentType: .movie) { v in
            SentTransferredFile(v.url)
        } importing: { recebido in
            let destino = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString + "-" + recebido.file.lastPathComponent)
            try FileManager.default.copyItem(at: recebido.file, to: destino)
            return VideoDaGaleria(url: destino, nome: recebido.file.lastPathComponent)
        }
    }
}

/// Foto da galeria copiada como arquivo (o original: HEIC, JPG, PNG…).
struct ImagemDaGaleria: Transferable {
    let url: URL
    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(importedContentType: .image) { recebido in
            let pasta = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: pasta, withIntermediateDirectories: true)
            let destino = pasta.appendingPathComponent(recebido.file.lastPathComponent)
            try FileManager.default.copyItem(at: recebido.file, to: destino)
            return ImagemDaGaleria(url: destino)
        }
    }
}
