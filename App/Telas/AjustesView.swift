import SwiftUI

struct AjustesView: View {
    @Environment(Estudio.self) private var estudio
    @AppStorage("nuvemPorPadrao") private var nuvemPorPadrao = false
    @AppStorage("idioma") private var idioma = "pt"
    @AppStorage("modeloLocal") private var modeloLocal = TranscritorLocal.modeloPadrao

    @State private var usuario = ""
    @State private var senha = ""
    @State private var entrando = false
    @State private var erroLogin: String?

    @State private var baixando: Double?
    @State private var msgModelo: String?
    @State private var espaco: Int64 = 0
    @AppStorage("vozAcelerador") private var vozAcelerador = "gpu"
    @State private var baixandoVoz: Double?
    @State private var msgVoz: String?
    @State private var espacoVoz: Int64 = 0
    @State private var confirmar: Confirmacao?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    contaNuvem
                    CartaoContaGoogle()
                    CartaoDrive()
                    Cartao(titulo: "Padrões", icone: "slider.horizontal.3") {
                        Toggle(isOn: $nuvemPorPadrao) { Label("Processar na nuvem", systemImage: "cloud.fill") }
                        Text("Vem marcado ao transcrever. Desmarcado, a transcrição roda no iPhone.")
                            .font(.footnote).foregroundStyle(Tema.texto2)
                        Picker("Idioma", selection: $idioma) {
                            Text("Português").tag("pt")
                            Text("Detectar").tag("auto")
                        }
                        .pickerStyle(.segmented)
                    }
                    CartaoPreparar()
                    CartaoOriginais()
                    CartaoArmazenamento()
                    modeloLocalCartao
                    vozCartao
                    Cartao(titulo: "Sobre", icone: "info.circle") {
                        let v = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
                        Text("Estúdio \(v)").font(.subheadline)
                        Text("FFmpeg \(String(cString: estudio_ffmpeg_versao())) · VP9 \(estudio_ffmpeg_decodifica("vp9") == 1 ? "sim" : "não") · AV1 \(estudio_ffmpeg_decodifica("av1") == 1 ? "sim" : "não")")
                            .font(.footnote).foregroundStyle(Tema.texto2)
                        Text("Os resultados ficam no app Arquivos, em “No meu iPhone › Estúdio › Resultados”.")
                            .font(.footnote).foregroundStyle(Tema.texto2)
                    }
                }
                .padding(.horizontal)
                .padding(.bottom, 24)
            }
            .telaEscura()
            .navigationTitle("Ajustes")
            .confirmar($confirmar)
            .onAppear { espaco = TranscritorLocal.tamanhoEmDisco(); espacoVoz = ModelosVoz.tamanhoEmDisco() + ModelosCoreML.tamanhoEmDisco() }
        }
    }

    // MARK: conta

    @ViewBuilder private var contaNuvem: some View {
        Cartao(titulo: "Nuvem", icone: "cloud.fill") {
            if estudio.logado, let u = estudio.nuvem.usuario {
                Label("Conectado como \(u)", systemImage: "checkmark.seal.fill").foregroundStyle(.green)
                Button("Sair", role: .destructive) {
                    Task { await estudio.nuvem.sair(); estudio.logado = false }
                }
                .buttonStyle(.glass)
            } else {
                Text("Use o mesmo usuário do site de transcrição.").font(.footnote).foregroundStyle(Tema.texto2)
                TextField("Usuário", text: $usuario)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                    .textContentType(.username)
                    .padding(12).background(.white.opacity(0.06), in: .rect(cornerRadius: 14))
                SecureField("Senha", text: $senha)
                    .textContentType(.password)
                    .padding(12).background(.white.opacity(0.06), in: .rect(cornerRadius: 14))
                if let erroLogin { Text(erroLogin).font(.footnote).foregroundStyle(.yellow) }
                BotaoPrincipal(titulo: entrando ? "Entrando…" : "Entrar", icone: "person.crop.circle.badge.checkmark",
                               desativado: entrando || usuario.isEmpty || senha.isEmpty) {
                    entrando = true; erroLogin = nil
                    Task {
                        do {
                            try await estudio.nuvem.entrar(usuario: usuario.trimmingCharacters(in: .whitespaces), senha: senha)
                            estudio.logado = true; senha = ""
                        } catch {
                            erroLogin = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                        }
                        entrando = false
                    }
                }
            }
        }
    }

    // MARK: modelo local

    @ViewBuilder private var modeloLocalCartao: some View {
        Cartao(titulo: "Transcrição no iPhone", icone: "iphone") {
            Picker("Modelo", selection: $modeloLocal) {
                ForEach(TranscritorLocal.modelos) { m in Text("\(m.nome) · \(m.tamanho)").tag(m.id) }
            }
            .pickerStyle(.menu)
            let pronto = TranscritorLocal.pastaDoModelo(modeloLocal) != nil
            Label(pronto ? "Modelo baixado" : "Modelo ainda não baixado",
                  systemImage: pronto ? "checkmark.circle.fill" : "arrow.down.circle")
                .foregroundStyle(pronto ? .green : Tema.texto2)
            if let baixando {
                ProgressView(value: baixando).tint(Tema.acento)
            }
            if let msgModelo { Text(msgModelo).font(.footnote).foregroundStyle(Tema.texto2) }
            if !pronto {
                BotaoPrincipal(titulo: "Baixar agora", icone: "arrow.down.circle.fill", desativado: baixando != nil) {
                    baixando = 0; msgModelo = nil
                    let id = modeloLocal
                    Task {
                        do {
                            _ = try await TranscritorLocal.shared.baixar(id) { p in
                                Task { @MainActor in if baixando != nil { baixando = p } }
                            }
                            msgModelo = "Pronto. A primeira transcrição ainda prepara o modelo no Neural Engine (alguns minutos, uma vez só)."
                        } catch {
                            msgModelo = "Falhou: \(error.localizedDescription)"
                        }
                        baixando = nil
                        espaco = TranscritorLocal.tamanhoEmDisco()
                    }
                }
            }
            HStack {
                Text("Espaço usado: \(ByteCountFormatter.string(fromByteCount: espaco, countStyle: .file))")
                    .font(.footnote).foregroundStyle(Tema.texto2)
                Spacer()
                if espaco > 0 {
                    Button("Apagar modelos", role: .destructive) {
                        confirmar = Confirmacao(titulo: "Apagar os modelos de transcrição?",
                                                mensagem: "Será preciso baixar e preparar de novo na próxima transcrição.") {
                            Task {
                                await TranscritorLocal.shared.apagarModelos()
                                espaco = TranscritorLocal.tamanhoEmDisco()
                            }
                        }
                    }
                    .font(.footnote)
                }
            }
        }
    }

    // MARK: voz no iPhone

    @ViewBuilder private var vozCartao: some View {
        Cartao(titulo: "Tratar voz no iPhone", icone: "waveform") {
            let pronto = espacoVoz > 0 && ModelosVoz.prontos
            Label(pronto ? "Modelos de voz baixados" : "Modelos de voz ainda não baixados (290 MB + 290 MB da GPU)",
                  systemImage: pronto ? "checkmark.circle.fill" : "arrow.down.circle")
                .foregroundStyle(pronto ? .green : Tema.texto2)
            if let baixandoVoz { ProgressView(value: baixandoVoz).tint(Tema.acento) }
            if let msgVoz { Text(msgVoz).font(.footnote).foregroundStyle(Tema.texto2) }
            if !pronto {
                BotaoPrincipal(titulo: "Baixar agora", icone: "arrow.down.circle.fill", desativado: baixandoVoz != nil) {
                    baixandoVoz = 0; msgVoz = nil
                    Task {
                        do {
                            try await ModelosVoz.baixar { p in Task { @MainActor in if baixandoVoz != nil { baixandoVoz = p } } }
                            msgVoz = "Pronto."
                        } catch {
                            msgVoz = "Falhou: \((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)"
                        }
                        baixandoVoz = nil
                        espacoVoz = ModelosVoz.tamanhoEmDisco()
                    }
                }
            }
            Picker("Onde rodar os modelos", selection: Binding(get: { vozAcelerador == "cpu" ? "cpu" : "gpu" },
                                                                set: { vozAcelerador = $0 })) {
                Text("GPU (Core ML)").tag("gpu")
                Text("Processador").tag("cpu")
            }
            .pickerStyle(.menu)
            Text(vozAcelerador == "cpu"
                 ? "Processador: o caminho mais lento (cerca de 3× a duração do áudio)."
                 : "GPU: bem mais rápido, com os mesmos cálculos em precisão total. Na 1ª vez baixa mais 290 MB e prepara os modelos. Em cada tratamento o 1º trecho é conferido com o processador; se não bater, volta para o processador sozinho.")
                .font(.footnote).foregroundStyle(Tema.texto2)
            if let diag = try? String(contentsOf: Diagnostico.arquivo, encoding: .utf8), !diag.isEmpty {
                DisclosureGroup("Diagnóstico do último tratamento") {
                    Text(diag).font(.caption2.monospaced()).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    HStack {
                        Button("Copiar", systemImage: "doc.on.doc") { UIPasteboard.general.string = diag }
                        Spacer()
                        ShareLink(item: Diagnostico.arquivo) { Label("Compartilhar", systemImage: "square.and.arrow.up") }
                    }
                    .font(.footnote)
                }
                .font(.footnote)
            }
            if espacoVoz > 0 {
                HStack {
                    Text("Espaço usado: \(ByteCountFormatter.string(fromByteCount: espacoVoz, countStyle: .file))")
                        .font(.footnote).foregroundStyle(Tema.texto2)
                    Spacer()
                    Button("Apagar modelos", role: .destructive) {
                        confirmar = Confirmacao(titulo: "Apagar os modelos de voz?",
                                                mensagem: "Será preciso baixar e preparar de novo no próximo tratamento de voz.") {
                            ModelosVoz.apagar(); ModelosCoreML.apagar(); espacoVoz = ModelosVoz.tamanhoEmDisco()
                        }
                    }
                    .font(.footnote)
                }
            }
        }
    }
}


