import SwiftUI
import AVKit

/// Converter vídeo/áudio no iPhone (as predefinições do ConversorMidia + as suas).
struct PainelConverter: View {
    @Environment(Estudio.self) private var estudio
    let arquivo: URL
    let nome: String
    var fechar: () -> Void

    @State private var info: InfoMidia?
    @State private var erro: String?
    /// "p:<preset embutido>" ou "s:<id de um preset salvo>"
    @State private var selecao = "p:" + PresetConversao.instagramHDR.rawValue
    @State private var o = OpcoesConversao()
    @State private var pedindoNome = false
    @State private var nomeNovo = ""
    @State private var meus = MeusPresets.shared

    private let personalizado = "p:" + PresetConversao.personalizado.rawValue

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
            escolher("p:" + inicial.rawValue)
        } catch {
            erro = "Não consegui ler esse arquivo: \(error.localizedDescription)"
        }
    }

    private var salvoAtivo: PresetSalvo? {
        guard selecao.hasPrefix("s:"), let id = UUID(uuidString: String(selecao.dropFirst(2))) else { return nil }
        return meus.preset(id)
    }

    private func escolher(_ tag: String) {
        selecao = tag
        if tag.hasPrefix("s:"), let id = UUID(uuidString: String(tag.dropFirst(2))), let p = meus.preset(id) {
            let trecho = (o.inicio, o.fim), vel = o.velocidade
            o = p.opcoes
            (o.inicio, o.fim) = trecho
            if o.acao != .semRecodificar && vel != 1 { o.velocidade = vel }
        } else if let p = PresetConversao(rawValue: String(tag.dropFirst(2))) {
            p.aplicar(&o)
            if p == .audio, let info, info.audioAAC { o.formatoAudio = .m4a }
        }
    }

    /// Mexer num ajuste troca a predefinição para "Personalizado" (os controles mandam).
    private func ajuste<T>(_ kp: WritableKeyPath<OpcoesConversao, T>) -> Binding<T> {
        Binding(get: { o[keyPath: kp] }, set: { o[keyPath: kp] = $0; selecao = personalizado })
    }

    private var presetEmbutido: PresetConversao? {
        selecao.hasPrefix("p:") ? PresetConversao(rawValue: String(selecao.dropFirst(2))) : nil
    }

    @ViewBuilder private func conteudo(_ info: InfoMidia) -> some View {
        Cartao {
            Text(info.resumo).font(.subheadline).foregroundStyle(Tema.texto2)
        }

        Cartao(titulo: "Predefinição", icone: "slider.horizontal.3") {
            Picker("Predefinição", selection: Binding(get: { selecao }, set: { escolher($0) })) {
                ForEach(PresetConversao.allCases.filter { info.temVideo || $0 == .audio || $0 == .personalizado }) { p in
                    Text(p.nome).tag("p:" + p.rawValue)
                }
                if !meus.lista.isEmpty {
                    Divider()
                    ForEach(meus.lista) { p in
                        Label(p.nome, systemImage: "star.fill").tag("s:" + p.id.uuidString)
                    }
                }
            }
            .pickerStyle(.menu)
            if let p = presetEmbutido {
                Text(p.dica).font(.footnote).foregroundStyle(Tema.texto2)
            } else if let s = salvoAtivo {
                Text("Seu preset “\(s.nome)”.").font(.footnote).foregroundStyle(Tema.texto2)
            }
            HStack(spacing: 10) {
                Button {
                    nomeNovo = ""; pedindoNome = true
                } label: { Label("Salvar como preset", systemImage: "star") }
                .buttonStyle(.glass)
                if let s = salvoAtivo {
                    Menu {
                        Button("Regravar “\(s.nome)” com os ajustes atuais", systemImage: "square.and.arrow.down") {
                            meus.salvar(nome: s.nome, opcoes: o, substituir: s.id)
                        }
                        Button("Apagar “\(s.nome)”", systemImage: "trash", role: .destructive) {
                            meus.remover(s.id); escolher(personalizado)
                        }
                    } label: { Image(systemName: "ellipsis").frame(width: 22, height: 22) }
                    .buttonStyle(.glass)
                }
            }
            .font(.footnote)
        }
        .alert("Nome do preset", isPresented: $pedindoNome) {
            TextField("Ex.: Reels leve", text: $nomeNovo)
            Button("Salvar") {
                let id = meus.salvar(nome: nomeNovo, opcoes: o)
                selecao = "s:" + id.uuidString
            }
            Button("Cancelar", role: .cancel) {}
        } message: {
            Text("Guarda todos os ajustes de agora (menos o trecho).")
        }

        if info.temVideo && presetEmbutido == .personalizado {
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

        if o.acao != .semRecodificar { velocidade(info) }

        PainelTrecho(arquivo: arquivo, info: info, inicio: $o.inicio, fim: $o.fim)

        Cartao {
            avisos(info)
            if o.acao == .video {
                let dims = PlanoConversao.dimensoes(info, o)
                HStack {
                    Label("Resultado", systemImage: "rectangle.dashed")
                    Spacer()
                    Text("\(dims.0)×\(dims.1) · \(String(format: "%.1f", PlanoConversao.taxaVideo(info, o) / 1_000_000)) Mb/s")
                        .monospacedDigit().foregroundStyle(Tema.texto2)
                }
            }
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

    private func rotulo(_ info: InfoMidia, ladoMenor: Int) -> String {
        var t = o; t.ladoMenor = ladoMenor
        let (w, h) = PlanoConversao.dimensoes(info, t)
        switch ladoMenor {
        case 0: return "Original (\(w)×\(h))"
        case -1: return "Personalizada…"
        default: return "\(ladoMenor)p (\(w)×\(h))"
        }
    }

    @ViewBuilder private func ajustesVideo(_ info: InfoMidia) -> some View {
        let menor = min(info.largura, info.altura)
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

            // cor: sempre visível
            VStack(alignment: .leading, spacing: 6) {
                Text("Cor").font(.subheadline.weight(.semibold))
                if info.hdr == .sdr {
                    Text("O original é SDR.").font(.footnote).foregroundStyle(Tema.texto2)
                } else {
                    Picker("Cor", selection: Binding(get: { o.saida }, set: { o.saida = $0; selecao = personalizado })) {
                        Text("Manter HDR").tag(OpcoesConversao.Saida.manterHDR)
                        Text("Converter para SDR").tag(OpcoesConversao.Saida.sdr)
                    }
                    .pickerStyle(.segmented)
                    .disabled(o.codec == .h264)
                    Text(o.codec == .h264 ? "H.264 não leva HDR: sai em SDR (o iOS faz a conversão)."
                                          : "Original: \(info.dolbyVision ? "Dolby Vision" : info.hdr.rawValue).")
                        .font(.footnote).foregroundStyle(Tema.texto2)
                }
            }

            // resolução: 1080p = 1080 no lado menor (vale deitado e em pé)
            Picker("Resolução", selection: ajuste(\.ladoMenor)) {
                Text(rotulo(info, ladoMenor: 0)).tag(0)
                ForEach([2160, 1440, 1080, 720, 480].filter { $0 < menor || $0 == o.ladoMenor }, id: \.self) {
                    Text(rotulo(info, ladoMenor: $0)).tag($0)
                }
                Text(rotulo(info, ladoMenor: -1)).tag(-1)
            }
            if o.ladoMenor == -1 {
                HStack {
                    TextField("Largura", value: ajuste(\.caixaLargura), format: .number)
                        .keyboardType(.numberPad).multilineTextAlignment(.center)
                        .padding(8).background(.white.opacity(0.06), in: .rect(cornerRadius: 10))
                    Text("×")
                    TextField("Altura", value: ajuste(\.caixaAltura), format: .number)
                        .keyboardType(.numberPad).multilineTextAlignment(.center)
                        .padding(8).background(.white.opacity(0.06), in: .rect(cornerRadius: 10))
                }
                Text("O vídeo cabe dentro dessa caixa mantendo a proporção; nunca aumenta.")
                    .font(.caption).foregroundStyle(Tema.texto2)
            }

            Picker("Quadros por segundo", selection: ajuste(\.fps)) {
                Text(info.fps > 0 ? String(format: "Original (%.0f)", info.fps) : "Original").tag(0)
                ForEach([60, 30, 25, 24].filter { Double($0) < info.fps - 0.5 || $0 == o.fps }, id: \.self) { Text("\($0)").tag($0) }
            }
            Text("A saída sempre tem taxa de quadros constante (resolve o fps variável do iPhone).")
                .font(.caption).foregroundStyle(Tema.texto2)

            taxa(info)
        }

        if info.temAudio {
            Cartao(titulo: "Áudio do vídeo", icone: "speaker.wave.2") {
                if info.audioAAC && !PlanoConversao.mudaVelocidade(o) {
                    Toggle("Copiar sem recodificar", isOn: ajuste(\.copiarAudio))
                }
                if !(info.audioAAC && o.copiarAudio) || PlanoConversao.mudaVelocidade(o) {
                    Picker("AAC", selection: ajuste(\.audioKbps)) {
                        ForEach([128, 160, 192, 256, 320], id: \.self) { Text("\($0) kb/s").tag($0) }
                    }
                }
            }
        }
    }

    private static let niveis = ["Mínima", "Baixa", "Média", "Boa", "Alta", "Muito alta", "Máxima"]

    @ViewBuilder private func taxa(_ info: InfoMidia) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Tamanho × qualidade").font(.subheadline.weight(.semibold))
            Picker("Modo", selection: ajuste(\.modoTaxa)) {
                Text("Qualidade").tag(OpcoesConversao.ModoTaxa.qualidade)
                Text("Mb/s").tag(OpcoesConversao.ModoTaxa.mbps)
                Text("Tamanho final").tag(OpcoesConversao.ModoTaxa.alvo)
            }
            .pickerStyle(.segmented)
            switch o.modoTaxa {
            case .qualidade:
                HStack {
                    Text(Self.niveis[min(Self.niveis.count - 1, Int((o.qualidade * Double(Self.niveis.count - 1)).rounded()))])
                    Spacer()
                    Text(String(format: "≈ %.1f Mb/s", PlanoConversao.taxaVideo(info, o) / 1_000_000))
                        .monospacedDigit().foregroundStyle(Tema.texto2)
                }
                Slider(value: ajuste(\.qualidade), in: 0...1)
                Text("Como o CRF: a mesma posição dá a mesma qualidade de imagem em qualquer resolução. Os Mb/s acompanham a resolução e o fps (4K 60 precisa de muito mais que 1080p 30 para ficar igual).")
                    .font(.caption).foregroundStyle(Tema.texto2)
            case .mbps:
                HStack {
                    Text("Taxa do vídeo")
                    Spacer()
                    TextField("Mb/s", value: Binding(get: { o.mbps }, set: { o.mbps = min(150, max(0.3, $0)); selecao = personalizado }),
                              format: .number.precision(.fractionLength(0...1)))
                        .keyboardType(.decimalPad).multilineTextAlignment(.trailing).frame(width: 80)
                    Text("Mb/s")
                }
                Text(String(format: "Referência para este vídeo: qualidade boa ≈ %.1f Mb/s.",
                            PlanoConversao.taxaPorQualidade(info, o, 0.5) / 1_000_000))
                    .font(.caption).foregroundStyle(Tema.texto2)
            case .alvo:
                HStack {
                    Text("Tamanho final")
                    Spacer()
                    TextField("MB", value: Binding(get: { o.alvoMB }, set: { o.alvoMB = max(1, $0); selecao = personalizado }),
                              format: .number.precision(.fractionLength(0...1)))
                        .keyboardType(.decimalPad).multilineTextAlignment(.trailing).frame(width: 90)
                    Text("MB")
                }
                Text("Uma passagem só: o arquivo fica perto do alvo.").font(.caption).foregroundStyle(Tema.texto2)
            }
        }
    }

    // MARK: velocidade

    @ViewBuilder private func velocidade(_ info: InfoMidia) -> some View {
        Cartao(titulo: "Velocidade", icone: "gauge.with.dots.needle.67percent") {
            Picker("Velocidade", selection: ajuste(\.velocidade)) {
                ForEach(Velocidade.opcoes, id: \.self) { v in
                    Text(v == 1 ? "Normal (1×)" : Velocidade.nome(v)).tag(v)
                }
            }
            if PlanoConversao.mudaVelocidade(o) {
                Text("O som acompanha a velocidade sem mudar o tom (voz não fica fina nem grossa). Duração final: \(formatarDuracao(PlanoConversao.duracao(info, o)) ?? "—").")
                    .font(.footnote).foregroundStyle(Tema.texto2)
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
                if info.audioAAC && !PlanoConversao.mudaVelocidade(o) {
                    Toggle("Copiar o AAC sem recodificar", isOn: ajuste(\.copiarAudio))
                }
                if !(info.audioAAC && o.copiarAudio) || PlanoConversao.mudaVelocidade(o) {
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
                Text("Duração do trecho: \(formatarDuracao(max(0, (fim ?? info.duracao) - (inicio ?? 0))) ?? "—")")
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
