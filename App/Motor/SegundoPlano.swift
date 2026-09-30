import Foundation
import BackgroundTasks
import UserNotifications

/// Se o app está à vista. Lido pela thread do motor de voz (por isso a trava), atualizado pela tela.
final class EstadoApp: @unchecked Sendable {
    static let shared = EstadoApp()
    private let cond = NSCondition()
    private var _ativo = true
    private var _geracao = 0          // soma 1 cada vez que o app sai da tela

    var ativo: Bool { cond.lock(); defer { cond.unlock() }; return _ativo }
    var geracao: Int { cond.lock(); defer { cond.unlock() }; return _geracao }

    func mudar(ativo: Bool) {
        cond.lock()
        if !ativo && _ativo { _geracao += 1 }
        _ativo = ativo
        cond.broadcast()
        cond.unlock()
    }

    /// Bloqueia a thread (do motor) até o app voltar para a tela.
    func esperarAtivo() {
        cond.lock()
        while !_ativo { cond.wait() }
        cond.unlock()
    }

    /// Versão para código assíncrono.
    func aguardarAtivo() async {
        while !ativo { try? await Task.sleep(nanoseconds: 300_000_000) }
    }
}

/// Pasta onde ficam a entrada e os arquivos intermediários de um trabalho até ele terminar
/// (Application Support/Trabalhos/<id>, fora do backup). É o que permite continuar depois.
enum Trabalhos {
    static var raiz: URL {
        var u = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Trabalhos", isDirectory: true)
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        var v = URLResourceValues(); v.isExcludedFromBackup = true
        try? u.setResourceValues(v)
        return u
    }
    static func pasta(_ id: UUID) -> URL { raiz.appendingPathComponent(id.uuidString, isDirectory: true) }
    static func entradas(_ id: UUID) -> URL { pasta(id).appendingPathComponent("entrada", isDirectory: true) }
    static func existe(_ id: UUID) -> Bool { FileManager.default.fileExists(atPath: entradas(id).path) }
    static func apagar(_ id: UUID) { try? FileManager.default.removeItem(at: pasta(id)) }

    /// Move os arquivos recebidos para a pasta do trabalho. Devolve os nomes lá dentro.
    static func guardar(_ id: UUID, _ arquivos: [URL]) throws -> [String] {
        let dest = entradas(id)
        try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
        return try arquivos.map { u in
            let alvo = Nuvem.semColisao(dest.appendingPathComponent(u.lastPathComponent))
            do { try FileManager.default.moveItem(at: u, to: alvo) }
            catch { try FileManager.default.copyItem(at: u, to: alvo) }
            return alvo.lastPathComponent
        }
    }
}

/// Tarefa contínua do iOS 26: o trabalho segue com o app fora da tela, com o progresso numa
/// Atividade ao Vivo. Só para o que não usa a GPU (no iPhone ela não roda em segundo plano).
@MainActor
final class SegundoPlano {
    static let shared = SegundoPlano()
    private var tarefas: [UUID: BGContinuedProcessingTask] = [:]
    private var ultimoAviso: [UUID: Double] = [:]

    /// Prefixo aceito, lido do Info.plist (o AltStore muda o bundle id, mas não esta lista).
    private var prefixo: String? {
        let lista = Bundle.main.object(forInfoDictionaryKey: "BGTaskSchedulerPermittedIdentifiers") as? [String] ?? []
        guard let curinga = lista.first(where: { $0.hasSuffix(".*") }) else { return nil }
        return String(curinga.dropLast(1))
    }

    func iniciar(_ id: UUID, titulo: String, aoExpirar: @escaping @MainActor () -> Void) {
        guard let prefixo else { return }
        let ident = prefixo + id.uuidString
        let ok = BGTaskScheduler.shared.register(forTaskWithIdentifier: ident, using: .main) { [weak self] task in
            guard let t = task as? BGContinuedProcessingTask else { task.setTaskCompleted(success: false); return }
            MainActor.assumeIsolated {
                t.progress.totalUnitCount = 1000
                t.expirationHandler = {
                    Task { @MainActor in
                        self?.tarefas[id] = nil
                        aoExpirar()
                        t.setTaskCompleted(success: false)
                    }
                }
                self?.tarefas[id] = t
            }
        }
        guard ok else { return }
        let req = BGContinuedProcessingTaskRequest(identifier: ident, title: titulo, subtitle: "Começando…")
        req.strategy = .fail
        do { try BGTaskScheduler.shared.submit(req) }
        catch { Diagnostico.log("segundo plano recusado: \(error.localizedDescription)") }
    }

    func progresso(_ id: UUID, _ p: Double?, _ msg: String) {
        guard let t = tarefas[id] else { return }
        if let p {
            t.progress.completedUnitCount = Int64(max(0, min(1, p)) * 1000)
        }
        // o subtítulo não precisa mudar a cada quadro
        let agora = Date().timeIntervalSince1970
        if agora - (ultimoAviso[id] ?? 0) > 1 {
            ultimoAviso[id] = agora
            t.updateTitle(t.title, subtitle: msg)
        }
    }

    func terminar(_ id: UUID, ok: Bool) {
        guard let t = tarefas.removeValue(forKey: id) else { return }
        ultimoAviso[id] = nil
        t.progress.completedUnitCount = t.progress.totalUnitCount
        t.setTaskCompleted(success: ok)
    }
}

/// Notificação local ("volte ao Estúdio").
enum Notificacoes {
    static func pedirPermissao() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    static func avisar(_ titulo: String, _ corpo: String) {
        let c = UNMutableNotificationContent()
        c.title = titulo
        c.body = corpo
        c.sound = .default
        let req = UNNotificationRequest(identifier: "estudio-pausa", content: c, trigger: nil)
        UNUserNotificationCenter.current().add(req)
    }

    static func limpar() {
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: ["estudio-pausa"])
    }
}
