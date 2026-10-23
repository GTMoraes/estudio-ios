import Foundation
import CoreML
import Observation
import UIKit

/// Chave do cache de compilação do iOS: muda quando o cache deixa de valer
/// (app instalado/atualizado — a pasta do app muda a cada instalação — ou outra versão do iOS).
enum CacheCompilacao {
    static func chave(_ nome: String) -> String {
        [nome, Bundle.main.bundleURL.path, ProcessInfo.processInfo.operatingSystemVersionString].joined(separator: "|")
    }
    static func feito(_ nome: String) -> Bool {
        UserDefaults.standard.string(forKey: "compilado." + nome) == chave(nome)
    }
    static func marcar(_ nome: String) {
        UserDefaults.standard.set(chave(nome), forKey: "compilado." + nome)
    }
}

/// Ajustes › "Deixar o app pronto": baixa e compila de antemão o que o app usa no iPhone,
/// para o primeiro trabalho não esperar minutos.
@MainActor
@Observable
final class Preparacao {
    static let shared = Preparacao()

    enum Parte: String, CaseIterable, Identifiable {
        case transcricao, vozProcessador, vozGPU, corte, alinhador, clonagem
        var id: String { rawValue }
        /// "Preparar tudo" deixa de fora o que ainda é teste.
        static var principais: [Parte] { allCases.filter { $0 != .clonagem } }
    }

    struct Andamento: Equatable { var mensagem: String; var fracao: Double? }

    private(set) var andamento: [Parte: Andamento] = [:]
    private(set) var erro: [Parte: String] = [:]
    private(set) var ocupado = false
    /// muda a cada preparação: faz a tela reler o estado do disco
    private(set) var versao = 0

    func titulo(_ p: Parte) -> String {
        switch p {
        case .transcricao: return "Transcrição: " + (TranscritorLocal.modelos.first { $0.id == modeloTranscricao }?.nome ?? "modelo")
        case .vozProcessador: return "Tratar voz: modelos do processador"
        case .vozGPU: return "Tratar voz: modelos da GPU"
        case .corte: return "Corte automático: CrisperWhisper"
        case .alinhador: return "Corte automático: alinhador"
        case .clonagem: return "Clonagem de voz (teste): Chatterbox"
        }
    }

    func detalhe(_ p: Parte) -> String {
        switch p {
        case .transcricao: return "Baixa ~630 MB e compila para o Neural Engine (3 a 4 min)"
        case .vozProcessador: return "Baixa 290 MB"
        case .vozGPU: return "Baixa 290 MB, monta e prepara na GPU (1 a 2 min)"
        case .corte: return "Baixa 1,2 GB e prepara na GPU (o que foi dito, palavra por palavra)"
        case .alinhador: return "Baixa 1,2 GB (onde cada palavra começa e termina)"
        case .clonagem: return "Baixa 1,6 GB e prepara para este iPhone (alguns minutos)"
        }
    }

    var modeloTranscricao: String {
        UserDefaults.standard.string(forKey: "modeloLocal") ?? TranscritorLocal.modeloPadrao
    }

    enum Estado { case pronto, falta(String) }

    func estado(_ p: Parte) -> Estado {
        _ = versao
        switch p {
        case .transcricao:
            if TranscritorLocal.pastaDoModelo(modeloTranscricao) == nil { return .falta("Não baixado") }
            return TranscritorLocal.compilado(modeloTranscricao) ? .pronto : .falta("Baixado; falta compilar")
        case .vozProcessador:
            return ModelosVoz.prontos ? .pronto : .falta("Não baixado")
        case .vozGPU:
            if !ModelosCoreML.prontos { return .falta("Não baixado") }
            return ModelosCoreML.aquecidos ? .pronto : .falta("Baixado; falta preparar na GPU")
        case .corte:
            if !ModeloCrisper.pronto { return .falta("Não baixado") }
            return CacheCompilacao.feito("crisper-gpu") ? .pronto : .falta("Baixado; falta preparar na GPU")
        case .alinhador:
            return ModeloAlinhador.pronto ? .pronto : .falta("Não baixado")
        case .clonagem:
            if !ModeloChatterbox.pronto { return .falta("Não baixado") }
            return ModeloChatterbox.temCompilado ? .pronto : .falta("Baixado; falta preparar")
        }
    }

    @ObservationIgnored private var cacheEspaco: [Parte: Int64] = [:]
    @ObservationIgnored private var versaoDoCache = -1

    /// Relê do disco o que está baixado (a tela chama ao aparecer).
    func recarregar() { versao += 1 }

    /// Espaço que a parte ocupa no iPhone (0 = nada baixado). Lido do disco só quando algo muda.
    func espaco(_ p: Parte) -> Int64 {
        if versaoDoCache != versao {
            versaoDoCache = versao
            cacheEspaco = Dictionary(uniqueKeysWithValues: Parte.allCases.map { ($0, Self.medir($0)) })
        }
        return cacheEspaco[p] ?? 0
    }

