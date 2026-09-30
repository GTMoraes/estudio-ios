import SwiftUI

/// Folha que aparece quando chega um link ou arquivo: escolhe o que fazer.
struct ProcessarView: View {
    @Environment(Estudio.self) private var estudio
    @Environment(\.dismiss) private var fechar
    let entrada: Entrada

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    switch entrada {
                    case .link(let l): PainelLink(link: l, fechar: { fechar() })
                    case .arquivo(let u, let nome): PainelArquivo(arquivo: u, nome: nome, fechar: { fechar() })
                    case .imagens(let us): PainelImagens(arquivos: us, fechar: { fechar() })
                    }
                }
                .padding()
            }
            .telaEscura()
            .navigationTitle(tituloTela)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Fechar", systemImage: "xmark") {
                        if case .arquivo(let u, _) = entrada { try? FileManager.default.removeItem(at: u) }
                        if case .imagens(let us) = entrada { us.forEach { try? FileManager.default.removeItem(at: $0) } }
                        fechar()
                    }
                }
            }
        }
        .presentationDetents([.large])
    }

    private var tituloTela: String {
        if case .link = entrada { return "Link" }
        if case .imagens(let us) = entrada { return us.count == 1 ? "Imagem" : "\(us.count) imagens" }
        return "Arquivo"
    }
}

/// Opções comuns: onde processar e idioma.
struct OpcoesTranscricao: View {
    @Binding var naNuvem: Bool
    @Binding var idioma: String

    var body: some View {
        Toggle(isOn: $naNuvem) {
            Label("Processar na nuvem", systemImage: "cloud.fill")
        }
        Text(naNuvem ? "Envia para a sua nuvem e recebe o resultado aqui."
                     : "Roda no Neural Engine do iPhone, sem internet (a 1ª vez baixa o modelo).")
            .font(.footnote).foregroundStyle(Tema.texto2)
        Picker("Idioma", selection: $idioma) {
            Text("Português").tag("pt")
            Text("Detectar").tag("auto")
        }
        .pickerStyle(.segmented)
    }
}

// MARK: - link

struct PainelLink: View {
    @Environment(Estudio.self) private var estudio
    let link: String
    var fechar: () -> Void

    @State private var info: InfoLink?
    @State private var erro: String?
    @State private var naNuvem = UserDefaults.standard.bool(forKey: "nuvemPorPadrao")
    @State private var idioma = UserDefaults.standard.string(forKey: "idioma") ?? "pt"
    @State private var padrao = PadraoNome.ler(.link)

    private func usar() { PadraoNome.gravar(padrao, .link) }

    var body: some View {
        Group {
            if let info {
                Cartao {
                    Text(info.titulo).font(.title3.weight(.semibold))
                    HStack(spacing: 8) {
                        if !info.site.isEmpty { Text(info.site) }
                        if !info.autor.isEmpty { Text("·"); Text(info.autor).lineLimit(1) }
                        if let d = formatarDuracao(info.duracao) { Text("·"); Text(d) }
                    }
                    .font(.subheadline).foregroundStyle(Tema.texto2)
                }
                let b = PadraoNome.base(info.titulo, padrao: padrao, data: Date())
                CartaoNomeSaida(padrao: $padrao, previa: [b + ".mp4 / .m4a / .txt"],
                                nota: "{nome} = título do vídeo; {data} e {datahora} = agora. Vale para baixar e transcrever.")
                Cartao(titulo: "Baixar", icone: "arrow.down.circle.fill") {
                    GlassEffectContainer(spacing: 12) {
                        HStack(spacing: 12) {
                            Button { usar(); estudio.baixarLink(info, modo: "video", padrao: padrao); fechar() } label: {
                                Label("Vídeo", systemImage: "film").frame(maxWidth: .infinity).padding(.vertical, 6)
                            }
                            .buttonStyle(.glassProminent).tint(Tema.acento)
                            Button { usar(); estudio.baixarLink(info, modo: "audio", padrao: padrao); fechar() } label: {
                                Label("Só o áudio", systemImage: "music.note").frame(maxWidth: .infinity).padding(.vertical, 6)
                            }
                            .buttonStyle(.glass)
                        }
                    }
                }
                Cartao(titulo: "Transcrever", icone: "text.quote") {
                    OpcoesTranscricao(naNuvem: $naNuvem, idioma: $idioma)
                    BotaoPrincipal(titulo: "Transcrever", icone: "text.badge.checkmark") {
                        usar(); estudio.transcreverLink(info, naNuvem: naNuvem, idioma: idioma, padrao: padrao); fechar()
                    }
                }
            } else if let erro {
                Cartao(titulo: "Não deu para identificar", icone: "exclamationmark.triangle.fill") {
                    Text(erro).foregroundStyle(Tema.texto2)
                    Text(link).font(.footnote.monospaced()).foregroundStyle(Tema.texto2).lineLimit(3)
                    Button("Tentar de novo") { self.erro = nil; Task { await identificar() } }
                        .buttonStyle(.glass)
                }
            } else {
                Cartao {
                    HStack(spacing: 12) {
                        ProgressView()
                        Text("Identificando o link na nuvem…")
                    }
                    Text(link).font(.footnote.monospaced()).foregroundStyle(Tema.texto2).lineLimit(3)
                }
            }
        }
        .task { await identificar() }
    }

    private func identificar() async {
        guard info == nil else { return }
        do { info = try await estudio.nuvem.identificar(link: link) }
        catch { erro = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription }
    }
}