/// Baixa e compila de antemão o que o iPhone usa, para o 1º trabalho não esperar minutos.
struct CartaoPreparar: View {
    @Environment(Estudio.self) private var estudio
    @State private var prep = Preparacao.shared

    var body: some View {
        Cartao(titulo: "Deixar o app pronto", icone: "bolt.badge.checkmark") {
            Text("Baixa e compila agora o que o app usa no iPhone, para o primeiro trabalho começar na hora. Depois de instalar uma versão nova do app (ou atualizar o iOS), as compilações precisam ser refeitas.")
                .font(.footnote).foregroundStyle(Tema.texto2)
            ForEach(Preparacao.Parte.allCases) { p in linha(p) }
            BotaoPrincipal(titulo: prep.ocupado ? "Preparando…" : prep.tudoPronto ? "Tudo pronto" : "Preparar tudo",
                           icone: prep.tudoPronto ? "checkmark.circle.fill" : "bolt.fill",
                           desativado: prep.ocupado || prep.tudoPronto || estudio.processandoLocal) {
                prep.preparar(Preparacao.Parte.allCases)
            }
            if estudio.processandoLocal && !prep.tudoPronto {
                Text("Espere o trabalho atual terminar.").font(.footnote).foregroundStyle(Tema.texto2)
            } else if prep.ocupado {
                Text("Mantenha o app aberto até terminar. De preferência no Wi-Fi.").font(.footnote).foregroundStyle(.yellow)
            }
        }
    }

