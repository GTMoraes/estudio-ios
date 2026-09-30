import Foundation
import AVFoundation
import CoreML
import os
import OnnxRuntimeBindings   // liga a biblioteca do ONNX Runtime (usada pela API C em mv_ort.c)

/// Tratamento de voz no iPhone: o mesmo motor da nuvem (motor_voz), portado para C
/// (App/MotorVoz). Aqui ficam os modelos (baixados na 1ª vez), a leitura do áudio e a
/// ponte com o ONNX Runtime.

struct OpcoesVozLocal {
    var voz: OpcoesVoz
    var quadra = false
}

// MARK: - modelos

enum ModelosVoz {
    /// Hospedados no servidor do Gabriel (sites-frx9 › cdn/modelos).
    static let base = URL(string: "https://cdn.frx9.com/modelos/")!
    static let arquivos: [(nome: String, bytes: Int64)] = [
        ("Kim_Vocal_2.onnx", 66_759_214),
        ("UVR-DeEcho-DeReverb.onnx", 223_235_646),
    ]
    static var totalBytes: Int64 { arquivos.reduce(0) { $0 + $1.bytes } }

    static var pasta: URL {
        var u = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("modelos-voz", isDirectory: true)
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        var rv = URLResourceValues(); rv.isExcludedFromBackup = true
        try? u.setResourceValues(rv)
        return u
    }
    static func caminho(_ nome: String) -> URL { pasta.appendingPathComponent(nome) }

    static var prontos: Bool {
        arquivos.allSatisfy { tamanho(caminho($0.nome)) == $0.bytes }
    }
    static func tamanhoEmDisco() -> Int64 { arquivos.reduce(0) { $0 + max(0, tamanho(caminho($1.nome))) } }
    static func apagar() { arquivos.forEach { try? FileManager.default.removeItem(at: caminho($0.nome)) } }

    private static func tamanho(_ u: URL) -> Int64 {
        ((try? FileManager.default.attributesOfItem(atPath: u.path))?[.size] as? NSNumber)?.int64Value ?? -1
    }

    /// Baixa o que falta. progresso: 0...1 sobre o total.
    static func baixar(progresso: @escaping @Sendable (Double) -> Void) async throws {
        var feitos: Int64 = 0
        for a in arquivos {
            let destino = caminho(a.nome)
            if tamanho(destino) == a.bytes { feitos += a.bytes; continue }
            let antes = feitos
            let tmp = try await Baixador().baixar(Self.base.appendingPathComponent(a.nome)) { bytes in
                progresso(Double(antes + bytes) / Double(totalBytes))
            }
            guard tamanho(tmp) == a.bytes else {
                try? FileManager.default.removeItem(at: tmp)
                throw ErroApp("O modelo \(a.nome) veio incompleto. Tente de novo.")
            }
            try? FileManager.default.removeItem(at: destino)
            try FileManager.default.moveItem(at: tmp, to: destino)
            feitos += a.bytes
        }
        progresso(1)
    }
}

/// Download com progresso (URLSession com delegate).
private final class Baixador: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
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
            cont?.resume(throwing: ErroApp("Não consegui baixar o modelo (HTTP \(codigo)).")); cont = nil; return
        }
        // o arquivo temporário some quando este método volta: move já
        let destino = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        do { try FileManager.default.moveItem(at: location, to: destino); cont?.resume(returning: destino) }
        catch { cont?.resume(throwing: error) }
        cont = nil
    }

    func urlSession(_ s: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error { cont?.resume(throwing: error); cont = nil }
    }
}

// MARK: - diagnóstico

