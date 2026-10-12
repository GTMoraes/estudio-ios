import SwiftUI
import UniformTypeIdentifiers

/// Ajustes › "Teste: corte automático". Roda o CrisperWhisper convertido num áudio, mede tempo e
/// memória e grava em Arquivos (No meu iPhone › Estúdio › CrisperWhisper-testes) o texto, as
/// palavras com tempos e o áudio cortado pela regra aprovada.
struct CartaoTesteCrisper: View {
    var body: some View {
        Cartao(titulo: "Teste: corte automático", icone: "scissors") {
            Text("Experimental. Usa o CrisperWhisper da pasta “No meu iPhone › Estúdio › CrisperWhisper”.")
                .font(.footnote).foregroundStyle(Tema.texto2)
            NavigationLink { TesteCrisperView() } label: {
                Label("Abrir o teste", systemImage: "flask").frame(maxWidth: .infinity).padding(.vertical, 6)
            }
            .buttonStyle(.glass)
        }
    }
}

@MainActor @Observable
final class TesteCrisper {
    var etapa = ""
    var progresso: Double?
    var rodando = false
    var erro: String?
    var resumo: [String] = []
    var texto = ""
    var pastaSaida: URL?
    var picoMemoria: UInt64 = 0
    private var tarefa: Task<Void, Never>?

    static var raiz: URL { FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0] }
    static var pastaModelo: URL { raiz.appendingPathComponent("CrisperWhisper", isDirectory: true) }

    var modeloEncontrado: Bool { CrisperModelo.acharPasta(em: Self.pastaModelo) != nil }
    var dicionarioEncontrado: Bool { CrisperModelo.acharArquivo("tokenizer.json", em: Self.pastaModelo) != nil }

    func cancelar() { tarefa?.cancel() }

    func rodar(audio origem: URL, onde: CrisperModelo.Onde) {
        guard !rodando else { return }
        rodando = true; erro = nil; resumo = []; texto = ""; pastaSaida = nil; picoMemoria = Memoria.agora()
        let medidor = Task { [weak self] in
            while !Task.isCancelled {
                let m = Memoria.agora()
                await MainActor.run { if let s = self, m > s.picoMemoria { s.picoMemoria = m } }
                try? await Task.sleep(for: .milliseconds(250))
            }
        }
        tarefa = Task {
            defer { medidor.cancel(); rodando = false; progresso = nil }
            do {
                let pasta = Self.pastaModelo
                etapa = "Lendo o áudio"; progresso = nil
                let audio = try await CrisperTranscritor.lerAudio(origem)
                etapa = "Carregando o modelo (na primeira vez o iPhone compila para o \(onde.rawValue): pode levar alguns minutos)"
                let t0 = Date()
                let carga = Task.detached(priority: .userInitiated) {
                    try CrisperTranscritor(pasta: pasta, onde: onde)
                }
                let transcritor = try await withTaskCancellationHandler { try await carga.value } onCancel: { carga.cancel() }
                let tCarga = Date().timeIntervalSince(t0)
                let t1 = Date()
                let trabalho = Task.detached(priority: .userInitiated) { [weak self] in
                    try transcritor.transcrever(audio) { p, msg in
                        Task { @MainActor in self?.progresso = p; self?.etapa = "Transcrevendo: " + msg }
                    }
                }
                let r = try await withTaskCancellationHandler { try await trabalho.value } onCancel: { trabalho.cancel() }
                let tTrans = Date().timeIntervalSince(t1)
                etapa = "Cortando"; progresso = nil
                let trechos = CorteAutomatico.trechos(r.palavras, audio: audio)

                let fmt = DateFormatter(); fmt.dateFormat = "yyyy-MM-dd HH.mm.ss"
                let saida = Self.raiz.appendingPathComponent("CrisperWhisper-testes", isDirectory: true)
                    .appendingPathComponent(fmt.string(from: Date()), isDirectory: true)
                try FileManager.default.createDirectory(at: saida, withIntermediateDirectories: true)
                let base = origem.deletingPathExtension().lastPathComponent
                try await CorteAutomatico.gravar(origem: origem, trechos: trechos,
                                                 destino: saida.appendingPathComponent(base + "-cortado.m4a"))

                let mantido = trechos.reduce(0) { $0 + ($1.f - $1.i) }
                let linhas = [
                    "Estúdio \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?") · \(onde.rawValue)",
                    "Áudio: \(formatarTempo(r.segundosAudio))",
                    "Carregar o modelo: \(String(format: "%.1f", tCarga)) s",
                    "Transcrever: \(String(format: "%.1f", tTrans)) s (\(String(format: "%.1f", r.segundosAudio / max(tTrans, 0.01)))× o tempo real)",
                    "Memória de pico do app: \(ByteCountFormatter.string(fromByteCount: Int64(picoMemoria), countStyle: .memory))",
                    "Palavras com tempo: \(r.palavras.count) · reparos de repetição: \(r.reparos)",
                    "Cortes: \(max(0, trechos.count - 1)) · fica \(formatarTempo(mantido)) de \(formatarTempo(r.segundosAudio))",
                ]
                resumo = linhas
                texto = r.texto
                let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
                struct Saida: Codable { var texto: String; var palavras: [PalavraTempo]; var trechos: [CorteAutomatico.Trecho] }
                try enc.encode(Saida(texto: r.texto, palavras: r.palavras, trechos: trechos))
                    .write(to: saida.appendingPathComponent("palavras.json"))
                try (linhas.joined(separator: "\n") + "\n\n" + r.texto + "\n")
                    .write(to: saida.appendingPathComponent("relatorio.txt"), atomically: true, encoding: .utf8)
                pastaSaida = saida
                etapa = "Pronto"
            } catch is CancellationError {
                etapa = "Cancelado"
            } catch {
                erro = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                etapa = ""
            }
        }
    }

    private func formatarTempo(_ s: Double) -> String {
        String(format: "%d:%04.1f", Int(s) / 60, s.truncatingRemainder(dividingBy: 60))
    }
}

