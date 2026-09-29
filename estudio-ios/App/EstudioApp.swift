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
                    if nova == .active { estudio.lerCaixa() }
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
        .alert("Aviso", isPresented: Binding(get: { estudio.aviso != nil }, set: { if !$0 { estudio.aviso = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(estudio.aviso ?? "")
        }
    }
}
