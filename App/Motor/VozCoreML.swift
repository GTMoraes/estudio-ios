import Foundation
import CoreML

/// Modelos de voz convertidos para Core ML nativo (float32), para rodar na GPU do iPhone
/// com a mesma precisão do processador. Ficam no servidor em cdn.frx9.com/modelos/coreml/
/// (os arquivos grandes em partes de 19 MB), são montados e compilados no iPhone na 1ª vez.
enum ModelosCoreML {
    static let base = URL(string: "https://cdn.frx9.com/modelos/coreml/")!

    struct Arquivo { let caminho: String; let bytes: Int64; let partes: Int }
    /// nome do pacote -> arquivos dentro do .mlpackage
    static let pacotes: [(nome: String, arquivos: [Arquivo])] = [
        ("Kim_Vocal_2", [
            Arquivo(caminho: "Manifest.json", bytes: 617, partes: 0),
            Arquivo(caminho: "Data/com.apple.CoreML/model.mlmodel", bytes: 109_598, partes: 0),
            Arquivo(caminho: "Data/com.apple.CoreML/weights/weight.bin", bytes: 66_738_176, partes: 4),
        ]),
        ("UVR-DeEcho-DeReverb", [
            Arquivo(caminho: "Manifest.json", bytes: 617, partes: 0),
            Arquivo(caminho: "Data/com.apple.CoreML/model.mlmodel", bytes: 209_551, partes: 0),
            Arquivo(caminho: "Data/com.apple.CoreML/weights/weight.bin", bytes: 223_148_608, partes: 12),
        ]),
    ]
    static var totalBytes: Int64 { pacotes.flatMap { $0.arquivos }.reduce(0) { $0 + $1.bytes } }

    static var pasta: URL {
        let u = ModelosVoz.pasta.appendingPathComponent("coreml", isDirectory: true)
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }
    static func compilado(_ nome: String) -> URL { pasta.appendingPathComponent(nome + ".mlmodelc", isDirectory: true) }

    static var prontos: Bool {
        pacotes.allSatisfy { FileManager.default.fileExists(atPath: compilado($0.nome).appendingPathComponent("coremldata.bin").path) }
    }

    static func tamanhoEmDisco() -> Int64 {
        guard let e = FileManager.default.enumerator(at: pasta, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
        var t: Int64 = 0
        for case let u as URL in e { t += Int64((try? u.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0) }
        return t
    }
    static func apagar() { try? FileManager.default.removeItem(at: pasta) }

    /// Baixa, monta e compila o que falta. progresso(mensagem, 0...1).
    static func preparar(progresso: @escaping @Sendable (String, Double?) -> Void) async throws {
        var feitos: Int64 = 0
        for p in pacotes {
            if FileManager.default.fileExists(atPath: compilado(p.nome).appendingPathComponent("coremldata.bin").path) {
                feitos += p.arquivos.reduce(0) { $0 + $1.bytes }; continue
            }
            let pacote = FileManager.default.temporaryDirectory.appendingPathComponent(p.nome + ".mlpackage", isDirectory: true)
            try? FileManager.default.removeItem(at: pacote)
            defer { try? FileManager.default.removeItem(at: pacote) }
            for a in p.arquivos {
                let destino = pacote.appendingPathComponent(a.caminho)
                try FileManager.default.createDirectory(at: destino.deletingLastPathComponent(), withIntermediateDirectories: true)
                FileManager.default.createFile(atPath: destino.path, contents: nil)
                let fh = try FileHandle(forWritingTo: destino)
                defer { try? fh.close() }
                let nomes = a.partes == 0 ? [a.caminho] : (0..<a.partes).map { String(format: "%@.part%02ld", a.caminho, $0) }
                for n in nomes {
                    let antes = feitos + Int64((try? fh.offset()) ?? 0)
                    let url = base.appendingPathComponent(p.nome + ".mlpackage").appendingPathComponent(n)
                    let tmp = try await BaixadorCoreML().baixar(url) { b in
                        progresso("Baixando os modelos da GPU (1ª vez)", Double(antes + b) / Double(totalBytes))
                    }
                    let dados = try Data(contentsOf: tmp, options: .alwaysMapped)
                    try fh.write(contentsOf: dados)
                    try? FileManager.default.removeItem(at: tmp)
                }
                let tam = Int64(try fh.offset())
                guard tam == a.bytes else {
                    throw ErroApp("O modelo da GPU \(p.nome) veio incompleto (\(a.caminho)). Tente de novo.")
                }
                feitos += a.bytes
            }
            progresso("Preparando \(p.nome) para a GPU (1ª vez)", nil)
            Diagnostico.log("compilando \(p.nome) para Core ML")
            let t0 = Date()
            let c = try await MLModel.compileModel(at: pacote)
            let destino = compilado(p.nome)
            try? FileManager.default.removeItem(at: destino)
            try FileManager.default.moveItem(at: c, to: destino)
            Diagnostico.log(String(format: "%@ compilado em %.0f s", p.nome, Date().timeIntervalSince(t0)))
        }
    }
}

/// Download simples com progresso (mesma lógica do baixador dos modelos ONNX).
private final class BaixadorCoreML: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private var cont: CheckedContinuation<URL, Error>?
    private var progresso: ((Int64) -> Void)?

    func baixar(_ url: URL, progresso: @escaping (Int64) -> Void) async throws -> URL {
        self.progresso = progresso
        let sessao = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
        defer { sessao.finishTasksAndInvalidate() }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { c in
                self.cont = c
                sessao.downloadTask(with: url).resume()
            }
        } onCancel: {
            sessao.invalidateAndCancel()
        }
    }

