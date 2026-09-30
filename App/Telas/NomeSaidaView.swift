import SwiftUI

/// Cartão "Nome de saída": padrão com tokens tocáveis e a prévia dos arquivos que vão sair.
struct CartaoNomeSaida: View {
    @Binding var padrao: String
    var tokens: [String] = ["{nome}", "{data}", "{datahora}"]
    var previa: [String]
    var nota: String?

    var body: some View {
        Cartao(titulo: "Nome de saída", icone: "character.cursor.ibeam") {
            HStack(spacing: 8) {
                TextField(Renomear.padrao, text: $padrao)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                    .padding(10).background(.white.opacity(0.06), in: .rect(cornerRadius: 12))
                if PadraoNome.personalizado(padrao) {
                    Button { padrao = Renomear.padrao } label: {
                        Image(systemName: "arrow.counterclockwise").frame(width: 22, height: 22)
                    }
                    .buttonStyle(.glass)
                }
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(tokens, id: \.self) { t in
                        Button(t) { padrao += t }
                            .font(.caption.monospaced())
                            .buttonStyle(.glass)
                    }
                }
            }
            ForEach(Array(previa.prefix(4).enumerated()), id: \.offset) { _, p in
                Text(p).font(.caption).foregroundStyle(Tema.texto2).lineLimit(1).truncationMode(.middle)
            }
            if previa.count > 4 { Text("…").font(.caption).foregroundStyle(Tema.texto2) }
            if let nota { Text(nota).font(.footnote).foregroundStyle(Tema.texto2) }
        }
    }
}
