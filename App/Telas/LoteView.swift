import SwiftUI

/// Vários áudios/vídeos de uma vez: ajustes do lote (valem para todos), lista dos vídeos
/// (cada um pode ter ajustes próprios, com trecho) e um trabalho só com a galeria no fim.
struct PainelLoteVideos: View {
    @Environment(Estudio.self) private var estudio
    let arquivos: [URL]
    var fechar: () -> Void

    @State private var infos: [URL: InfoMidia] = [:]
    @State private var datas: [URL: Date] = [:]
    @State private var erros: [URL: String] = [:]
    @State private var lote: AjusteConversao?
    @State private var proprios: [URL: AjusteConversao] = [:]
    @State private var editando: Editado?
    @State private var padrao = PadraoNome.ler(.conversao)
    @State private var versaoLote = 0          // recria o painel do lote quando "Aplicar a todos" muda os ajustes

    struct Editado: Identifiable { let id: URL }

    /// Vídeo de referência: o enquadramento do lote é desenhado sobre ele.
    private var referencia: URL { arquivos[0] }
    private var validos: [URL] { arquivos.filter { infos[$0] != nil } }
    private var carregados: Bool { infos.count + erros.count == arquivos.count }

    var body: some View {
        Cartao {
            Label("\(arquivos.count) arquivos", systemImage: "film.stack").font(.headline)
            if carregados {
                let dur = validos.reduce(0.0) { $0 + (infos[$1]?.duracao ?? 0) }
                let tam = validos.reduce(Int64(0)) { $0 + (infos[$1]?.tamanhoBytes ?? 0) }
                Text("\(formatarDuracao(dur) ?? "—") no total · \(ByteCountFormatter.string(fromByteCount: tam, countStyle: .file))")
                    .font(.subheadline).foregroundStyle(Tema.texto2)
            } else {
                HStack { ProgressView(); Text("Lendo os arquivos…").foregroundStyle(Tema.texto2) }
            }
            Text("Os ajustes abaixo valem para todos. Toque num vídeo da lista para ajustar só ele (inclusive o trecho).")
                .font(.footnote).foregroundStyle(Tema.texto2)
        }
        .task { await carregar() }

        PainelConverter(arquivo: referencia, nome: referencia.lastPathComponent, fechar: fechar,
                        modo: .lote, inicial: lote, mudou: { lote = $0 })
            .id(versaoLote)

        Cartao(titulo: "Vídeos", icone: "list.bullet") {
            ForEach(arquivos, id: \.self) { u in linha(u) }
        }

        CartaoNomeSaida(padrao: $padrao, tokens: ["{nome}", "{data}", "{datahora}", "{largura}", "{altura}"],
                        previa: previaNomes,
                        nota: "Vale para todos: {nome} é o nome de cada arquivo. Nomes repetidos ganham (2), (3)…")

        Cartao {
            HStack {
                Label("Tamanho estimado", systemImage: "internaldrive")
                Spacer()
                Text(ByteCountFormatter.string(fromByteCount: tamanhoTotal, countStyle: .file))
                    .monospacedDigit().fontWeight(.semibold)
            }
            if !erros.isEmpty {
                Label("\(erros.count) arquivo(s) não abriram e ficam de fora.", systemImage: "exclamationmark.triangle.fill")
                    .font(.footnote).foregroundStyle(.yellow)
            }
            BotaoPrincipal(titulo: "Converter \(validos.count) \(validos.count == 1 ? "arquivo" : "arquivos")",
                           icone: "arrow.triangle.2.circlepath", desativado: !carregados || validos.isEmpty || lote == nil) {
                converter()
            }
        }
        .sheet(item: $editando) { ed in
            EditorVideoDoLote(url: ed.id, inicial: proprios[ed.id] ?? AjusteConversao(opcoes: doLote(ed.id), selecao: lote?.selecao ?? ""),
                              temProprio: proprios[ed.id] != nil,
                              salvar: { novo in salvarProprio(ed.id, novo) },
                              aplicarATodos: { a in aplicarATodos(de: ed.id, a) })
        }
    }

    // MARK: lista

