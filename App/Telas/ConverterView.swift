import SwiftUI
import AVKit

/// Converter vídeo/áudio no iPhone (as predefinições do ConversorMidia).
struct PainelConverter: View {
    @Environment(Estudio.self) private var estudio
    let arquivo: URL
    let nome: String
    var fechar: () -> Void

    @State private var info: InfoMidia?
    @State private var erro: String?
    @State private var preset: PresetConversao = .instagramHDR
    @State private var o = OpcoesConversao()
    @State private var usarAlvo = false

    var body: some View {
        if let info {
            conteudo(info)
        } else if let erro {
            Cartao { Label(erro, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.yellow) }
        } else {
            Cartao { HStack { ProgressView(); Text("Lendo o arquivo…") } }
                .task { await carregar() }
        }
    }

    private func carregar() async {
        do {
            let i = try await InfoMidia.ler(arquivo)
            info = i
            let inicial: PresetConversao = !i.temVideo ? .audio : (i.hdr != .sdr ? .instagramHDR : .instagramSDR)
            escolher(inicial)
        } catch {
            erro = "Não consegui ler esse arquivo: \(error.localizedDescription)"
        }
    }

    private func escolher(_ p: PresetConversao) {
        preset = p
        p.aplicar(&o)
        if p == .audio, let info, info.audioAAC { o.formatoAudio = .m4a }
        usarAlvo = o.alvoMB != nil
    }

    /// Mexer num ajuste troca a predefinição para "Personalizado" (os controles mandam).
    private func ajuste<T>(_ kp: WritableKeyPath<OpcoesConversao, T>) -> Binding<T> {
        Binding(get: { o[keyPath: kp] }, set: { o[keyPath: kp] = $0; preset = .personalizado })
    }

    @ViewBuilder private func conteudo(_ info: InfoMidia) -> some View {
        Cartao {
            Text(info.resumo).font(.subheadline).foregroundStyle(Tema.texto2)
        }

        Cartao(titulo: "Predefinição", icone: "slider.horizontal.3") {
            Picker("Predefinição", selection: Binding(get: { preset }, set: { escolher($0) })) {
                ForEach(PresetConversao.allCases.filter { info.temVideo || $0 == .audio || $0 == .personalizado }) { p in
                    Text(p.nome).tag(p)
                }
            }
            .pickerStyle(.menu)
            Text(preset.dica).font(.footnote).foregroundStyle(Tema.texto2)
        }

        if info.temVideo && preset == .personalizado {
            Cartao(titulo: "Ação", icone: "arrow.triangle.2.circlepath") {
                Picker("Ação", selection: $o.acao) {
                    Text("Recodificar").tag(OpcoesConversao.Acao.video)
                    Text("Sem recodificar").tag(OpcoesConversao.Acao.semRecodificar)
                    Text("Só o áudio").tag(OpcoesConversao.Acao.audio)
                }
                .pickerStyle(.segmented)
            }
        }

        switch o.acao {
        case .video: ajustesVideo(info)
        case .audio: ajustesAudio(info)
        case .semRecodificar: EmptyView()
        }

        PainelTrecho(arquivo: arquivo, info: info, inicio: $o.inicio, fim: $o.fim)

        Cartao {
            avisos(info)
            HStack {
                Label("Tamanho estimado", systemImage: "internaldrive")
                Spacer()
                Text(ByteCountFormatter.string(fromByteCount: PlanoConversao.tamanhoEstimado(info, o), countStyle: .file))
                    .monospacedDigit().fontWeight(.semibold)
            }
            BotaoPrincipal(titulo: "Converter", icone: "arrow.triangle.2.circlepath") {
                estudio.converter(arquivo, nome: nome, info: info, opcoes: o); fechar()
            }
        }
    }

    // MARK: vídeo