/// Registro das etapas em Documentos/diagnostico-voz.txt (aparece no app Arquivos, em
/// "No meu iPhone › Estúdio"). Se o app fechar no meio, a última linha mostra onde parou
/// e quanta memória ainda sobrava.
enum Diagnostico {
    private static let fila = DispatchQueue(label: "diagnostico-voz")
    static var arquivo: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("diagnostico-voz.txt")
    }

    static func iniciar() {
        fila.sync { try? Data().write(to: arquivo) }
        log("início")
    }

    static func log(_ msg: String) {
        let livre = Double(os_proc_available_memory()) / 1_048_576
        let linha = String(format: "%@  %@  (memória livre para o app: %.0f MB)\n",
                           ISO8601DateFormatter().string(from: Date()), msg, livre)
        fila.sync {
            guard let d = linha.data(using: .utf8) else { return }
            if let h = try? FileHandle(forWritingTo: arquivo) {
                h.seekToEndOfFile(); h.write(d); try? h.synchronize(); try? h.close()
            } else {
                try? d.write(to: arquivo)
            }
        }
    }
}

// MARK: - motor

/// Estado compartilhado com o C durante um tratamento (passado como ctx).
/// Os modelos rodam no ONNX Runtime pela API C (App/MotorVoz/mv_ort.c).
private final class HostVoz {
    let ort: OpaquePointer?
    let coreml: MotorCoreML?
    /// por modelo: roda no Core ML (GPU)? Vira false se a conferência com o processador falhar.
    var usarCoreML: [Bool]
    var caminhosONNX: (String, String) = ("", "")
    var cancelado = false
    let progresso: (Int32, Double) -> Void
    var modelosVistos = Set<Int32>()
    var ultimaEtapa: Int32 = -1
    var ultimoDecimo = -1

    init(ort: OpaquePointer?, coreml: MotorCoreML?, progresso: @escaping (Int32, Double) -> Void) {
        self.ort = ort
        self.coreml = coreml
        self.usarCoreML = [coreml != nil && !HostVoz.conferencia(0).falhou, coreml != nil && !HostVoz.conferencia(1).falhou]
        self.progresso = progresso
    }
    deinit { mv_ort_fechar(ort) }

    var erroModelo: String? {
        guard let ort else { return "sem memória" }
        let s = String(cString: mv_ort_erro(ort))
        return s.isEmpty ? nil : s
    }

    /// Resultado guardado da conferência de cada modelo, válido para esta versão do iOS
    /// (o Core ML e o driver da GPU mudam com o sistema; numa versão nova, confere de novo).
    private static var versaoSistema: String { ProcessInfo.processInfo.operatingSystemVersionString }
    static func conferencia(_ modelo: Int32) -> (feita: Bool, falhou: Bool) {
        guard let v = UserDefaults.standard.string(forKey: "vozConferencia\(modelo)") else { return (false, false) }
        let partes = v.split(separator: "|", maxSplits: 1).map(String.init)
        guard partes.count == 2, partes[1] == versaoSistema else { return (false, false) }
        return (true, partes[0] == "falhou")
    }
    private static func guardarConferencia(_ modelo: Int32, ok: Bool) {
        UserDefaults.standard.set((ok ? "ok|" : "falhou|") + versaoSistema, forKey: "vozConferencia\(modelo)")
    }

    /// Na 1ª vez de cada modelo na GPU (nesta versão do iOS), roda o mesmo trecho também no processador (ONNX
    /// Runtime) e compara. Se a diferença passar do aceitável, esse modelo volta para o
    /// processador e o resultado fica igual ao da nuvem.
    func conferir(_ modelo: Int32, _ entrada: UnsafePointer<Float>, _ saidaGPU: UnsafeMutablePointer<Float>) {
        let n = MotorCoreML.formas[Int(modelo)].saida.reduce(1, *)
        let ref = UnsafeMutablePointer<Float>.allocate(capacity: n)
        defer { ref.deallocate() }
        let cpu = mv_ort_abrir(caminhosONNX.0, caminhosONNX.1, 0)
        defer { mv_ort_fechar(cpu) }
        guard mv_ort_inferir(UnsafeMutableRawPointer(cpu), modelo, entrada, ref) == 0 else {
            Diagnostico.log("conferência do modelo \(modelo): o processador falhou; seguindo na GPU sem conferir")
            return
        }
        var sinal = 0.0, erro = 0.0
        for k in 0..<n {
            let a = Double(ref[k]), d = a - Double(saidaGPU[k])
            sinal += a * a; erro += d * d
        }
        let snr = erro > 0 ? 10 * log10(sinal / erro) : 200
        let ok = snr >= 60
        Self.guardarConferencia(modelo, ok: ok)
        Diagnostico.log(String(format: "conferência GPU x processador, modelo %d: %.1f dB %@", modelo, snr,
                               ok ? "(ok)" : "(diferente demais: este modelo volta para o processador)"))
        if !ok {
            usarCoreML[Int(modelo)] = false
            saidaGPU.update(from: ref, count: n)
        }
    }
}