    @ViewBuilder private func linha(_ p: Preparacao.Parte) -> some View {
        let pronto = prep.pronto(p)
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: pronto ? "checkmark.circle.fill" : "circle.dashed")
                    .foregroundStyle(pronto ? .green : Tema.texto2)
                    .font(.title3)
                VStack(alignment: .leading, spacing: 2) {
                    Text(prep.titulo(p)).font(.subheadline.weight(.semibold))
                    Text(textoEstado(p)).font(.caption).foregroundStyle(pronto ? .green : Tema.texto2)
                }
                Spacer(minLength: 8)
                if !pronto && prep.andamento[p] == nil {
                    Button("Preparar") { prep.preparar([p]) }
                        .buttonStyle(.glass)
                        .font(.footnote)
                        .disabled(prep.ocupado || estudio.processandoLocal)
                }
            }
            if let a = prep.andamento[p] {
                if let f = a.fracao { ProgressView(value: f).tint(Tema.acento) }
                else { ProgressView().progressViewStyle(.linear).tint(Tema.acento) }
                Text(a.mensagem).font(.caption).foregroundStyle(Tema.texto2)
            }
            if let e = prep.erro[p] {
                Label(e, systemImage: "exclamationmark.triangle.fill").font(.caption).foregroundStyle(.yellow)
            }
        }
        .padding(12)
        .background(.white.opacity(0.05), in: .rect(cornerRadius: 14))
    }

    private func textoEstado(_ p: Preparacao.Parte) -> String {
        switch prep.estado(p) {
        case .pronto: return "Pronto"
        case .falta(let m): return m + " · " + prep.detalhe(p)
        }
    }
}