// MARK: - arquivo

struct PainelArquivo: View {
    @Environment(Estudio.self) private var estudio
    let arquivo: URL
    let nome: String
    var fechar: () -> Void

    enum Acao: String, CaseIterable, Identifiable {
        case converter = "Converter", voz = "Tratar voz", transcrever = "Transcrever"
        var id: String { rawValue }
    }

    @State private var acao: Acao = .converter
    @State private var duracao: Double?
    @State private var naNuvem = UserDefaults.standard.bool(forKey: "nuvemPorPadrao")
    @State private var idioma = UserDefaults.standard.string(forKey: "idioma") ?? "pt"
    @State private var voz = OpcoesVoz.padrao(.fala)
    @State private var quadra = false
    @State private var padraoTrans = PadraoNome.ler(.transcricao)
    @State private var padraoVoz = PadraoNome.ler(.voz)
    @State private var dataOriginal = Date()

    private let notaData = "{data} e {datahora} = quando o áudio/vídeo foi gravado (se o arquivo não disser, a data do arquivo)."

    private func nomesVoz(_ b: String) -> [String] {
        let suf = quadra && !naNuvem ? "-quadra" : ""
        return voz.modo == .soVoz ? ["\(b)-voz-tratada\(suf).mp3"]
            : ["\(b)-mix-tratado\(suf).mp3", "\(b)-voz-tratada\(suf).mp3", "\(b)-trilha-separada\(suf).mp3"]
    }

    var body: some View {
        Cartao {
            Label(nome, systemImage: "doc.fill").font(.headline).lineLimit(2)
            if let d = formatarDuracao(duracao) {
                Text(d).font(.subheadline).foregroundStyle(Tema.texto2)
            }
        }
        .task {
            duracao = await AudioUtil.duracao(arquivo)
            dataOriginal = await DataMidia.ler(arquivo)
        }

        Picker("O que fazer", selection: $acao) {
            ForEach(Acao.allCases) { Text($0.rawValue).tag($0) }
        }
        .pickerStyle(.segmented)

        switch acao {
        case .converter:
            PainelConverter(arquivo: arquivo, nome: nome, fechar: fechar)
        case .transcrever:
            Cartao(titulo: "Transcrever", icone: "text.quote") {
                OpcoesTranscricao(naNuvem: $naNuvem, idioma: $idioma)
                Text("Sai o texto completo (.txt) e a legenda com tempos (.srt).")
                    .font(.footnote).foregroundStyle(Tema.texto2)
            }
            let bt = PadraoNome.base(nome, padrao: padraoTrans, data: dataOriginal)
            CartaoNomeSaida(padrao: $padraoTrans, previa: [bt + ".txt", bt + ".srt"], nota: notaData)
            BotaoPrincipal(titulo: "Transcrever", icone: "text.badge.checkmark") {
                PadraoNome.gravar(padraoTrans, .transcricao)
                estudio.transcrever(arquivo, nome: nome, naNuvem: naNuvem, idioma: idioma,
                                    padrao: padraoTrans, data: dataOriginal); fechar()
            }
        case .voz:
            Cartao(titulo: "Tratar voz", icone: "waveform") {
                Picker("Tipo de áudio", selection: Binding(get: { voz.modo }, set: { voz = OpcoesVoz.padrao($0) })) {
                    ForEach(OpcoesVoz.Modo.allCases) { Text($0.nome).tag($0) }
                }
                .pickerStyle(.segmented)
                Toggle("Tirar eco", isOn: $voz.eco)
                Toggle("Clareza da fala", isOn: $voz.clareza)
                if voz.modo != .soVoz {
                    Picker("Voz à frente no mix", selection: $voz.vozFrente) {
                        Text("Igual ao original").tag(0)
                        Text("+3 dB").tag(3)
                        Text("+6 dB").tag(6)
                    }
                }
                Picker("Onde vai tocar", selection: $quadra) {
                    Text("Padrão").tag(false)
                    Text("Quadra / ginásio").tag(true)
                }
                .disabled(naNuvem)
                if quadra && !naNuvem {
                    Text("Para som de PA em quadra: mono, sem graves abaixo de 110 Hz e clareza sem compressor.")
                        .font(.footnote).foregroundStyle(Tema.texto2)
                }
                Toggle(isOn: $naNuvem) {
                    Label("Processar na nuvem", systemImage: "cloud.fill")
                }
                Text(naNuvem ? "Envia para a sua nuvem e recebe os MP3 aqui (a opção Quadra ainda não existe na nuvem)."
                             : ModelosVoz.prontos ? "Roda no iPhone, sem internet. Deixe o app aberto até terminar."
                             : "Roda no iPhone. A 1ª vez baixa e prepara os modelos de voz (580 MB, uma vez só).")
                    .font(.footnote).foregroundStyle(Tema.texto2)
            }
            CartaoNomeSaida(padrao: $padraoVoz,
                            previa: nomesVoz(PadraoNome.base(nome, padrao: padraoVoz, data: dataOriginal)), nota: notaData)
            BotaoPrincipal(titulo: "Tratar voz", icone: "wand.and.stars") {
                PadraoNome.gravar(padraoVoz, .voz)
                estudio.tratarVoz(arquivo, nome: nome, opcoes: voz, quadra: quadra && !naNuvem, naNuvem: naNuvem,
                                  padrao: padraoVoz, data: dataOriginal); fechar()
            }
        }
    }
}