private let cInferir: MVInferir = { ctx, modelo, entrada, saida in
    guard let ctx, let entrada, let saida else { return -1 }
    let h = Unmanaged<HostVoz>.fromOpaque(ctx).takeUnretainedValue()
    let primeira = !h.modelosVistos.contains(modelo)
    if primeira { h.modelosVistos.insert(modelo); Diagnostico.log("modelo \(modelo): abrindo e rodando a 1ª vez") }
    // fora da tela o tratamento pausa aqui (a GPU do iPhone não roda em segundo plano)
    if !EstadoApp.shared.ativo {
        Diagnostico.log("app fora da tela: pausado")
        EstadoApp.shared.esperarAtivo()
        Diagnostico.log("app de volta: continuando")
    }
    if let cm = h.coreml, h.usarCoreML[Int(modelo)] {
        let geracao = EstadoApp.shared.geracao
        do {
            do {
                try cm.inferir(Int(modelo), entrada, saida)
            } catch where EstadoApp.shared.geracao != geracao || !EstadoApp.shared.ativo {
                // o app saiu da tela no meio da conta: espera voltar e refaz o bloco na GPU
                Diagnostico.log("modelo \(modelo): GPU interrompida ao sair da tela; refazendo ao voltar")
                EstadoApp.shared.esperarAtivo()
                try cm.inferir(Int(modelo), entrada, saida)
            }
            if primeira {
                Diagnostico.log("modelo \(modelo): 1ª inferência na GPU ok")
                if HostVoz.conferencia(modelo).feita {
                    Diagnostico.log("modelo \(modelo): já conferido com o processador nesta versão do iOS")
                } else {
                    h.conferir(modelo, entrada, saida)
                }
            }
            return 0
        } catch {
            Diagnostico.log("modelo \(modelo): Core ML falhou (\(error.localizedDescription)); voltando para o processador")
            h.usarCoreML[Int(modelo)] = false
        }
    }
    let r = mv_ort_inferir(UnsafeMutableRawPointer(h.ort), modelo, entrada, saida)
    if primeira || r != 0 {
        let e = h.ort.map { String(cString: mv_ort_erro($0)) } ?? ""
        Diagnostico.log("modelo \(modelo): 1ª inferência r=\(r) \(e)")
    }
    return r
}
private let cProgresso: MVProgresso = { ctx, etapa, fracao in
    guard let ctx else { return }
    let h = Unmanaged<HostVoz>.fromOpaque(ctx).takeUnretainedValue()
    let decimo = Int(fracao * 10)
    if etapa != h.ultimaEtapa || decimo != h.ultimoDecimo {
        h.ultimaEtapa = etapa; h.ultimoDecimo = decimo
        Diagnostico.log(String(format: "etapa %d: %.0f%%", etapa, fracao * 100))
    }
    h.progresso(etapa, fracao)
}
private let cCancelado: MVCancelado = { ctx in
    guard let ctx else { return 0 }
    return Unmanaged<HostVoz>.fromOpaque(ctx).takeUnretainedValue().cancelado ? 1 : 0
}

enum VozLocal {
    /// Tamanho do bloco: a memória depende dele, não da duração do áudio.
    static let blocoSegundos = 300.0

    /// O Core ML pode derrubar o app ao preparar o modelo (exceção que não dá para capturar).
    /// Marca a tentativa antes; se o app abrir de novo com a marca, desliga o Neural Engine.
    private static let chaveTentando = "vozNeuralTentando"
    static func neuralDerrubouOApp() -> Bool {
        let d = UserDefaults.standard
        guard d.bool(forKey: chaveTentando) else { return false }
        d.set(false, forKey: chaveTentando)
        d.set("cpu", forKey: "vozAcelerador")
        return true
    }

