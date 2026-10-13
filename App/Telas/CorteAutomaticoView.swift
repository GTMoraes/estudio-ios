import SwiftUI

/// Ajustes › "Corte automático": o modelo (CrisperWhisper) e as transcrições guardadas.
struct CartaoCorteAutomatico: View {
    @State private var baixa = BaixaCrisper.shared
    @State private var pronto = ModeloCrisper.pronto
    @State private var alinhador = ModeloAlinhador.pronto
    @State private var espacoModelo: Int64 = 0
    @State private var guardadas = 0
    @State private var espacoGuardadas: Int64 = 0
    @State private var confirmar: Confirmacao?

    var body: some View {
        Cartao(titulo: "Corte automático", icone: "scissors") {
            Label(pronto ? "CrisperWhisper pronto (o que foi dito)" : "CrisperWhisper ainda não está no iPhone (1,2 GB)",
                  systemImage: pronto ? "checkmark.circle.fill" : "arrow.down.circle")
                .foregroundStyle(pronto ? .green : Tema.texto2)
            Label(alinhador ? "Alinhador pronto (onde cada palavra começa e termina)" : "Alinhador ainda não está no iPhone (1,2 GB)",
                  systemImage: alinhador ? "checkmark.circle.fill" : "arrow.down.circle")
                .foregroundStyle(alinhador ? .green : Tema.texto2)
            Text("Rodam na GPU do iPhone, sem internet. Sem o alinhador o corte funciona, mas pode comer começo e fim de palavra. Ficam em “No meu iPhone › Estúdio › CrisperWhisper” e “› Alinhador”, e continuam lá quando o app é atualizado. Cada corte grava um diagnóstico em “› CrisperWhisper-testes”.")
                .font(.footnote).foregroundStyle(Tema.texto2)
            if let p = baixa.progresso { ProgressView(value: p).tint(Tema.acento) }
            if let m = baixa.mensagem { Text(m).font(.footnote).foregroundStyle(Tema.texto2) }
            if baixa.baixando {
                Button("Pausar o download", role: .cancel) { baixa.cancelar() }.buttonStyle(.glass)
            } else if !pronto || !alinhador {
                BotaoPrincipal(titulo: "Baixar o que falta", icone: "arrow.down.circle.fill") { baixa.iniciar() }
            }
            Divider().overlay(Color.white.opacity(0.1))
            Text(guardadas == 0 ? "Nenhuma transcrição guardada."
                 : "\(guardadas) \(guardadas == 1 ? "transcrição guardada" : "transcrições guardadas") (\(ByteCountFormatter.string(fromByteCount: espacoGuardadas, countStyle: .file))): rodar o corte de novo no mesmo arquivo pula a transcrição.")
                .font(.footnote).foregroundStyle(Tema.texto2)
            HStack {
                if guardadas > 0 {
                    Button("Apagar transcrições guardadas", role: .destructive) {
                        confirmar = Confirmacao(titulo: "Apagar as transcrições guardadas?",
                                                mensagem: "O próximo corte de cada arquivo vai transcrever de novo.") {
                            TranscricoesGuardadas.apagarTudo(); atualizar()
                        }
                    }
                }
                Spacer()
                if (pronto || alinhador) && !baixa.baixando {
                    Button("Apagar modelos", role: .destructive) {
                        confirmar = Confirmacao(titulo: "Apagar os modelos do corte automático?",
                                                mensagem: "Será preciso baixar de novo (1,2 GB + 1,2 GB) para usar o corte automático.") {
                            ModeloCrisper.apagar(); ModeloAlinhador.apagar(); atualizar()
                        }
                    }
                }
            }
            .font(.footnote)
            if espacoModelo > 0 {
                Text("Modelos: \(ByteCountFormatter.string(fromByteCount: espacoModelo, countStyle: .file))")
                    .font(.caption).foregroundStyle(Tema.texto2)
            }
        }
        .confirmar($confirmar)
        .onAppear { atualizar() }
        .onChange(of: baixa.baixando) { _, _ in atualizar() }
    }

    private func atualizar() {
        pronto = ModeloCrisper.pronto
        alinhador = ModeloAlinhador.pronto
        espacoModelo = ModeloCrisper.tamanhoEmDisco() + ModeloAlinhador.tamanhoEmDisco()
        guardadas = TranscricoesGuardadas.quantidade()
        espacoGuardadas = TranscricoesGuardadas.tamanhoEmDisco()
    }
}
