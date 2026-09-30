import SwiftUI
import PhotosUI
import UniformTypeIdentifiers

struct NovoView: View {
    @Environment(Estudio.self) private var estudio
    @State private var link = ""
    @State private var escolhendoArquivo = false
    @State private var itemGaleria: PhotosPickerItem?
    @State private var carregandoGaleria = false
    @State private var escolhendoImagens = false
    @State private var fotosGaleria: [PhotosPickerItem] = []
    @State private var carregandoFotos = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    Cartao(titulo: "Link do YouTube, Instagram…", icone: "link") {
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
                        Text("O download dos links é feito pela nuvem; o arquivo pronto vem para o iPhone.")
                            .font(.footnote).foregroundStyle(Tema.texto2)
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
                                PhotosPicker(selection: $itemGaleria, matching: .videos, preferredItemEncoding: .current) {
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
            .onChange(of: itemGaleria) { _, novo in
                guard let novo else { return }
                carregandoGaleria = true
                Task {
                    defer { carregandoGaleria = false; itemGaleria = nil }
                    do {
                        let video = try await novo.loadTransferable(type: VideoDaGaleria.self)
                        if let v = video {
                            estudio.importar(v.url, nome: v.nome)
                            try? FileManager.default.removeItem(at: v.url)
                        }
                    } catch {
                        estudio.aviso = "Não consegui abrir o vídeo da galeria: \(error.localizedDescription)"
                    }
                }
            }
        }
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
