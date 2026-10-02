import SwiftUI

enum Tema {
    static let acento = Color(red: 0.851, green: 0.467, blue: 0.341)      // #D97757
    static let fundo = Color(red: 0.118, green: 0.114, blue: 0.110)       // #1E1D1C
    static let fundo2 = Color(red: 0.165, green: 0.157, blue: 0.149)      // #2A2826
    static let texto2 = Color(white: 0.70)

    /// Fundo escuro com um brilho quente discreto, para o vidro ter o que refletir.
    static var gradiente: some View {
        ZStack {
            fundo
            RadialGradient(colors: [acento.opacity(0.22), .clear], center: .topTrailing, startRadius: 10, endRadius: 520)
            RadialGradient(colors: [Color(red: 0.35, green: 0.30, blue: 0.55).opacity(0.14), .clear],
                           center: .bottomLeading, startRadius: 10, endRadius: 480)
        }
        .ignoresSafeArea()
    }
}

/// Cartão de vidro usado em todas as telas.
struct Cartao<Conteudo: View>: View {
    var titulo: String?
    var icone: String?
    @ViewBuilder var conteudo: Conteudo

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let titulo {
                Label(titulo, systemImage: icone ?? "circle")
                    .labelStyle(.titleAndIcon)
                    .font(.headline)
                    .foregroundStyle(.primary)
            }
            conteudo
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(.regular, in: .rect(cornerRadius: 24))
    }
}

/// Botão principal, laranja.
struct BotaoPrincipal: View {
    var titulo: String
    var icone: String
    var desativado = false
    var acao: () -> Void

    var body: some View {
        Button(action: acao) {
            Label(titulo, systemImage: icone)
                .font(.body.weight(.semibold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
        }
        .buttonStyle(.glassProminent)
        .tint(Tema.acento)
        .disabled(desativado)
    }
}

extension View {
    func telaEscura() -> some View {
        self.scrollContentBackground(.hidden)
            .background(Tema.gradiente)
    }
}

/// Pergunta antes de apagar. Uso: `confirmar = Confirmacao(titulo: "Apagar …?") { … }` e
/// `.confirmar($confirmar)` num contêiner da tela (não num botão de vidro).
struct Confirmacao: Identifiable {
    let id = UUID()
    var titulo: String
    var mensagem = "Isso não pode ser desfeito."
    var botao = "Apagar"
    var destrutivo = true
    var acao: () -> Void
}

extension View {
    func confirmar(_ c: Binding<Confirmacao?>) -> some View {
        alert(c.wrappedValue?.titulo ?? "Tem certeza?",
              isPresented: Binding(get: { c.wrappedValue != nil }, set: { if !$0 { c.wrappedValue = nil } }),
              presenting: c.wrappedValue) { x in
            if x.destrutivo { Button(x.botao, role: .destructive) { x.acao() } }
            else { Button(x.botao) { x.acao() } }
            Button("Cancelar", role: .cancel) {}
        } message: { x in
            Text(x.mensagem)
        }
    }
}

func formatarDuracao(_ s: Double?) -> String? {
    guard let s, s.isFinite, s > 0 else { return nil }
    let t = Int(s.rounded())
    if t >= 3600 { return String(format: "%d h %02d min", t / 3600, t % 3600 / 60) }
    if t >= 60 { return String(format: "%d min %02d s", t / 60, t % 60) }
    return "\(t) s"
}