    /// Trata `arquivo` e grava os MP3 em `pasta`. Devolve os nomes (mix, voz, trilha).
    /// trabalho: pasta dos intermediários (entrada decodificada, blocos prontos, ponto de retomada).
    /// Se já tiver um trabalho começado lá, continua de onde parou.
    static func tratar(_ arquivo: URL, opcoes: OpcoesVozLocal, pasta: URL, base: String, trabalho: URL,
                       progresso: @escaping @Sendable (String, Double?) -> Void) async throws -> (arquivos: [String], duracao: Double) {
        Diagnostico.iniciar()
        Diagnostico.log("arquivo: \(arquivo.lastPathComponent), modo \(opcoes.voz.modo.rawValue), eco \(opcoes.voz.eco), clareza \(opcoes.voz.clareza), quadra \(opcoes.quadra)")
        if !ModelosVoz.prontos {
            Diagnostico.log("baixando modelos")
            progresso("Baixando os modelos de voz (1ª vez)", 0)
            try await ModelosVoz.baixar { p in progresso("Baixando os modelos de voz (1ª vez)", p) }
        }
        try Task.checkCancellation()

        let tmp = trabalho
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)

        let entrada = tmp.appendingPathComponent("entrada.f32")
        let marca = tmp.appendingPathComponent("entrada.ok")      // guarda o nº de quadros: a leitura terminou
        let quadros: Int
        if let t = try? String(contentsOf: marca, encoding: .utf8), let q = Int(t),
           FileManager.default.fileExists(atPath: entrada.path) {
            quadros = q
            Diagnostico.log(String(format: "continuando um trabalho começado: áudio de %.1f s já lido", Double(q) / 44100))
        } else {
            progresso("Lendo o áudio", nil)
            Diagnostico.log("modelos prontos; lendo o áudio")
            quadros = try await LeitorAudio.lerEstereo441(arquivo, para: entrada)
            try String(quadros).write(to: marca, atomically: true, encoding: .utf8)
            Diagnostico.log(String(format: "áudio lido: %.1f s", Double(quadros) / 44100))
        }
        try Task.checkCancellation()

        let v = opcoes.voz
        let separar = v.modo != .soVoz
        let suf = opcoes.quadra ? "-quadra" : ""
        let nVoz = "\(base)-voz-tratada\(suf).mp3", nTri = "\(base)-trilha-separada\(suf).mp3", nMix = "\(base)-mix-tratado\(suf).mp3"
        try FileManager.default.createDirectory(at: pasta, withIntermediateDirectories: true)

        var op = MVOpcoes()
        op.separar = separar ? 1 : 0
        op.eco = v.eco ? 1 : 0
        op.clareza = v.clareza ? 1 : 0
        op.mono = v.modo != .musica ? 1 : 0
        op.nivelar = v.modo != .musica ? 1 : 0
        op.voz_frente_db = Double(v.vozFrente)
        op.quadra = opcoes.quadra ? 1 : 0
        op.bloco_seg = blocoSegundos

