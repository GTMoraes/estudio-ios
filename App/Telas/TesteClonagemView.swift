import SwiftUI
import UIKit
import AVFoundation
import UniformTypeIdentifiers

/// Ajustes › "Teste: clonagem de voz". Gera fala com a sua voz no próprio iPhone (Chatterbox v3),
/// mede tempo e memória e grava em "No meu iPhone › Estúdio › Clonagem-testes".
struct CartaoTesteClonagem: View {
    var body: some View {
        Cartao(titulo: "Teste: clonagem de voz", icone: "person.wave.2") {
            Text("Experimental. Gera fala com a sua voz no iPhone, sem internet, e mede tempo e memória para comparar com o GT-PC.")
                .font(.footnote).foregroundStyle(Tema.texto2)
            NavigationLink { TesteClonagemView() } label: {
                Label("Abrir o teste", systemImage: "flask").frame(maxWidth: .infinity).padding(.vertical, 6)
            }
            .buttonStyle(.glass)
        }
    }
}

@MainActor @Observable
final class TesteClonagem {
    struct Item: Identifiable {
        let id = UUID()
        var titulo: String
        var arquivo: URL
        var linhas: [String]
    }

    var etapa = ""
    var rodando = false
    var erro: String?
    var picoMemoria: UInt64 = 0
    var resultados: [Item] = []
    var conferencia: [String] = []
    private var motor: MotorChatterbox?
    private var ondeMotor: CrisperModelo.Onde?
    private var tarefa: Task<Void, Never>?

