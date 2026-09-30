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
        case transcricao, vozProcessador, vozGPU
        var id: String { rawValue }
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
        }
    }

    func detalhe(_ p: Parte) -> String {
        switch p {
        case .transcricao: return "Baixa ~630 MB e compila para o Neural Engine (3 a 4 min)"
        case .vozProcessador: return "Baixa 290 MB"
        case .vozGPU: return "Baixa 290 MB, monta e prepara na GPU (1 a 2 min)"
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
        }
    }

    func pronto(_ p: Parte) -> Bool { if case .pronto = estado(p) { return true }; return false }
    var tudoPronto: Bool { Parte.allCases.allSatisfy { pronto($0) } }

    func preparar(_ partes: [Parte]) {
        guard !ocupado else { return }
        ocupado = true
        UIApplication.shared.isIdleTimerDisabled = true
        Task { @MainActor in
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