    func urlSession(_ s: URLSession, downloadTask: URLSessionDownloadTask, didWriteData _: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite _: Int64) {
        progresso?(totalBytesWritten)
    }

    func urlSession(_ s: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        let codigo = (downloadTask.response as? HTTPURLResponse)?.statusCode ?? 0
        guard codigo == 200 else {
            cont?.resume(throwing: ErroApp("Não consegui baixar \(downloadTask.originalRequest?.url?.lastPathComponent ?? "o modelo") (HTTP \(codigo)).")); cont = nil; return
        }
        let destino = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        do { try FileManager.default.moveItem(at: location, to: destino); cont?.resume(returning: destino) }
        catch { cont?.resume(throwing: error) }
        cont = nil
    }

    func urlSession(_ s: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error { cont?.resume(throwing: error); cont = nil }
    }
}

/// Roda os modelos pelo Core ML (GPU). Um modelo carregado por vez, como no ONNX Runtime.
final class MotorCoreML {
    private var modelos: [MLModel?] = [nil, nil]
    private let unidades: MLComputeUnits

    init(unidades: MLComputeUnits) { self.unidades = unidades }

    static let formas: [(entrada: [Int], saida: [Int])] = [
        ([1, 4, 3072, 256], [1, 4, 3072, 256]),
        ([1, 2, 673, 512], [1, 2, 673, 384]),
    ]

    private func modelo(_ i: Int) throws -> MLModel {
        if let m = modelos[i] { return m }
        modelos[1 - i] = nil                                   // libera o da etapa anterior
        let cfg = MLModelConfiguration()
        cfg.computeUnits = unidades
        cfg.allowLowPrecisionAccumulationOnGPU = false         // contas em float32 de ponta a ponta
        let t0 = Date()
        let m = try MLModel(contentsOf: ModelosCoreML.compilado(ModelosCoreML.pacotes[i].nome), configuration: cfg)
        Diagnostico.log(String(format: "Core ML: modelo %d carregado em %.1f s", i, Date().timeIntervalSince(t0)))
        modelos[i] = m
        return m
    }

    private static func passos(_ forma: [Int]) -> [NSNumber] {
        var p = [Int](repeating: 1, count: forma.count)
        for k in stride(from: forma.count - 2, through: 0, by: -1) { p[k] = p[k + 1] * forma[k + 1] }
        return p.map { NSNumber(value: $0) }
    }

    func inferir(_ i: Int, _ entrada: UnsafePointer<Float>, _ saida: UnsafeMutablePointer<Float>) throws {
        let f = Self.formas[i]
        let arrIn = try MLMultiArray(dataPointer: UnsafeMutableRawPointer(mutating: entrada),
                                     shape: f.entrada.map { NSNumber(value: $0) }, dataType: .float32,
                                     strides: Self.passos(f.entrada), deallocator: nil)
        let arrOut = try MLMultiArray(dataPointer: UnsafeMutableRawPointer(saida),
                                      shape: f.saida.map { NSNumber(value: $0) }, dataType: .float32,
                                      strides: Self.passos(f.saida), deallocator: nil)
        let prov = try MLDictionaryFeatureProvider(dictionary: ["input": MLFeatureValue(multiArray: arrIn)])
        let op = MLPredictionOptions()
        op.outputBackings = ["output": arrOut]
        let r = try modelo(i).prediction(from: prov, options: op)
        // se o Core ML não escreveu direto no nosso buffer, copia
        if let o = r.featureValue(for: "output")?.multiArrayValue, o.dataPointer != arrOut.dataPointer {
            let n = f.saida.reduce(1, *)
            let s = MLShapedArray<Float>(converting: o)
            s.withUnsafeShapedBufferPointer { p, _, _ in
                if let b = p.baseAddress { saida.update(from: b, count: min(n, p.count)) }
            }
        }
    }
}