/// Chave de API do Google Drive (links públicos). Fica no Keychain do iPhone.
struct CartaoDrive: View {
    @State private var temChave = Drive.chave != nil
    @State private var nova = ""
    @State private var msg: String?
    @State private var testando = false
    @State private var confirmar: Confirmacao?

    var body: some View {
        Cartao(titulo: "Drive: chave de API", icone: "key.fill") {
            if temChave {
                Label("Chave de API guardada no iPhone", systemImage: "checkmark.seal.fill").foregroundStyle(.green)
                Text("Links públicos do Drive (\u{201C}qualquer pessoa com o link\u{201D}) abrem no app, com as pastas.")
                    .font(.footnote).foregroundStyle(Tema.texto2)
                HStack {
                    Button { testar() } label: { Label(testando ? "Testando…" : "Testar", systemImage: "checkmark.circle") }
                        .buttonStyle(.glass).disabled(testando)
                    Spacer()
                    Button("Apagar chave", role: .destructive) {
                        confirmar = Confirmacao(titulo: "Apagar a chave de API do Drive?",
                                                mensagem: "Links públicos só voltam a abrir sem login depois de colar a chave de novo.") {
                            Drive.apagarChave(); temChave = false; msg = nil
                        }
                    }
                    .buttonStyle(.glass)
                }
            } else {
                Text("Cole a chave de API criada no Google Cloud (só com a Google Drive API liberada). Ela fica no Keychain do iPhone.")
                    .font(.footnote).foregroundStyle(Tema.texto2)
                SecureField("Chave de API (AIza…)", text: $nova)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                    .padding(12).background(.white.opacity(0.06), in: .rect(cornerRadius: 14))
                HStack {
                    Button("Colar", systemImage: "doc.on.clipboard") {
                        if let s = UIPasteboard.general.string { nova = s.trimmingCharacters(in: .whitespacesAndNewlines) }
                    }
                    .buttonStyle(.glass)
                    Spacer()
                    Button("Salvar", systemImage: "key.fill") {
                        Drive.salvarChave(nova); nova = ""
                        temChave = Drive.chave != nil
                        if temChave { testar() } else { msg = "Não consegui guardar a chave." }
                    }
                    .buttonStyle(.glassProminent).tint(Tema.acento)
                    .disabled(nova.trimmingCharacters(in: .whitespaces).count < 20)
                }
            }
            if let msg { Text(msg).font(.footnote).foregroundStyle(Tema.texto2) }
        }
        .confirmar($confirmar)
    }

    private func testar() {
        testando = true; msg = nil
        Task {
            do { try await Drive.testarChave(); msg = "A chave funciona." }
            catch { msg = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription }
            testando = false
        }
    }
}


/// Login na conta Google: abre o que foi compartilhado com você, Meu Drive e drives compartilhados.
struct CartaoContaGoogle: View {
    @State private var logado = ContaGoogle.logado
    @State private var email = ContaGoogle.email
    @State private var cliente = ContaGoogle.clienteId ?? ""
    @State private var editandoCliente = ContaGoogle.clienteId == nil
    @State private var entrando = false
    @State private var msg: String?