    @ViewBuilder private func ajustesVideo(_ info: InfoMidia) -> some View {
        Cartao(titulo: "Vídeo", icone: "film") {
            Picker("Formato", selection: ajuste(\.codec)) {
                Text("HEVC").tag(OpcoesConversao.Codec.hevc)
                Text("H.264").tag(OpcoesConversao.Codec.h264)
            }
            .pickerStyle(.segmented)
            Label {
                Text("**AV1** — em breve, pela nuvem. Nem o iPhone nem a placa da nuvem codificam AV1 por hardware, então não será rápido em lugar nenhum; mas é um ótimo formato (arquivo bem menor na mesma qualidade).")
            } icon: { Image(systemName: "hourglass") }
            .font(.footnote).foregroundStyle(Tema.texto2)

            Picker("Resolução (lado maior)", selection: ajuste(\.ladoMaior)) {
                Text("Original (\(max(info.largura, info.altura)))").tag(0)
                // o valor atual sempre precisa ter uma opção (a predefinição pode pôr 1080 num vídeo 720)
                ForEach([2160, 1440, 1080, 720, 480].filter { $0 < max(info.largura, info.altura) || $0 == o.ladoMaior }, id: \.self) { Text("\($0)").tag($0) }
            }
            Picker("Quadros por segundo", selection: ajuste(\.fps)) {
                Text(info.fps > 0 ? String(format: "Original (%.0f)", info.fps) : "Original").tag(0)
                ForEach([60, 30, 25, 24].filter { Double($0) < info.fps - 0.5 || $0 == o.fps }, id: \.self) { Text("\($0)").tag($0) }
            }
            Text("A saída sempre tem taxa de quadros constante (resolve o fps variável do iPhone).")
                .font(.caption).foregroundStyle(Tema.texto2)

            if info.hdr != .sdr {
                Toggle("Manter HDR", isOn: Binding(get: { o.saida == .manterHDR && o.codec == .hevc },
                                                  set: { o.saida = $0 ? .manterHDR : .sdr; preset = .personalizado }))
                    .disabled(o.codec == .h264)
            }

            Toggle("Alvo de tamanho", isOn: Binding(get: { usarAlvo }, set: {
                usarAlvo = $0; o.alvoMB = $0 ? (o.alvoMB ?? 50) : nil; preset = .personalizado
            }))
            if usarAlvo {
                HStack {
                    Text("Tamanho final")
                    Spacer()
                    TextField("MB", value: Binding(get: { o.alvoMB ?? 50 }, set: { o.alvoMB = max(1, $0); preset = .personalizado }),
                              format: .number.precision(.fractionLength(0...1)))
                        .keyboardType(.decimalPad).multilineTextAlignment(.trailing).frame(width: 90)
                    Text("MB")
                }
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Qualidade")
                        Spacer()
                        Text(String(format: "%.1f Mb/s", PlanoConversao.taxaVideo(info, o) / 1_000_000))
                            .monospacedDigit().foregroundStyle(Tema.texto2)
                    }
                    Slider(value: ajuste(\.qualidade), in: 0...1)
                    HStack { Text("menor arquivo"); Spacer(); Text("melhor imagem") }
                        .font(.caption2).foregroundStyle(Tema.texto2)
                }
            }
        }

        if info.temAudio {
            Cartao(titulo: "Áudio do vídeo", icone: "speaker.wave.2") {
                if info.audioAAC {
                    Toggle("Copiar sem recodificar", isOn: ajuste(\.copiarAudio))
                }
                if !(info.audioAAC && o.copiarAudio) {
                    Picker("AAC", selection: ajuste(\.audioKbps)) {
                        ForEach([128, 160, 192, 256, 320], id: \.self) { Text("\($0) kb/s").tag($0) }
                    }
                }
            }
        }
    }

    // MARK: áudio

    @ViewBuilder private func ajustesAudio(_ info: InfoMidia) -> some View {
        Cartao(titulo: "Áudio", icone: "music.note") {
            Picker("Formato", selection: ajuste(\.formatoAudio)) {
                ForEach(OpcoesConversao.FormatoAudio.allCases) { Text($0.nome).tag($0) }
            }
            .pickerStyle(.segmented)
            switch o.formatoAudio {
            case .m4a:
                if info.audioAAC { Toggle("Copiar o AAC sem recodificar", isOn: ajuste(\.copiarAudio)) }
                if !(info.audioAAC && o.copiarAudio) {
                    Picker("Taxa", selection: ajuste(\.audioKbps)) {
                        ForEach([128, 160, 192, 256, 320], id: \.self) { Text("\($0) kb/s").tag($0) }
                    }
                }
            case .mp3:
                Picker("Taxa", selection: ajuste(\.mp3Kbps)) {
                    ForEach([96, 128, 160, 192, 256, 320], id: \.self) { Text("\($0) kb/s").tag($0) }
                }
            case .ogg:
                VStack(alignment: .leading) {
                    HStack { Text("Qualidade"); Spacer(); Text(String(format: "%.0f", o.oggQualidade)).monospacedDigit() }
                    Slider(value: ajuste(\.oggQualidade), in: 0...10, step: 1)
                    Text("6 ≈ 190 kb/s. Igual ao -q:a do ffmpeg.").font(.caption).foregroundStyle(Tema.texto2)
                }
            case .wav:
                Picker("Amostragem", selection: ajuste(\.wavTaxa)) {
                    Text("Original (\(Int(info.taxaAudio)) Hz)").tag(0)
                    Text("48000 Hz").tag(48000)
                    Text("44100 Hz").tag(44100)
                }
            }
        }
    }

    // MARK: avisos

    @ViewBuilder private func avisos(_ info: InfoMidia) -> some View {
        if o.acao == .video {
            if info.hdr != .sdr && !PlanoConversao.hdrSaida(info, o) {
                Label("O HDR vai virar SDR (conversão feita pelo iOS).", systemImage: "sun.max.trianglebadge.exclamationmark")
                    .font(.footnote).foregroundStyle(.yellow)
            }
            if info.dolbyVision {
                Label("O Dolby Vision vai se perder ao recodificar (fica o HDR comum, se mantido). Para manter, use \"sem recodificar\".",
                      systemImage: "exclamationmark.triangle")
                    .font(.footnote).foregroundStyle(.yellow)
            }
        }
        if o.acao == .semRecodificar {
            Label("Sem recodificar, o corte cai no keyframe mais próximo (pode começar um pouco antes).", systemImage: "info.circle")
                .font(.footnote).foregroundStyle(Tema.texto2)
        }
    }
}

