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

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    contaNuvem
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
                    modeloLocalCartao
                    Cartao(titulo: "Sobre", icone: "info.circle") {
                        let v = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
                        Text("Estúdio \(v)").font(.subheadline)
                        Text("Os resultados ficam no app Arquivos, em “No meu iPhone › Estúdio › Resultados”.")
                            .font(.footnote).foregroundStyle(Tema.texto2)
                    }
                }
                .padding(.horizontal)
                .padding(.bottom, 24)
            }
            .telaEscura()
            .navigationTitle("Ajustes")
            .onAppear { espaco = TranscritorLocal.tamanhoEmDisco() }
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
                        Task {
                            await TranscritorLocal.shared.apagarModelos()
                            espaco = TranscritorLocal.tamanhoEmDisco()
                        }
                    }
                    .font(.footnote)
                }
            }
        }
    }
}