    var body: some View {
        Cartao(titulo: "Conta Google (Drive)", icone: "person.crop.circle.badge.checkmark") {
            if logado {
                Label("Conectado como \(email ?? "sua conta")", systemImage: "checkmark.seal.fill").foregroundStyle(.green)
                Text("Abre links compartilhados com você, Meu Drive e drives compartilhados (só leitura).")
                    .font(.footnote).foregroundStyle(Tema.texto2)
                Button("Sair da conta Google", role: .destructive) {
                    Task { await ContaGoogle.sair(); logado = false; email = nil }
                }
                .buttonStyle(.glass)
            } else {
                Text("Para ver o que foi compartilhado só com você. A senha é digitada na tela do Google, nunca no app.")
                    .font(.footnote).foregroundStyle(Tema.texto2)
                if editandoCliente {
                    TextField("ID do cliente (…apps.googleusercontent.com)", text: $cliente)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                        .font(.footnote.monospaced())
                        .padding(12).background(.white.opacity(0.06), in: .rect(cornerRadius: 14))
                    Button("Colar", systemImage: "doc.on.clipboard") {
                        if let s = UIPasteboard.general.string { cliente = s.trimmingCharacters(in: .whitespacesAndNewlines) }
                    }
                    .buttonStyle(.glass)
                } else {
                    HStack {
                        Label("ID do cliente salvo", systemImage: "checkmark.circle").font(.footnote).foregroundStyle(Tema.texto2)
                        Spacer()
                        Button("Trocar") { editandoCliente = true }.buttonStyle(.glass)
                    }
                }
                BotaoPrincipal(titulo: entrando ? "Abrindo o Google…" : "Entrar com o Google", icone: "person.badge.key.fill",
                               desativado: entrando || cliente.trimmingCharacters(in: .whitespaces).isEmpty) {
                    entrar()
                }
            }
            if let msg { Text(msg).font(.footnote).foregroundStyle(.yellow) }
        }
    }

    private func entrar() {
        let c = cliente.trimmingCharacters(in: .whitespacesAndNewlines)
        guard ContaGoogle.esquema(c) != nil else {
            msg = "O ID do cliente deve terminar em .apps.googleusercontent.com (cliente do tipo iOS)."
            return
        }
        ContaGoogle.salvarCliente(c)
        editandoCliente = false
        entrando = true; msg = nil
        Task {
            do {
                try await ContaGoogle.entrar()
                logado = ContaGoogle.logado
                email = ContaGoogle.email
            } catch {
                msg = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
            entrando = false
        }
    }
}


/// Cópias guardadas dos vídeos que chegaram pelo Compartilhar (os outros são buscados de novo
/// na galeria, no app Arquivos ou em Resultados).
struct CartaoOriginais: View {
    @Environment(Estudio.self) private var estudio
    @AppStorage("originaisDias") private var dias = 7
    @State private var espaco: Int64 = 0
    @State private var confirmar: Confirmacao?

    var body: some View {
        Cartao(titulo: "Editar novamente", icone: "slider.horizontal.3") {
            Text("Para editar de novo, o app busca o original na galeria, no app Arquivos ou em Resultados. Só o que chega pelo Compartilhar precisa de uma cópia guardada, porque o iPhone não entrega o original.")
                .font(.footnote).foregroundStyle(Tema.texto2)
            Picker("Manter essas cópias por", selection: $dias) {
                Text("7 dias").tag(7)
                Text("30 dias").tag(30)
                Text("Indefinido").tag(-1)
            }
            HStack {
                Text("Em uso: \(ByteCountFormatter.string(fromByteCount: espaco, countStyle: .file))").font(.subheadline)
                Spacer()
                Menu {
                    Button("Manter os últimos 7 dias") {
                        confirmar = Confirmacao(titulo: "Apagar as cópias com mais de 7 dias?") { apagar(7) }
                    }
                    Button("Manter os últimos 30 dias") {
                        confirmar = Confirmacao(titulo: "Apagar as cópias com mais de 30 dias?") { apagar(30) }
                    }
                    Button("Apagar tudo", role: .destructive) {
                        confirmar = Confirmacao(titulo: "Apagar todas as cópias guardadas?",
                                                mensagem: "O que veio pelo Compartilhar não poderá mais ser editado de novo.") { apagar(nil) }
                    }
                } label: {
                    Label("Apagar", systemImage: "trash").padding(.horizontal, 12).padding(.vertical, 7)
                        .background(.white.opacity(0.08), in: .capsule)
                }
            }
            Text("Conta também o vídeo que o editor de legenda deixa à mão. Apagar tira só os vídeos: o texto e o estilo das legendas ficam, e o vídeo volta sozinho quando há de onde buscar.")
                .font(.caption).foregroundStyle(Tema.texto2)
        }
        .onAppear { estudio.limparOriginaisAntigos(); espaco = Originais.tamanhoEmDisco() }
        .onChange(of: dias) { estudio.limparOriginaisAntigos(); espaco = Originais.tamanhoEmDisco() }
        .confirmar($confirmar)
    }