    static var raiz: URL { FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0] }

    func cancelar() { tarefa?.cancel() }
    func liberar() { motor = nil; ondeMotor = nil }

    private func pegarMotor(_ onde: CrisperModelo.Onde) async throws -> MotorChatterbox {
        if let m = motor, ondeMotor == onde { return m }
        motor = nil
        etapa = ModeloChatterbox.temCompilado ? "Carregando o modelo"
            : "Preparando o modelo para este iPhone (só na primeira vez, pode levar alguns minutos)"
        let carga = Task.detached(priority: .userInitiated) { () async throws -> MotorChatterbox in
            let u = try await ModeloChatterbox.compilarSePreciso()
            return try MotorChatterbox(onde: onde, compilado: u)
        }
        let m = try await withTaskCancellationHandler { try await carga.value } onCancel: { carga.cancel() }
        motor = m; ondeMotor = onde
        let (iguais, total, dif) = m.conferirTokenizador()
        conferencia = ["Tokenizador: \(iguais) de \(total) frases iguais ao original" + (dif.map { ". Diferença em \($0)" } ?? "")]
        return m
    }

    private func comecar(_ trabalho: @escaping () async throws -> Void) {
        guard !rodando else { return }
        rodando = true; erro = nil; picoMemoria = Memoria.agora()
        UIApplication.shared.isIdleTimerDisabled = true
        let medidor = Task { [weak self] in
            while !Task.isCancelled {
                let m = Memoria.agora()
                await MainActor.run { if let s = self, m > s.picoMemoria { s.picoMemoria = m } }
                try? await Task.sleep(for: .milliseconds(250))
            }
        }
        tarefa = Task {
            defer { medidor.cancel(); rodando = false; UIApplication.shared.isIdleTimerDisabled = false }
            do {
                try await trabalho()
            } catch is CancellationError {
                etapa = "Cancelado"
            } catch {
                erro = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                etapa = ""
            }
        }
    }

    func gerar(texto: String, voz vozURL: URL, ajustes: MotorChatterbox.Ajustes, versoes: Int, onde: CrisperModelo.Onde) {
        comecar { [weak self] in
            guard let self else { return }
            let voz = try VozChatterbox.ler(vozURL)
            let motor = try await self.pegarMotor(onde)
            let fmt = DateFormatter(); fmt.dateFormat = "yyyy-MM-dd HH.mm.ss"
            let pasta = Self.raiz.appendingPathComponent("Clonagem-testes", isDirectory: true)
                .appendingPathComponent(fmt.string(from: Date()), isDirectory: true)
            try FileManager.default.createDirectory(at: pasta, withIntermediateDirectories: true)
            var relatorio = ["Estúdio \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?") · \(onde.rawValue) · modelo \(motor.config.modelo ?? "?") · voz \(vozURL.lastPathComponent)",
                             String(format: "cfg %.2f · exageração %.2f · temperatura %.2f", ajustes.cfg, ajustes.exageracao, ajustes.temperatura),
                             "Texto: \(texto)", ""]
            for v in 0..<versoes {
                var a = ajustes
                a.semente = (ajustes.semente ?? 1) + UInt64(v)
                self.etapa = "Versão \(v + 1) de \(versoes): começando"
                let trabalho = Task.detached(priority: .userInitiated) { [weak self, a] in
                    try motor.gerar(texto, voz: voz, ajustes: a) { msg in
                        Task { @MainActor in self?.etapa = "Versão \(v + 1) de \(versoes): " + msg }
                    }
                }
                let r = try await withTaskCancellationHandler { try await trabalho.value } onCancel: { trabalho.cancel() }
                let arq = pasta.appendingPathComponent("versao-\(v + 1)-semente-\(a.semente ?? 0).wav")
                try GravarWav.gravar(r.audio, taxa: 24000, em: arq)
                let total = r.segundosT3 + r.segundosDecodificador
                let linhas = [
                    String(format: "Áudio: %.1f s · %ld tokens%@", r.duracao, r.tokens.count, r.trechos > 1 ? " · \(r.trechos) trechos" : ""),
                    String(format: "T3: %.1f s (%.1f tokens/s) · decodificador: %.1f s", r.segundosT3,
                           Double(r.tokens.count) / max(r.segundosT3, 0.01), r.segundosDecodificador),
                    String(format: "Total: %.1f s = %.2f× a duração do áudio", total, total / max(r.duracao, 0.01)),
                ] + (r.cortadoPorLimite ? ["Parou no limite de tokens (a fala pode ter disparado)."] : [])
                self.resultados.insert(Item(titulo: "Versão \(v + 1) · semente \(a.semente ?? 0)", arquivo: arq, linhas: linhas), at: 0)
                relatorio += ["Versão \(v + 1), semente \(a.semente ?? 0)"] + linhas + [""]
            }
            relatorio.append("Memória de pico do app: \(ByteCountFormatter.string(fromByteCount: Int64(self.picoMemoria), countStyle: .memory))")
            try relatorio.joined(separator: "\n").write(to: pasta.appendingPathComponent("relatorio.txt"), atomically: true, encoding: .utf8)
            self.etapa = "Pronto. Salvo em Clonagem-testes › \(pasta.lastPathComponent)"
        }
    }

    /// Escolhe sempre o token mais provável e compara com o que o PyTorch escolheu no GT-PC.
    func conferir(voz vozURL: URL, onde: CrisperModelo.Onde) {
        comecar { [weak self] in
            guard let self else { return }
            let voz = try VozChatterbox.ler(vozURL)
            guard let c = voz.conferencia else { throw ErroApp("Esta voz não tem dados de conferência.") }
            let motor = try await self.pegarMotor(onde)
            self.etapa = "Conferindo o T3"
            var a = MotorChatterbox.Ajustes()
            a.cfg = c.cfg; a.exageracao = c.exageracao; a.semente = nil; a.maxTokens = c.tokens_gulosos.count
            let trabalho = Task.detached(priority: .userInitiated) { [a] in
                try motor.gerar(c.texto, voz: voz, ajustes: a) { _ in }
            }
            let r = try await withTaskCancellationHandler { try await trabalho.value } onCancel: { trabalho.cancel() }
            let iguais = zip(r.tokens, c.tokens_gulosos).prefix { $0 == $1 }.count
            let dif = zip(r.primeirosLogits, c.logits_inicio).map { abs($0 - $1) }.max() ?? 0
            let arq = Self.raiz.appendingPathComponent("Clonagem-testes", isDirectory: true)
            try FileManager.default.createDirectory(at: arq, withIntermediateDirectories: true)
            let wav = arq.appendingPathComponent("conferencia.wav")
            try GravarWav.gravar(r.audio, taxa: 24000, em: wav)
            self.conferencia = [self.conferencia.first ?? "",
                                "T3: os primeiros \(iguais) de \(c.tokens_gulosos.count) tokens iguais ao PyTorch",
                                String(format: "Diferença máxima nos primeiros logits: %.3f", dif),
                                String(format: "T3 %.1f s (%.1f tokens/s), decodificador %.1f s",
                                       r.segundosT3, Double(r.tokens.count) / max(r.segundosT3, 0.01), r.segundosDecodificador)]
            self.resultados.insert(Item(titulo: "Conferência (mais provável)", arquivo: wav, linhas: []), at: 0)
            self.etapa = "Conferência pronta"
        }
    }
}

enum GravarWav {
    static func gravar(_ x: [Float], taxa: Int, em u: URL) throws {
        var d = Data()
        func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        let n = UInt32(x.count * 2)
        d.append(contentsOf: Array("RIFF".utf8)); u32(36 + n); d.append(contentsOf: Array("WAVE".utf8))
        d.append(contentsOf: Array("fmt ".utf8)); u32(16); u16(1); u16(1); u32(UInt32(taxa)); u32(UInt32(taxa * 2)); u16(2); u16(16)
        d.append(contentsOf: Array("data".utf8)); u32(n)
        var pcm = [Int16](repeating: 0, count: x.count)
        for i in x.indices { pcm[i] = Int16(max(-1, min(1, x[i])) * 32767) }
        pcm.withUnsafeBytes { d.append(contentsOf: $0) }
        try d.write(to: u)
    }
}