enum Memoria {
    /// Memória que o iOS conta para o app (a mesma usada para encerrar apps que passam do limite).
    static func agora() -> UInt64 {
        var info = task_vm_info_data_t()
        var n = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let r = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(n)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &n) }
        }
        return r == KERN_SUCCESS ? info.phys_footprint : 0
    }
}

struct TesteCrisperView: View {
    @State private var teste = TesteCrisper()
    @State private var escolhendo = false
    @State private var onde: CrisperModelo.Onde = .neural

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                Cartao(titulo: "Modelo", icone: "cpu") {
                    Label(teste.modeloEncontrado ? "Modelo encontrado" : "Modelo não encontrado",
                          systemImage: teste.modeloEncontrado ? "checkmark.circle.fill" : "xmark.circle")
                        .foregroundStyle(teste.modeloEncontrado ? Color.green : Color.orange)
                    Label(teste.dicionarioEncontrado ? "Dicionário encontrado" : "Dicionário (tokenizer.json) não encontrado",
                          systemImage: teste.dicionarioEncontrado ? "checkmark.circle.fill" : "xmark.circle")
                        .foregroundStyle(teste.dicionarioEncontrado ? Color.green : Color.orange)
                    Text("Copie a pasta do modelo e os arquivos .json para “No meu iPhone › Estúdio › CrisperWhisper”.")
                        .font(.footnote).foregroundStyle(Tema.texto2)
                    Picker("Rodar em", selection: $onde) {
                        ForEach(CrisperModelo.Onde.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .disabled(teste.rodando)
                }
                Cartao(titulo: "Áudio", icone: "waveform") {
                    if teste.rodando {
                        Text(teste.etapa).font(.subheadline)
                        if let p = teste.progresso { ProgressView(value: p) } else { ProgressView() }
                        Button("Cancelar", role: .cancel) { teste.cancelar() }.buttonStyle(.glass)
                    } else {
                        Button { escolhendo = true } label: {
                            Label("Escolher áudio ou vídeo e rodar", systemImage: "play.fill")
                                .frame(maxWidth: .infinity).padding(.vertical, 6)
                        }
                        .buttonStyle(.glassProminent)
                        .disabled(!teste.modeloEncontrado || !teste.dicionarioEncontrado)
                        if !teste.etapa.isEmpty { Text(teste.etapa).font(.footnote).foregroundStyle(Tema.texto2) }
                    }
                    if let e = teste.erro {
                        Label(e, systemImage: "exclamationmark.triangle.fill").font(.footnote).foregroundStyle(.yellow)
                    }
                }
                if !teste.resumo.isEmpty {
                    Cartao(titulo: "Resultado", icone: "chart.bar") {
                        ForEach(teste.resumo, id: \.self) { Text($0).font(.footnote) }
                        if let p = teste.pastaSaida {
                            Text("Arquivos em: Estúdio › CrisperWhisper-testes › \(p.lastPathComponent)")
                                .font(.footnote).foregroundStyle(Tema.texto2)
                        }
                    }
                    Cartao(titulo: "Texto", icone: "text.quote") {
                        Text(teste.texto).font(.footnote).textSelection(.enabled)
                    }
                }
            }
            .padding()
        }
        .telaEscura()
        .navigationTitle("Corte automático")
        .navigationBarTitleDisplayMode(.inline)
        .fileImporter(isPresented: $escolhendo, allowedContentTypes: [.audio, .movie]) { r in
            guard case .success(let url) = r else { return }
            let acesso = url.startAccessingSecurityScopedResource()
            let copia = FileManager.default.temporaryDirectory.appendingPathComponent(url.lastPathComponent)
            try? FileManager.default.removeItem(at: copia)
            do { try FileManager.default.copyItem(at: url, to: copia) } catch { teste.erro = error.localizedDescription }
            if acesso { url.stopAccessingSecurityScopedResource() }
            teste.rodar(audio: copia, onde: onde)
        }
    }
}