        let nomesEtapa = ["Lendo o áudio", "Separando voz e trilha", "Tirando o eco", "Montando os arquivos"]
        // onde rodar os modelos: "gpu" (padrão: Core ML em float32, conferido com o processador)
        // ou "cpu" (ONNX Runtime). O Neural Engine saiu: derrubava o app e calcula com menos precisão.
        let acel = UserDefaults.standard.string(forKey: "vozAcelerador") == "cpu" ? "cpu" : "gpu"
        if acel == "gpu" && !ModelosCoreML.prontos {
            Diagnostico.log("preparando os modelos da GPU")
            try await ModelosCoreML.preparar(progresso: progresso)
        }
        let neural: Int32 = acel == "ane" ? 1 : 0
        if acel != "cpu" { UserDefaults.standard.set(true, forKey: chaveTentando); UserDefaults.standard.synchronize() }
        defer { UserDefaults.standard.set(false, forKey: chaveTentando) }
        Diagnostico.log("modelos rodando em: \(acel == "gpu" ? "GPU (Core ML)" : acel == "ane" ? "Neural Engine" : "processador")")
        let onnx0 = ModelosVoz.caminho(ModelosVoz.arquivos[0].nome).path, onnx1 = ModelosVoz.caminho(ModelosVoz.arquivos[1].nome).path
        let host = HostVoz(ort: mv_ort_abrir(onnx0, onnx1, neural),
                           coreml: acel == "gpu" ? MotorCoreML(unidades: .cpuAndGPU) : nil) { etapa, f in
            progresso(nomesEtapa[Int(max(0, min(3, etapa)))], f)
        }
        host.caminhosONNX = (onnx0, onnx1)
        let caminhos = [entrada.path, tmp.path, pasta.appendingPathComponent(nVoz).path,
                        pasta.appendingPathComponent(nTri).path, pasta.appendingPathComponent(nMix).path]
        let opC = op

        Diagnostico.log("motor aberto: \(host.ort == nil ? "falhou" : "ok"); começando")
        // o motor roda numa thread própria com pilha de 16 MB: as threads das Tasks do Swift
        // têm só 512 KB, pouco para o ONNX Runtime
        let (r, msg): (Int32, String) = await withTaskCancellationHandler {
            await withCheckedContinuation { (cont: CheckedContinuation<(Int32, String), Never>) in
                let t = Thread {
                    var erro = [CChar](repeating: 0, count: 512)
                    let ctx = Unmanaged.passUnretained(host).toOpaque()
                    let h = MVHost(inferir: cInferir, progresso: cProgresso, cancelado: cCancelado, ctx: ctx)
                    let c = caminhos.map { strdup($0) }
                    let r = mv_tratar(c[0], c[1], c[2], separar ? c[3] : nil, separar ? c[4] : nil,
                                      nil, opC, h, &erro, Int32(erro.count))
                    c.forEach { free($0) }
                    withExtendedLifetime(host) {}
                    cont.resume(returning: (r, String(cString: erro)))
                }
                t.stackSize = 16 << 20
                t.qualityOfService = .userInitiated
                t.start()
            }
        } onCancel: {
            host.cancelado = true
        }
        let ne = mv_ort_neural_ativo(host.ort)
        func onde(_ i: Int) -> String {
            host.coreml != nil && host.usarCoreML[i] ? "GPU" : (ne & Int32(1 << i)) != 0 ? "Neural Engine" : "processador"
        }
        Diagnostico.log("fim: r=\(r) \(msg) · separação: \(onde(0)), eco: \(onde(1))")
        if r == 1 { throw CancellationError() }
        if r != 0 {
            for n in [nVoz, nTri, nMix] { try? FileManager.default.removeItem(at: pasta.appendingPathComponent(n)) }
            if r == -3 {
                throw ErroApp("O modelo de voz falhou: \(host.erroModelo ?? msg). Se repetir, apague os modelos em Ajustes para baixá-los de novo.")
            }
            throw ErroApp("Tratamento de voz falhou: \(msg)")
        }
        return (separar ? [nMix, nVoz, nTri] : [nVoz], Double(quadros) / 44100)
    }
}

// MARK: - leitura do áudio

enum LeitorAudio {
    /// Decodifica qualquer áudio/vídeo para float32 intercalado estéreo 44,1 kHz (como o
    /// `ffmpeg -ar 44100 -ac 2` do motor): mono vira estéreo com ganho 0,7071 em cada lado.
    /// Devolve o número de quadros.
    static func lerEstereo441(_ url: URL, para destino: URL) async throws -> Int {
        let asset = AVURLAsset(url: url)
        guard let trilha = try await asset.loadTracks(withMediaType: .audio).first else {
            throw ErroApp("O arquivo não tem áudio.")
        }
        let fmts = try await trilha.load(.formatDescriptions)
        var canaisFonte = 2, taxaFonte = 44100.0
        if let f = fmts.first, let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(f)?.pointee {
            canaisFonte = Int(asbd.mChannelsPerFrame)
            taxaFonte = asbd.mSampleRate > 0 ? asbd.mSampleRate : 44100
        }
        let canaisLidos = canaisFonte == 1 ? 1 : 2
        Diagnostico.log("fonte: \(canaisFonte) canal(is), \(Int(taxaFonte)) Hz")
        let leitor = try AVAssetReader(asset: asset)
        let saida = AVAssetReaderTrackOutput(track: trilha, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
            AVNumberOfChannelsKey: canaisLidos,
            AVSampleRateKey: taxaFonte,
        ])
        saida.alwaysCopiesSampleData = false
        leitor.add(saida)
        guard leitor.startReading() else { throw leitor.error ?? ErroApp("Não consegui ler o áudio.") }

