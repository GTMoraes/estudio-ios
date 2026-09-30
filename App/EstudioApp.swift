import SwiftUI

@main
struct EstudioApp: App {
    @State private var estudio = Estudio()
    @Environment(\.scenePhase) private var fase

    var body: some Scene {
        WindowGroup {
            RaizView()
                .environment(estudio)
                .preferredColorScheme(.dark)
                .tint(Tema.acento)
                .onOpenURL { estudio.abrir($0) }
                .onAppear {
                    estudio.retomar()
                    estudio.lerCaixa()
                }
                .onChange(of: fase) { _, nova in
                    switch nova {
                    case .active: estudio.faseMudou(ativo: true); estudio.lerCaixa()
                    case .background: estudio.faseMudou(ativo: false)
                    default: break                 // .inactive (Central de Controle etc.): segue rodando
                    }
                }
        }
    }
}

struct RaizView: View {
    @Environment(Estudio.self) private var estudio

    var body: some View {
        @Bindable var e = estudio
        TabView(selection: $e.abaSelecionada) {
            Tab("Novo", systemImage: "plus.circle.fill", value: 0) {
                NovoView()
            }
            Tab("Resultados", systemImage: "tray.full.fill", value: 1) {
                ResultadosView()
            }
            Tab("Ajustes", systemImage: "gearshape.fill", value: 2) {
                AjustesView()
            }
        }
        .sheet(item: $e.entrada, onDismiss: { estudio.entradaConcluida() }) { entrada in
            ProcessarView(entrada: entrada)
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            if estudio.processandoLocal { AvisoProcessando() }
        }
        .alert("Aviso", isPresented: Binding(get: { estudio.aviso != nil }, set: { if !$0 { estudio.aviso = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(estudio.aviso ?? "")
        }
        .alert(estudio.interrompidos.count == 1 ? "1 trabalho foi interrompido" : "\(estudio.interrompidos.count) trabalhos foram interrompidos",
               isPresented: Binding(get: { !estudio.interrompidos.isEmpty && estudio.aviso == nil },
                                    set: { if !$0 { estudio.interrompidos = [] } })) {
            Button("Continuar") { estudio.continuarInterrompidos() }
            Button("Depois", role: .cancel) { estudio.interrompidos = [] }
        } message: {
            Text("O app foi fechado enquanto processava. Dá para continuar de onde parou (também pelo botão Continuar em Resultados).")
        }
    }
}

/// Faixa no topo enquanto algo é processado no iPhone.
struct AvisoProcessando: View {
    @Environment(Estudio.self) private var estudio

    private var soImagens: Bool {
        estudio.historico.itens.filter { !$0.naNuvem && $0.estado == .processando && estudio.rodando($0.id) }
            .allSatisfy { $0.tipo == .imagem }
    }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: soImagens ? "photo.stack" : "exclamationmark.triangle.fill")
                .foregroundStyle(soImagens ? Tema.acento : .yellow)
            VStack(alignment: .leading, spacing: 1) {
                Text(soImagens ? "Convertendo imagens" : "Processando no iPhone: não troque de app")
                    .font(.footnote.weight(.semibold))
                Text(soImagens ? "Pode sair: continua em segundo plano, com o progresso na tela bloqueada."
                               : "Fora do Estúdio o processamento pausa. A tela fica acesa até terminar.")
                    .font(.caption2).foregroundStyle(Tema.texto2)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14).padding(.vertical, 9)
        .glassEffect(.regular, in: .rect(cornerRadius: 18))
        .padding(.horizontal, 12)
        .padding(.bottom, 4)
    }
}