    @ViewBuilder private func linha(_ u: URL) -> some View {
        Button { if infos[u] != nil { editando = Editado(id: u) } } label: {
            HStack(spacing: 12) {
                MiniaturaVideo(url: u).frame(width: 56, height: 56)
                VStack(alignment: .leading, spacing: 3) {
                    Text(u.lastPathComponent).font(.subheadline).lineLimit(1).truncationMode(.middle)
                    if let e = erros[u] {
                        Text(e).font(.caption).foregroundStyle(.yellow).lineLimit(2)
                    } else if let i = infos[u] {
                        Text(i.resumo).font(.caption).foregroundStyle(Tema.texto2).lineLimit(1)
                    }
                    if let p = proprios[u] {
                        HStack(spacing: 6) {
                            Label("Ajustes próprios", systemImage: "slider.horizontal.3")
                            if p.opcoes.inicio != nil || p.opcoes.fim != nil {
                                Label("Trecho", systemImage: "scissors")
                            }
                        }
                        .font(.caption2.weight(.semibold)).foregroundStyle(Tema.acento)
                    }
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right").font(.caption).foregroundStyle(Tema.texto2)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: ajustes

    private func carregar() async {
        for u in arquivos where infos[u] == nil && erros[u] == nil {
            do {
                infos[u] = try await InfoMidia.ler(u)
                datas[u] = await DataMidia.ler(u)
            } catch {
                erros[u] = "Não abriu: \(error.localizedDescription)"
            }
        }
    }

    /// Ajustes do lote para um vídeo: enquadramento adaptado ao formato dele, sem trecho;
    /// arquivo só de áudio vira "extrair áudio".
    private func doLote(_ u: URL) -> OpcoesConversao {
        var o = lote?.opcoes ?? OpcoesConversao()
        o.inicio = nil; o.fim = nil
        if let e = o.enquadramento, let ri = infos[referencia], let vi = infos[u] {
            o.enquadramento = e.adaptado(de: (Double(ri.largura), Double(ri.altura)),
                                         para: (Double(vi.largura), Double(vi.altura)))
        }
        if let vi = infos[u], !vi.temVideo, o.acao != .audio { o.acao = .audio }
        return o
    }

    private func efetivo(_ u: URL) -> OpcoesConversao { proprios[u]?.opcoes ?? doLote(u) }

    private func salvarProprio(_ u: URL, _ novo: AjusteConversao?) {
        guard let novo else { proprios[u] = nil; return }
        // igual ao lote e sem trecho: não é "próprio"
        if novo.opcoes == doLote(u) { proprios[u] = nil } else { proprios[u] = novo }
    }

    /// Os ajustes deste vídeo passam a ser os do lote. Os trechos de cada vídeo continuam.
    private func aplicarATodos(de u: URL, _ a: AjusteConversao) {
        var o = a.opcoes
        let trechoDeste = (o.inicio, o.fim)
        o.inicio = nil; o.fim = nil
        if let e = o.enquadramento, let vi = infos[u], let ri = infos[referencia] {
            o.enquadramento = e.adaptado(de: (Double(vi.largura), Double(vi.altura)),
                                         para: (Double(ri.largura), Double(ri.altura)))
        }
        lote = AjusteConversao(opcoes: o, selecao: a.selecao)
        var novos: [URL: AjusteConversao] = [:]
        for v in arquivos {
            let trecho = v == u ? trechoDeste : (proprios[v]?.opcoes.inicio, proprios[v]?.opcoes.fim)
            if trecho.0 != nil || trecho.1 != nil {
                var p = doLote(v)
                if v == u { p.enquadramento = a.opcoes.enquadramento }     // o dele, exatamente como ajustado
                (p.inicio, p.fim) = trecho
                novos[v] = AjusteConversao(opcoes: p, selecao: a.selecao)
            }
        }
        proprios = novos
        versaoLote += 1
    }

    private var tamanhoTotal: Int64 {
        validos.reduce(Int64(0)) { t, u in
            guard let i = infos[u] else { return t }
            return t + PlanoConversao.tamanhoEstimado(i, efetivo(u))
        }
    }

    private var previaNomes: [String] {
        validos.prefix(3).compactMap { u -> String? in
            guard let i = infos[u] else { return nil }
            let o = efetivo(u)
            let dims: (Int, Int)? = i.temVideo && o.acao != .audio ? PlanoConversao.dimensoesSaida(i, o) : nil
            let b = PadraoNome.base(u.lastPathComponent, padrao: padrao, data: o.usarDataAtual ? Date() : (datas[u] ?? Date()),
                                    largura: dims?.0, altura: dims?.1)
            return "\(u.lastPathComponent) → \(b).\(extensao(o, u))"
        } + (validos.count > 3 ? ["…"] : [])
    }

    private func extensao(_ o: OpcoesConversao, _ u: URL) -> String {
        switch o.acao {
        case .video: return "mp4"
        case .semRecodificar: return u.pathExtension.lowercased() == "mp4" ? "mp4" : "mov"
        case .audio: return o.formatoAudio.rawValue
        case .gif: return "gif"
        case .webpAnimado: return "webp"
        }
    }

    private func converter() {
        let videos = validos.compactMap { u -> Estudio.VideoDoLote? in
            guard let i = infos[u] else { return nil }
            return Estudio.VideoDoLote(url: u, nome: u.lastPathComponent, info: i, opcoes: efetivo(u), data: datas[u] ?? Date())
        }
        PadraoNome.gravar(padrao, .conversao)
        estudio.converterLote(videos, padrao: padrao)
        // os que não abriram não vão junto: apaga
        erros.keys.forEach { try? FileManager.default.removeItem(at: $0) }
        fechar()
    }
}

/// Ajustes de um vídeo dentro do lote (o mesmo conversor, com o trecho).
struct EditorVideoDoLote: View {
    let url: URL
    let inicial: AjusteConversao
    let temProprio: Bool
    var salvar: (AjusteConversao?) -> Void          // nil = voltar aos ajustes do lote
    var aplicarATodos: (AjusteConversao) -> Void
    @Environment(\.dismiss) private var fechar
    @State private var atual: AjusteConversao?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    PainelConverter(arquivo: url, nome: url.lastPathComponent, fechar: {},
                                    modo: .video, inicial: inicial, mudou: { atual = $0 })
                    Cartao {
                        Button {
                            aplicarATodos(atual ?? inicial); fechar()
                        } label: {
                            Label("Aplicar estes ajustes a todos", systemImage: "square.stack.3d.down.forward")
                                .frame(maxWidth: .infinity).padding(.vertical, 4)
                        }
                        .buttonStyle(.glass)
                        Text("O trecho de cada vídeo não muda.").font(.caption).foregroundStyle(Tema.texto2)
                        if temProprio {
                            Button(role: .destructive) { salvar(nil); fechar() } label: {
                                Label("Voltar aos ajustes do lote", systemImage: "arrow.uturn.backward")
                                    .frame(maxWidth: .infinity).padding(.vertical, 4)
                            }
                            .buttonStyle(.glass)
                        }
                    }
                }
                .padding()
            }
            .telaEscura()
            .navigationTitle(url.lastPathComponent)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancelar") { fechar() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("OK") { salvar(atual ?? inicial); fechar() }
                }
            }
        }
    }
}