struct TesteClonagemView: View {
    @State private var teste = TesteClonagem()
    @State private var pronto = ModeloChatterbox.pronto
    @State private var vozes: [URL] = VozChatterbox.disponiveis()
    @State private var voz: URL?
    @State private var texto = TesteClonagemView.frases[1].1
    @State private var cfg: Float = 0.5
    @State private var exageracao: Float = 0.3
    @State private var temperatura: Float = 0.8
    @State private var versoes = 2
    @State private var semente = 1
    @State private var onde: CrisperModelo.Onde = .gpu
    @State private var importando = false
    @State private var confirmar: Confirmacao?
    @State private var tocador: AVAudioPlayer?
    @State private var tocando: URL?

    static let frases: [(String, String)] = [
        ("Frase 1", "Fala, pessoal! Hoje eu vou mostrar uma coisa que mudou completamente o meu jeito de editar vídeo."),
        ("Frase 5", "Quando eu comecei, gastava horas em cada detalhe e mesmo assim o resultado não ficava do jeito que eu queria. Com o tempo, entendi que o segredo era simplificar: menos ferramentas, mais atenção ao que importa pra quem assiste."),
        ("Nova 1", "Olha, eu vou ser bem sincero com você: esse resultado me surpreendeu bastante."),
        ("Nova 2", "Se você chegou até aqui, deixa nos comentários o que achou e compartilha com quem precisa ver isso."),
    ]

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                cartaoModelo
                cartaoVoz
                cartaoTexto
                cartaoAjustes
                cartaoAcoes
                if !teste.conferencia.isEmpty {
                    Cartao(titulo: "Conferência", icone: "checkmark.seal") {
                        ForEach(teste.conferencia, id: \.self) { Text($0).font(.footnote) }
                    }
                }
                ForEach(teste.resultados) { item in
                    Cartao(titulo: item.titulo, icone: "waveform") {
                        ForEach(item.linhas, id: \.self) { Text($0).font(.footnote).foregroundStyle(Tema.texto2) }
                        Button { tocar(item.arquivo) } label: {
                            Label(tocando == item.arquivo ? "Parar" : "Ouvir",
                                  systemImage: tocando == item.arquivo ? "stop.fill" : "play.fill")
                                .frame(maxWidth: .infinity).padding(.vertical, 4)
                        }
                        .buttonStyle(.glass)
                    }
                }
            }
            .padding(16)
        }
        .telaEscura()
        .navigationTitle("Clonagem de voz")
        .confirmar($confirmar)
        .fileImporter(isPresented: $importando, allowedContentTypes: [.json]) { r in importar(r) }
        .onAppear { atualizar() }
        .onDisappear { tocador?.stop(); teste.cancelar(); teste.liberar() }
    }

    private var cartaoModelo: some View {
        Cartao(titulo: "Modelo", icone: "cpu") {
            Label(pronto ? "Chatterbox pronto" : "Chatterbox ainda não está no iPhone (1,6 GB)",
                  systemImage: pronto ? "checkmark.circle.fill" : "arrow.down.circle")
                .foregroundStyle(pronto ? .green : Tema.texto2)
            Text("Baixar, preparar e apagar ficam em Ajustes › Deixar o app pronto.")
                .font(.footnote).foregroundStyle(Tema.texto2)
        }
    }

    private var cartaoVoz: some View {
        Cartao(titulo: "Voz", icone: "person.wave.2") {
            if vozes.isEmpty {
                Text("Nenhuma voz. Importe o voz-gabriel.json que o rodar-iphone.sh gravou na pasta iphone do GT-PC.")
                    .font(.footnote).foregroundStyle(Tema.texto2)
            } else {
                Picker("Voz", selection: $voz) {
                    ForEach(vozes, id: \.self) { Text($0.deletingPathExtension().lastPathComponent).tag(Optional($0)) }
                }
            }
            HStack {
                Button("Importar voz") { importando = true }.buttonStyle(.glass)
                Spacer()
                if let v = voz {
                    Button("Apagar voz", role: .destructive) {
                        confirmar = Confirmacao(titulo: "Tem certeza?", mensagem: "Apaga \(v.lastPathComponent) do iPhone.") {
                            try? FileManager.default.removeItem(at: v); atualizar()
                        }
                    }
                }
            }
            .font(.footnote)
        }
    }

    private var cartaoTexto: some View {
        Cartao(titulo: "Texto", icone: "text.alignleft") {
            TextEditor(text: $texto)
                .frame(minHeight: 120)
                .scrollContentBackground(.hidden)
                .padding(8)
                .background(Color.white.opacity(0.06), in: .rect(cornerRadius: 12))
            Menu {
                ForEach(Self.frases.indices, id: \.self) { i in Button(Self.frases[i].0) { texto = Self.frases[i].1 } }
            } label: {
                Label("Frases de teste", systemImage: "list.bullet").font(.footnote)
            }
        }
    }

    private var cartaoAjustes: some View {
        Cartao(titulo: "Ajustes", icone: "slider.horizontal.3") {
            controle("cfg", $cfg, 0...1)
            controle("Exageração", $exageracao, 0.25...1)
            controle("Temperatura", $temperatura, 0.5...1.2)
            Stepper("Versões por vez: \(versoes)", value: $versoes, in: 1...3)
            Stepper("Semente inicial: \(semente)", value: $semente, in: 1...999)
            Picker("Rodar no", selection: $onde) {
                ForEach(CrisperModelo.Onde.allCases) { Text($0.rawValue).tag($0) }
            }
            Text("Melhor da rodada 2 no GT-PC: cfg 0,5 e exageração 0,3. Cada versão usa uma semente diferente.")
                .font(.caption).foregroundStyle(Tema.texto2)
        }
    }

    private func controle(_ nome: String, _ v: Binding<Float>, _ faixa: ClosedRange<Float>) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(String(format: "%@: %.2f", nome, v.wrappedValue)).font(.footnote)
            Slider(value: v, in: faixa, step: 0.05).tint(Tema.acento)
        }
    }

    private var cartaoAcoes: some View {
        Cartao {
            if teste.rodando {
                ProgressView().frame(maxWidth: .infinity)
                Text(teste.etapa).font(.footnote).foregroundStyle(Tema.texto2)
                Text("Memória do app: \(ByteCountFormatter.string(fromByteCount: Int64(teste.picoMemoria), countStyle: .memory))")
                    .font(.caption).foregroundStyle(Tema.texto2)
                Button("Cancelar", role: .cancel) { teste.cancelar() }.buttonStyle(.glass)
            } else {
                BotaoPrincipal(titulo: "Gerar", icone: "waveform.badge.plus",
                               desativado: !pronto || voz == nil || texto.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) {
                    guard let v = voz else { return }
                    var a = MotorChatterbox.Ajustes()
                    a.cfg = cfg; a.exageracao = exageracao; a.temperatura = temperatura; a.semente = UInt64(semente)
                    teste.gerar(texto: texto, voz: v, ajustes: a, versoes: versoes, onde: onde)
                }
                Button { if let v = voz { teste.conferir(voz: v, onde: onde) } } label: {
                    Label("Conferir o modelo", systemImage: "checkmark.seal").frame(maxWidth: .infinity).padding(.vertical, 4)
                }
                .buttonStyle(.glass)
                .disabled(!pronto || voz == nil)
                if !teste.etapa.isEmpty { Text(teste.etapa).font(.footnote).foregroundStyle(Tema.texto2) }
                if teste.picoMemoria > 0 {
                    Text("Memória de pico do app: \(ByteCountFormatter.string(fromByteCount: Int64(teste.picoMemoria), countStyle: .memory))")
                        .font(.caption).foregroundStyle(Tema.texto2)
                }
            }
            if let e = teste.erro { Text(e).font(.footnote).foregroundStyle(.orange) }
        }
    }

    private func atualizar() {
        pronto = ModeloChatterbox.pronto
        vozes = VozChatterbox.disponiveis()
        if voz == nil || !vozes.contains(where: { $0 == voz }) { voz = vozes.first }
    }

    private func importar(_ r: Result<URL, Error>) {
        guard case .success(let u) = r else { return }
        let acesso = u.startAccessingSecurityScopedResource()
        defer { if acesso { u.stopAccessingSecurityScopedResource() } }
        do {
            _ = try VozChatterbox.ler(u)
            let fm = FileManager.default
            try fm.createDirectory(at: VozChatterbox.pasta, withIntermediateDirectories: true)
            var nome = u.lastPathComponent
            if !nome.lowercased().hasPrefix("voz") { nome = "voz-" + nome }
            let destino = VozChatterbox.pasta.appendingPathComponent(nome)
            try? fm.removeItem(at: destino)
            try fm.copyItem(at: u, to: destino)
            atualizar(); voz = destino
        } catch {
            teste.erro = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    private func tocar(_ u: URL) {
        if tocando == u { tocador?.stop(); tocando = nil; return }
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback)
            try AVAudioSession.sharedInstance().setActive(true)
            tocador = try AVAudioPlayer(contentsOf: u)
            tocador?.play()
            tocando = u
        } catch {
            teste.erro = "Não consegui tocar: \(error.localizedDescription)"
        }
    }
}