    private static func medir(_ p: Parte) -> Int64 {
        switch p {
        case .transcricao: return TranscritorLocal.tamanhoEmDisco()
        case .vozProcessador: return ModelosVoz.tamanhoEmDisco()
        case .vozGPU: return ModelosCoreML.tamanhoEmDisco()
        case .corte: return ModeloCrisper.tamanhoEmDisco()
        case .alinhador: return ModeloAlinhador.tamanhoEmDisco()
        case .clonagem: return ModeloChatterbox.tamanhoEmDisco()
        }
    }

    var espacoTotal: Int64 { Parte.allCases.reduce(0) { $0 + espaco($1) } }

    /// Apaga o que a parte baixou (a tela pergunta "Tem certeza?" antes).
    func apagar(_ p: Parte) async {
        guard !ocupado else { return }
        switch p {
        case .transcricao: await TranscritorLocal.shared.apagarModelos()
        case .vozProcessador: ModelosVoz.apagar()
        case .vozGPU: ModelosCoreML.apagar()
        case .corte: ModeloCrisper.apagar()
        case .alinhador: ModeloAlinhador.apagar()
        case .clonagem: ModeloChatterbox.apagar()
        }
        erro[p] = nil
        versao += 1
    }

    func pronto(_ p: Parte) -> Bool { if case .pronto = estado(p) { return true }; return false }
    var tudoPronto: Bool { Parte.principais.allSatisfy { pronto($0) } }

    func preparar(_ partes: [Parte], estudio: Estudio? = nil) {
        guard !ocupado else { return }
        ocupado = true
        UIApplication.shared.isIdleTimerDisabled = true
        Task { @MainActor in
            // entra na fila dos trabalhos pesados (carregar modelos junto com um trabalho estoura a memória)
            let dono = UUID()
            if let estudio, let primeira = partes.first(where: { !pronto($0) }) {
                try? await estudio.aguardarVezDoEditor(dono) { pos in
                    self.andamento[primeira] = Andamento(mensagem: pos <= 1 ? "Na fila: começa quando o trabalho atual terminar"
                                                                            : "Na fila (\(pos)º)", fracao: nil)
                }
            }
            defer { estudio?.liberarVezDoEditor(dono) }
            for p in partes where !pronto(p) {
                erro[p] = nil
                andamento[p] = Andamento(mensagem: "Começando", fracao: nil)
                do {
                    try await executar(p)
                } catch {
                    erro[p] = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                }
                andamento[p] = nil
                versao += 1
            }
            ocupado = false
            UIApplication.shared.isIdleTimerDisabled = false
        }
    }

    private func executar(_ p: Parte) async throws {
        let avisar: @Sendable (String, Double?) -> Void = { msg, f in
            Task { @MainActor in self.andamento[p] = Andamento(mensagem: msg, fracao: f) }
        }
        switch p {
        case .transcricao:
            try await TranscritorLocal.shared.prepararDeAntemao(modeloTranscricao, avisar: avisar)
        case .vozProcessador:
            try await ModelosVoz.baixar { f in avisar("Baixando", f) }
        case .vozGPU:
            try await ModelosCoreML.preparar(progresso: avisar)
            avisar("Preparando na GPU", nil)
            try await Task.detached(priority: .userInitiated) { try ModelosCoreML.aquecer() }.value
        case .corte:
            if !ModeloCrisper.pronto {
                try await ModeloCrisper.baixar(nome: "o CrisperWhisper") { f, msg in avisar(msg, f) }
            }
            avisar("Preparando na GPU (alguns minutos na 1ª vez)", nil)
            let pasta = ModeloCrisper.pasta
            try await Task.detached(priority: .userInitiated) {
                _ = try CrisperTranscritor(pasta: pasta, onde: .gpu)      // carrega uma vez e solta
            }.value
            CacheCompilacao.marcar("crisper-gpu")
        case .alinhador:
            try await ModeloCrisper.baixar(de: ModeloAlinhador.base, para: ModeloAlinhador.pasta,
                                           nome: "o alinhador") { f, msg in avisar(msg, f) }
        case .clonagem:
            if !ModeloChatterbox.pronto {
                try await ModeloCrisper.baixar(de: ModeloChatterbox.base, para: ModeloChatterbox.pasta, nome: "o Chatterbox",
                                               pular: ModeloChatterbox.temCompilado ? "T3.mlpackage/" : nil) { f, msg in avisar(msg, f) }
            }
            avisar("Preparando para este iPhone", nil)
            _ = try await ModeloChatterbox.compilarSePreciso()
        }
    }
}

extension ModelosCoreML {
    /// Já carregados na GPU uma vez desde a última instalação (o iOS guarda a preparação).
    static var aquecidos: Bool { prontos && pacotes.allSatisfy { CacheCompilacao.feito("voz-gpu-" + $0.nome) } }

    /// Carrega cada modelo na GPU uma vez, com a mesma configuração do tratamento, e solta.
    static func aquecer() throws {
        for p in pacotes {
            try autoreleasepool {
                let cfg = MLModelConfiguration()
                cfg.computeUnits = .cpuAndGPU
                cfg.allowLowPrecisionAccumulationOnGPU = false
                _ = try MLModel(contentsOf: compilado(p.nome), configuration: cfg)
            }
            CacheCompilacao.marcar("voz-gpu-" + p.nome)
        }
    }
}