    private func apagar(_ manter: Int?) {
        estudio.limparOriginais(manterDias: manter)
        espaco = Originais.tamanhoEmDisco()
    }
}

/// Os arquivos prontos (Resultados): quanto ocupam, limpeza por idade e os maiores, um a um.
struct CartaoArmazenamento: View {
    @Environment(Estudio.self) private var estudio
    @State private var arquivos: [ArquivoGuardado] = []
    @State private var confirmar: Confirmacao?

    private var espaco: Int64 { arquivos.reduce(Int64(0)) { $0 + $1.bytes } }

    var body: some View {
        Cartao(titulo: "Armazenamento", icone: "internaldrive") {
            Text("Os vídeos, áudios, imagens e textos prontos que estão em Resultados.")
                .font(.footnote).foregroundStyle(Tema.texto2)
            HStack {
                Text("Em uso: \(ByteCountFormatter.string(fromByteCount: espaco, countStyle: .file))").font(.subheadline)
                Spacer()
                Menu {
                    Button("Manter os últimos 7 dias") {
                        confirmar = Confirmacao(titulo: "Apagar os resultados com mais de 7 dias?",
                                                mensagem: "Eles saem de Resultados, com todos os arquivos. Isso não pode ser desfeito.") { limpar(7) }
                    }
                    Button("Manter os últimos 30 dias") {
                        confirmar = Confirmacao(titulo: "Apagar os resultados com mais de 30 dias?",
                                                mensagem: "Eles saem de Resultados, com todos os arquivos. Isso não pode ser desfeito.") { limpar(30) }
                    }
                    Button("Apagar tudo", role: .destructive) {
                        confirmar = Confirmacao(titulo: "Apagar todos os resultados?",
                                                mensagem: "A aba Resultados fica vazia: vídeos, legendas e transcrições saem do app. Isso não pode ser desfeito.") { limpar(nil) }
                    }
                } label: {
                    Label("Apagar", systemImage: "trash").padding(.horizontal, 12).padding(.vertical, 7)
                        .background(.white.opacity(0.08), in: .capsule)
                }
            }
            if !arquivos.isEmpty {
                Text("Maiores arquivos").font(.subheadline.weight(.semibold)).padding(.top, 4)
                ForEach(Array(arquivos.prefix(15))) { a in
                    Deslizavel(apagar: {
                        confirmar = Confirmacao(titulo: "Apagar “\(a.nome)”?",
                                                mensagem: "O arquivo sai do app. Isso não pode ser desfeito.") {
                            estudio.apagarArquivoGuardado(a)
                            withAnimation(.snappy) { atualizar() }
                        }
                    }, tocar: {}) {
                        HStack(spacing: 10) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(a.nome).font(.subheadline).lineLimit(1).truncationMode(.middle)
                                Text("\(a.titulo) · \(a.criado.formatted(.dateTime.day().month()))")
                                    .font(.caption).foregroundStyle(Tema.texto2).lineLimit(1)
                            }
                            Spacer(minLength: 0)
                            Text(ByteCountFormatter.string(fromByteCount: a.bytes, countStyle: .file))
                                .font(.subheadline.monospacedDigit())
                        }
                        .padding(.vertical, 8).padding(.horizontal, 10)
                        .background(.white.opacity(0.06), in: .rect(cornerRadius: 12))
                    }
                }
                Text("Deslize um arquivo para a esquerda para apagar só ele.")
                    .font(.caption).foregroundStyle(Tema.texto2)
            }
        }
        .onAppear { atualizar() }
        .confirmar($confirmar)
    }

    private func atualizar() { arquivos = estudio.arquivosGuardados() }

    private func limpar(_ manter: Int?) {
        estudio.limparResultados(manterDias: manter)
        atualizar()
    }
}