/// Escolher um trecho: prévia, início e fim.
struct PainelTrecho: View {
    let arquivo: URL
    let info: InfoMidia
    @Binding var inicio: Double?
    @Binding var fim: Double?
    @State private var player: AVPlayer?

    private var ativo: Binding<Bool> {
        Binding(get: { inicio != nil || fim != nil },
                set: { if $0 { inicio = 0; fim = info.duracao } else { inicio = nil; fim = nil } })
    }

    var body: some View {
        Cartao(titulo: "Trecho", icone: "scissors") {
            Toggle("Cortar um trecho", isOn: ativo)
            if ativo.wrappedValue {
                if info.temVideo, let player {
                    VideoPlayer(player: player).frame(height: 200).clipShape(.rect(cornerRadius: 16))
                }
                controle("Início", valor: Binding(get: { inicio ?? 0 }, set: { inicio = min($0, (fim ?? info.duracao) - 0.1); mostrar(inicio ?? 0) }))
                controle("Fim", valor: Binding(get: { fim ?? info.duracao }, set: { fim = max($0, (inicio ?? 0) + 0.1); mostrar(fim ?? info.duracao) }))
                Text("Duração: \(formatarDuracao(max(0, (fim ?? info.duracao) - (inicio ?? 0))) ?? "—")")
                    .font(.footnote).foregroundStyle(Tema.texto2)
            }
        }
        .onAppear { if info.temVideo, player == nil { player = AVPlayer(url: arquivo) } }
        .onDisappear { player?.pause() }
    }

    private func controle(_ titulo: String, valor: Binding<Double>) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(titulo)
                Spacer()
                Text(Legenda.tempo(valor.wrappedValue).replacingOccurrences(of: ",", with: "."))
                    .font(.footnote.monospacedDigit()).foregroundStyle(Tema.texto2)
                if player != nil {
                    Button("Aqui") {
                        if let t = player?.currentTime().seconds, t.isFinite { valor.wrappedValue = t }
                    }
                    .buttonStyle(.glass).font(.footnote)
                }
            }
            Slider(value: valor, in: 0...max(info.duracao, 0.2))
        }
    }

    private func mostrar(_ t: Double) {
        player?.pause()
        player?.seek(to: CMTime(seconds: t, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
    }
}
