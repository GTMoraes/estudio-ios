import SwiftUI

/// Ajustes › "Corte automático": o modelo (CrisperWhisper) e as transcrições guardadas.
struct CartaoCorteAutomatico: View {
    @State private var baixa = BaixaCrisper.shared
    @State private var pronto = ModeloCrisper.pronto
    @State private var espacoModelo: Int64 = 0
    @State private var guardadas = 0
    @State private var espacoGuardadas: Int64 = 0
    @State private var confirmar: Confirmacao?

    var body: some View {
        Cartao(titulo: "Corte automático", icone: "scissors") {
            Label(pronto ? "Modelo pronto (CrisperWhisper)" : "Modelo ainda não está no iPhone (1,2 GB)",
                  systemImage: pronto ? "checkmark.circle.fill" : "arrow.down.circle")
                .foregroundStyle(pronto ? .green : Tema.texto2)
            Text("Roda na GPU do iPhone, sem internet. Cada uso começa carregando o modelo (cerca de 30 s). O modelo fica em “No meu iPhone › Estúdio › CrisperWhisper” e continua lá quando o app é atualizado.")
                .font(.footnote).foregroundStyle(Tema.texto2)
            if let p = baixa.progresso { ProgressView(value: p).tint(Tema.acento) }
            if let m = baixa.mensagem { Text(m).font(.footnote).foregroundStyle(Tema.texto2) }
            if baixa.baixando {
                Button("Pausar o download", role: .cancel) { baixa.cancelar() }.buttonStyle(.glass)
            } else if !pronto {
                BotaoPrincipal(titulo: "Baixar o modelo", icone: "arrow.down.circle.fill") { baixa.iniciar() }
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
                if pronto && !baixa.baixando {
                    Button("Apagar modelo", role: .destructive) {
                        confirmar = Confirmacao(titulo: "Apagar o modelo do corte automático?",
                                                mensagem: "Será preciso baixar 1,2 GB de novo para usar o corte automático.") {
                            ModeloCrisper.apagar(); atualizar()
                        }
                    }
                }
            }
            .font(.footnote)
            if espacoModelo > 0 {
                Text("Modelo: \(ByteCountFormatter.string(fromByteCount: espacoModelo, countStyle: .file))")
                    .font(.caption).foregroundStyle(Tema.texto2)
            }
        }
        .confirmar($confirmar)
        .onAppear { atualizar() }
        .onChange(of: baixa.baixando) { _, _ in atualizar() }
    }

    private func atualizar() {
        pronto = ModeloCrisper.pronto
        espacoModelo = ModeloCrisper.tamanhoEmDisco()
        guardadas = TranscricoesGuardadas.quantidade()
        espacoGuardadas = TranscricoesGuardadas.tamanhoEmDisco()
    }
}
