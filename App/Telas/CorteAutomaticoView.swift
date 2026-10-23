import SwiftUI

/// Ajustes › "Corte automático": as transcrições guardadas (os modelos ficam em "Deixar o app pronto").
struct CartaoCorteAutomatico: View {
    @State private var pronto = ModeloCrisper.pronto
    @State private var alinhador = ModeloAlinhador.pronto
    @State private var guardadas = 0
    @State private var espacoGuardadas: Int64 = 0
    @State private var confirmar: Confirmacao?

    var body: some View {
        Cartao(titulo: "Corte automático", icone: "scissors") {
            Text("Usa o CrisperWhisper (o que foi dito) e o alinhador (onde cada palavra começa e termina), na GPU do iPhone, sem internet. Baixar, preparar e apagar os dois ficam em “Deixar o app pronto”, acima. Cada corte grava um diagnóstico em “No meu iPhone › Estúdio › CrisperWhisper-testes”.")
                .font(.footnote).foregroundStyle(Tema.texto2)
            Label(pronto && alinhador ? "Modelos no iPhone" : !pronto ? "Falta o CrisperWhisper" : "Falta o alinhador (o corte funciona, mas pode comer começo e fim de palavra)",
                  systemImage: pronto && alinhador ? "checkmark.circle.fill" : "arrow.down.circle")
                .font(.footnote)
                .foregroundStyle(pronto && alinhador ? .green : Tema.texto2)
            Divider().overlay(Color.white.opacity(0.1))
            Text(guardadas == 0 ? "Nenhuma transcrição guardada."
                 : "\(guardadas) \(guardadas == 1 ? "transcrição guardada" : "transcrições guardadas") (\(ByteCountFormatter.string(fromByteCount: espacoGuardadas, countStyle: .file))): rodar o corte de novo no mesmo arquivo pula a transcrição.")
                .font(.footnote).foregroundStyle(Tema.texto2)
            if guardadas > 0 {
                Button("Apagar transcrições guardadas", role: .destructive) {
                    confirmar = Confirmacao(titulo: "Tem certeza?",
                                            mensagem: "Apaga as transcrições guardadas. O próximo corte de cada arquivo vai transcrever de novo.") {
                        TranscricoesGuardadas.apagarTudo(); atualizar()
                    }
                }
                .font(.footnote)
            }
        }
        .confirmar($confirmar)
        .onAppear { atualizar() }
    }

    private func atualizar() {
        pronto = ModeloCrisper.pronto
        alinhador = ModeloAlinhador.pronto
        guardadas = TranscricoesGuardadas.quantidade()
        espacoGuardadas = TranscricoesGuardadas.tamanhoEmDisco()
    }
}