        FileManager.default.createFile(atPath: destino.path, contents: nil)
        let fh = try FileHandle(forWritingTo: destino)
        defer { try? fh.close() }

        let fmtFonte = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: taxaFonte, channels: 2, interleaved: true)!
        let fmt441 = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 44100, channels: 2, interleaved: true)!
        // conversão de taxa só se precisar, com a melhor qualidade do iOS
        let conversor: AVAudioConverter? = taxaFonte == 44100 ? nil : {
            let c = AVAudioConverter(from: fmtFonte, to: fmt441)!
            c.sampleRateConverterQuality = AVAudioQuality.max.rawValue
            c.sampleRateConverterAlgorithm = AVSampleRateConverterAlgorithm_Mastering
            return c
        }()
        var total = 0
        var fim = false

        func gravar(_ b: AVAudioPCMBuffer) {
            let n = Int(b.frameLength)
            guard n > 0 else { return }
            fh.write(Data(bytes: b.floatChannelData![0], count: n * 8))
            total += n
        }

        /// próximo pedaço da fonte, já em estéreo
        func proximo() throws -> AVAudioPCMBuffer? {
            while true {
                if Task.isCancelled { leitor.cancelReading(); throw CancellationError() }
                guard let sb = saida.copyNextSampleBuffer() else {
                    if leitor.status == .failed { throw leitor.error ?? ErroApp("Falha ao ler o áudio.") }
                    return nil
                }
                let n = CMSampleBufferGetNumSamples(sb)
                guard n > 0, let bloco = CMSampleBufferGetDataBuffer(sb) else { continue }
                let buf = AVAudioPCMBuffer(pcmFormat: fmtFonte, frameCapacity: AVAudioFrameCount(n))!
                buf.frameLength = AVAudioFrameCount(n)
                let dst = buf.floatChannelData![0]
                if canaisLidos == 1 {
                    var mono = [Float](repeating: 0, count: n)
                    CMBlockBufferCopyDataBytes(bloco, atOffset: 0, dataLength: n * 4, destination: &mono)
                    for i in 0..<n { let v = mono[i] * 0.70710677; dst[2 * i] = v; dst[2 * i + 1] = v }
                } else {
                    CMBlockBufferCopyDataBytes(bloco, atOffset: 0, dataLength: n * 8, destination: dst)
                }
                return buf
            }
        }

        if let conversor {
            let saidaBuf = AVAudioPCMBuffer(pcmFormat: fmt441, frameCapacity: 16384)!
            while true {
                var erro: NSError?
                var falha: Error?
                let st = conversor.convert(to: saidaBuf, error: &erro) { _, status in
                    if fim { status.pointee = .endOfStream; return nil }
                    do {
                        if let b = try proximo() { status.pointee = .haveData; return b }
                    } catch { falha = error }
                    fim = true
                    status.pointee = .endOfStream
                    return nil
                }
                if let falha { throw falha }
                if st == .error { throw erro ?? ErroApp("Falha ao converter a taxa do áudio.") }
                gravar(saidaBuf)
                if st == .endOfStream { break }
            }
        } else {
            while let b = try proximo() { gravar(b) }
        }
        if leitor.status == .failed { throw leitor.error ?? ErroApp("Falha ao ler o áudio.") }
        guard total >= 22050 else { throw ErroApp("Áudio curto demais (menos de meio segundo).") }
        return total
    }
}
