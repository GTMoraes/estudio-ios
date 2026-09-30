import SwiftUI
import AVFoundation

/// Editor do enquadramento do vídeo: preencher (recorte no formato), caber (barras pretas),
/// desfocado (fundo com o próprio vídeo) ou livre (qualquer retângulo). Ajustado sobre um quadro
/// escolhido na barra de tempo; vale para o vídeo inteiro.
struct EditorEnquadramento: View {
    let arquivo: URL
    let info: InfoMidia
    @Binding var enquadramento: Enquadramento?
    @Environment(\.dismiss) private var fechar

    @State private var e = Enquadramento()
    @State private var quadro: UIImage?
    @State private var tempo: Double = 0
    @State private var inicio: Recorte?
    // zoom só da prévia (o resultado não muda): ver detalhes para ajustar o recorte
    @State private var zoom: CGFloat = 1
    @State private var desloc: CGSize = .zero
    @State private var zoomInicio: CGFloat?
    @State private var deslocInicio: CGSize?
    private let zoomMax: CGFloat = 8

    private let minimo = 0.05
    private var W: Double { Double(max(info.largura, 2)) }
    private var H: Double { Double(max(info.altura, 2)) }
    private var aspectoVideo: Double { W / H }

    var body: some View {
        NavigationStack {
            VStack(spacing: 14) {
                Picker("Modo", selection: Binding(get: { e.modo }, set: { mudarModo($0) })) {
                    ForEach(Enquadramento.Modo.allCases) { Text($0.nome).tag($0) }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal)

                if e.modo != .livre {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(Enquadramento.proporcoes, id: \.nome) { p in
                                Button(p.nome) { mudarProporcao(p.valor) }
                                    .buttonStyle(.glass)
                                    .tint(abs(e.proporcao - p.valor) < 0.001 ? Tema.acento : .primary)
                            }
                        }
                        .padding(.horizontal)
                    }
                }

                GeometryReader { geo in
                    if let quadro {
                        switch e.modo {
                        case .preencher, .livre: areaRecorte(quadro, geo.size)
                        case .caber, .desfocar: previaEncaixe(quadro, geo.size)
                        }
                    } else {
                        ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
                .clipped()
                // o recorte só recebe toques dentro da área: a imagem ampliada ou desfocada
                // (scaledToFill) passava por cima dos botões e engolia os toques
                .contentShape(Rectangle())
                .padding(.horizontal)

                if e.modo == .preencher || e.modo == .livre {
                    HStack(spacing: 10) {
                        Button { mudarZoom(zoom / 1.5) } label: { Image(systemName: "minus.magnifyingglass") }
                            .buttonStyle(.glass).disabled(zoom <= 1.001)
                        Text(String(format: "%.1f×", zoom).replacingOccurrences(of: ".", with: ","))
                            .font(.footnote.monospacedDigit()).frame(width: 44)
                        Button { mudarZoom(zoom * 1.5) } label: { Image(systemName: "plus.magnifyingglass") }
                            .buttonStyle(.glass).disabled(zoom >= zoomMax - 0.001)
                        Button("Ver a seleção") { focarSelecao() }.buttonStyle(.glass).font(.footnote)
                        if zoom > 1.001 {
                            Button("1×") { withAnimation(.snappy) { zoom = 1; desloc = .zero } }.buttonStyle(.glass).font(.footnote)
                        }
                    }
                    Text("Pinça ou botões para dar zoom na prévia; arraste fora da moldura para mover. O resultado não muda.")
                        .font(.caption).foregroundStyle(Tema.texto2).padding(.horizontal)
                }

                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Quadro para ajustar").font(.footnote)
                        Spacer()
                        Text(Legenda.tempo(tempo).replacingOccurrences(of: ",", with: "."))
                            .font(.footnote.monospacedDigit()).foregroundStyle(Tema.texto2)
                    }
                    Slider(value: $tempo, in: 0...max(info.duracao, 0.1))
                    Text(e.modo.dica).font(.caption).foregroundStyle(Tema.texto2)
                    Text("O enquadramento vale para o vídeo inteiro.").font(.caption).foregroundStyle(Tema.texto2)
                }
                .padding(.horizontal)
            }
            .padding(.vertical)
            .telaEscura()
            .navigationTitle("Enquadramento")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancelar") { fechar() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("OK") { enquadramento = e; fechar() }
                }
            }
            .task(id: tempo) {
                // espera o dedo parar na barra antes de ler o quadro
                if quadro != nil { try? await Task.sleep(nanoseconds: 180_000_000) }
                if Task.isCancelled { return }
                await carregarQuadro()
            }
            .onAppear {
                if let atual = enquadramento { e = atual } else { e = Enquadramento(); mudarProporcao(0.8) }
            }
        }
    }

    private func carregarQuadro() async {
        let g = AVAssetImageGenerator(asset: AVURLAsset(url: arquivo))
        g.appliesPreferredTrackTransform = true
        g.maximumSize = .zero            // resolução cheia: o zoom da prévia mostra os pixels de verdade
        let tol = CMTime(seconds: 0.1, preferredTimescale: 600)
        g.requestedTimeToleranceBefore = tol
        g.requestedTimeToleranceAfter = tol
        if let r = try? await g.image(at: CMTime(seconds: tempo, preferredTimescale: 600)) {
            quadro = UIImage(cgImage: r.image)
        }
    }

    // MARK: modos e proporções

    private func mudarModo(_ m: Enquadramento.Modo) {
        e.modo = m
        if m == .preencher { mudarProporcao(e.proporcao) }
    }

    /// Ajusta o recorte para a proporção (em pixels), mantendo o centro e o maior tamanho possível.
    private func mudarProporcao(_ p: Double) {
        e.proporcao = p
        guard e.modo == .preencher || e.modo == .livre, p > 0 else { return }
        let r = e.recorte
        let cx = r.x + r.largura / 2, cy = r.y + r.altura / 2
        var lpx = W, apx = W / p
        if apx > H { apx = H; lpx = H * p }
        let nl = lpx / W, na = apx / H
        e.recorte = Recorte(x: min(max(0, cx - nl / 2), 1 - nl), y: min(max(0, cy - na / 2), 1 - na),
                            largura: nl, altura: na)
    }

    // MARK: prévia de caber / desfocado

    private func encaixe(_ aspecto: Double, em area: CGSize) -> CGRect {
        let a = CGFloat(aspecto)
        var w = area.width, h = w / a
        if h > area.height { h = area.height; w = h * a }
        return CGRect(x: (area.width - w) / 2, y: (area.height - h) / 2, width: w, height: h)
    }

    @ViewBuilder
    private func previaEncaixe(_ img: UIImage, _ area: CGSize) -> some View {
        let tela = encaixe(e.proporcao > 0 ? e.proporcao : aspectoVideo, em: area)
        ZStack {
            if e.modo == .desfocar {
                Image(uiImage: img).resizable().scaledToFill()
                    .frame(width: tela.width, height: tela.height)
                    .blur(radius: max(tela.width, tela.height) * 0.035)
                    .brightness(-0.12)
                    .clipped()
            } else {
                Color.black
            }
            Image(uiImage: img).resizable().scaledToFit()
                .frame(width: tela.width, height: tela.height)
        }
        .frame(width: tela.width, height: tela.height)
        .clipShape(.rect(cornerRadius: 6))
        .contentShape(Rectangle())
        .allowsHitTesting(false)
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(.white.opacity(0.5), lineWidth: 1))
        .position(x: tela.midX, y: tela.midY)
    }

    // MARK: recorte (preencher / livre)

    @ViewBuilder
    private func areaRecorte(_ img: UIImage, _ area: CGSize) -> some View {
        let q0 = encaixe(aspectoVideo, em: area)
        let q = retanguloZoom(q0)
        let r = e.recorte
        let caixa = CGRect(x: q.minX + CGFloat(r.x) * q.width, y: q.minY + CGFloat(r.y) * q.height,
                           width: CGFloat(r.largura) * q.width, height: CGFloat(r.altura) * q.height)
        ZStack(alignment: .topLeading) {
            Image(uiImage: img).resizable()
                .interpolation(zoom > 2 ? .none : .high)       // no zoom forte, mostra os pixels de verdade
                .frame(width: q.width, height: q.height)
                .position(x: q.midX, y: q.midY)
                .allowsHitTesting(false)
            // fundo: pinça para zoom e arrastar para mover a prévia (fora da moldura)
            Color.clear
                .contentShape(Rectangle())
                .frame(width: area.width, height: area.height)
                .position(x: area.width / 2, y: area.height / 2)
                .onAppear { areaAtual = area }
                .onChange(of: area) { _, n in areaAtual = n }
                .gesture(SimultaneousGesture(
                    gestoZoom(q0),
                    DragGesture(minimumDistance: 4)
                        .onChanged { g in
                            guard zoomInicio == nil else { return }
                            if deslocInicio == nil { deslocInicio = desloc }
                            let b = deslocInicio ?? .zero
                            desloc = limitar(CGSize(width: b.width + g.translation.width, height: b.height + g.translation.height), q0, zoom)
                        }
                        .onEnded { _ in deslocInicio = nil }))
                .onTapGesture(count: 2) { withAnimation(.snappy) { if zoom > 1.001 { zoom = 1; desloc = .zero } else { focarSelecao() } } }
            Path { p in p.addRect(q); p.addRect(caixa) }
                .fill(Color.black.opacity(0.6), style: FillStyle(eoFill: true))
                .allowsHitTesting(false)
            Rectangle().stroke(Color.white, lineWidth: 2)
                .frame(width: caixa.width, height: caixa.height)
                .contentShape(Rectangle())
                .position(x: caixa.midX, y: caixa.midY)
                .simultaneousGesture(gestoZoom(q0))
                .gesture(DragGesture()
                    .onChanged { g in
                        guard zoomInicio == nil else { inicio = nil; return }
                        if inicio == nil { inicio = e.recorte }
                        guard let b = inicio else { return }
                        e.recorte.x = min(max(0, b.x + Double(g.translation.width / q.width)), 1 - b.largura)
                        e.recorte.y = min(max(0, b.y + Double(g.translation.height / q.height)), 1 - b.altura)
                    }
                    .onEnded { _ in inicio = nil })
            ForEach(0..<4, id: \.self) { k in
                let sx = k % 2, sy = k / 2
                Circle().fill(Color.white).frame(width: 22, height: 22)
                    .overlay(Circle().stroke(Tema.acento, lineWidth: 2))
                    .frame(width: 44, height: 44).contentShape(Rectangle())
                    .position(x: sx == 0 ? caixa.minX : caixa.maxX, y: sy == 0 ? caixa.minY : caixa.maxY)
                    .gesture(DragGesture()
                        .onChanged { g in
                            if inicio == nil { inicio = e.recorte }
                            guard let b = inicio else { return }
                            redimensionar(b, sx: sx, sy: sy,
                                          dx: Double(g.translation.width / q.width), dy: Double(g.translation.height / q.height))
                        }
                        .onEnded { _ in inicio = nil })
            }
        }
    }

    // MARK: zoom da prévia

    /// Retângulo da imagem na tela com o zoom e o deslocamento atuais.
    private func retanguloZoom(_ q0: CGRect) -> CGRect {
        let w = q0.width * zoom, h = q0.height * zoom
        return CGRect(x: q0.midX - w / 2 + desloc.width, y: q0.midY - h / 2 + desloc.height, width: w, height: h)
    }

    /// Não deixa a imagem sair da área (sem faixas vazias ao mover).
    private func limitar(_ d: CGSize, _ q0: CGRect, _ z: CGFloat) -> CGSize {
        let mx = q0.width * (z - 1) / 2, my = q0.height * (z - 1) / 2
        return CGSize(width: min(max(d.width, -mx), mx), height: min(max(d.height, -my), my))
    }

    /// Zoom mantendo parado o ponto sob os dedos.
    private func aplicarZoom(_ novo: CGFloat, ancora: CGPoint, base q0: CGRect, zoomBase: CGFloat, deslocBase: CGSize) {
        let z = min(max(1, novo), zoomMax)
        let c = CGPoint(x: q0.midX + deslocBase.width, y: q0.midY + deslocBase.height)
        let f = z / max(zoomBase, 0.01)
        let c2 = CGPoint(x: ancora.x + (c.x - ancora.x) * f, y: ancora.y + (c.y - ancora.y) * f)
        zoom = z
        desloc = limitar(CGSize(width: c2.x - q0.midX, height: c2.y - q0.midY), q0, z)
    }

    /// Botões +/−: zoom pelo centro da prévia.
    private func mudarZoom(_ novo: CGFloat) {
        withAnimation(.snappy) {
            let z = min(max(1, novo), zoomMax)
            let f = z / zoom
            zoom = z
            desloc = CGSize(width: desloc.width * f, height: desloc.height * f)
            ultimoQ0.map { desloc = limitar(desloc, $0, z) }
        }
    }

    /// Enquadra a seleção na prévia (ocupando ~70% da área).
    private func focarSelecao() {
        guard let q0 = ultimoQ0 else { return }
        let r = e.recorte
        let z = min(zoomMax, max(1, 0.7 / max(CGFloat(r.largura), CGFloat(r.altura))))
        // centro da seleção em coordenadas da imagem sem zoom (relativo ao centro)
        let cx = (CGFloat(r.x + r.largura / 2) - 0.5) * q0.width
        let cy = (CGFloat(r.y + r.altura / 2) - 0.5) * q0.height
        withAnimation(.snappy) {
            zoom = z
            desloc = limitar(CGSize(width: -cx * z, height: -cy * z), q0, z)
        }
    }

    @State private var areaAtual: CGSize = .zero
    private var ultimoQ0: CGRect? { areaAtual == .zero ? nil : encaixe(aspectoVideo, em: areaAtual) }

    private func gestoZoom(_ q0: CGRect) -> some Gesture {
        MagnifyGesture()
            .onChanged { g in
                if zoomInicio == nil { zoomInicio = zoom; deslocInicio = desloc }
                aplicarZoom((zoomInicio ?? 1) * g.magnification, ancora: g.startLocation, base: q0,
                            zoomBase: zoomInicio ?? 1, deslocBase: deslocInicio ?? .zero)
            }
            .onEnded { _ in zoomInicio = nil; deslocInicio = nil }
    }

    private func redimensionar(_ b: Recorte, sx: Int, sy: Int, dx: Double, dy: Double) {
        var x0 = b.x, x1 = b.x + b.largura, y0 = b.y, y1 = b.y + b.altura
        if sx == 0 { x0 = min(max(0, x0 + dx), x1 - minimo) } else { x1 = max(min(1, x1 + dx), x0 + minimo) }
        if sy == 0 { y0 = min(max(0, y0 + dy), y1 - minimo) } else { y1 = max(min(1, y1 + dy), y0 + minimo) }
        let p = e.modo == .preencher ? e.proporcao : 0
        if p > 0 {
            // altura relativa que dá a proporção em pixels: (w·W)/(h·H) = p
            var w = x1 - x0
            var h = w * aspectoVideo / p
            let hMax = sy == 0 ? y1 : 1 - y0
            if h > hMax { h = hMax; w = h * p / aspectoVideo }
            let wMax = sx == 0 ? x1 : 1 - x0
            if w > wMax { w = wMax; h = w * aspectoVideo / p }
            if sx == 0 { x0 = x1 - w } else { x1 = x0 + w }
            if sy == 0 { y0 = y1 - h } else { y1 = y0 + h }
        }
        e.recorte = Recorte(x: x0, y: y0, largura: x1 - x0, altura: y1 - y0)
    }
}
