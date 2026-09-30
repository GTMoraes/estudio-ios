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
                            Button("1×") { zoom = 1; desloc = .zero }.buttonStyle(.glass).font(.footnote)
                        }
                    }
                    Text("Zoom só na prévia (o resultado não muda): pinça em qualquer lugar ou os botões. Um dedo na moldura move a seleção; fora dela move o vídeo. Toque duplo: ver a seleção / 1×.")
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
            .interactiveDismissDisabled()        // arrastar a moldura para baixo não fecha a folha
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
        let caixa = retanguloSelecao(q)
        ZStack(alignment: .topLeading) {
            // tamanho fixo + escala/deslocamento: a GPU só transforma a textura (nada de
            // redesenhar um quadro 4K ampliado 8× a cada passo). Mesma posição de `q`.
            Image(uiImage: img).resizable()
                .interpolation(zoom > 2 ? .none : .high)       // no zoom forte, mostra os pixels de verdade
                .frame(width: q0.width, height: q0.height)
                .scaleEffect(zoom)
                .offset(desloc)
                .position(x: q0.midX, y: q0.midY)
            Path { p in p.addRect(q); p.addRect(caixa) }
                .fill(Color.black.opacity(0.6), style: FillStyle(eoFill: true))
            Rectangle().stroke(Color.white, lineWidth: 2)
                .frame(width: caixa.width, height: caixa.height)
                .position(x: caixa.midX, y: caixa.midY)
            ForEach(0..<4, id: \.self) { k in
                let sx = k % 2, sy = k / 2
                Circle().fill(Color.white).frame(width: 22, height: 22)
                    .overlay(Circle().stroke(Tema.acento, lineWidth: 2))
                    .position(x: sx == 0 ? caixa.minX : caixa.maxX, y: sy == 0 ? caixa.minY : caixa.maxY)
            }
        }
        .allowsHitTesting(false)
        // todos os toques da área passam por gestos do UIKit: pinça em qualquer lugar (inclusive
        // dentro da moldura), um dedo move a moldura, os cantos redimensionam, fora dela move o vídeo
        .overlay {
            CamadaGestos(
                aoArrastar: { fase, ponto, desloc in arrastar(fase, ponto, desloc) },
                aoPincar: { fase, escala, centro in pincar(fase, escala, centro) },
                aoTocarDuas: { if zoom > 1.001 { zoom = 1; desloc = .zero } else { focarSelecao() } })
        }
        .onAppear { areaAtual = area }
        .onChange(of: area) { _, n in areaAtual = n }
    }

    private func retanguloSelecao(_ q: CGRect) -> CGRect {
        let r = e.recorte
        return CGRect(x: q.minX + CGFloat(r.x) * q.width, y: q.minY + CGFloat(r.y) * q.height,
                      width: CGFloat(r.largura) * q.width, height: CGFloat(r.altura) * q.height)
    }

    // MARK: gestos (UIKit)

    private enum Alvo { case mover, canto(Int, Int), video }
    @State private var alvo: Alvo?
    @State private var ancoraPinca: CGPoint = .zero

    private func arrastar(_ fase: UIGestureRecognizer.State, _ ponto: CGPoint, _ t: CGSize) {
        guard let q0 = ultimoQ0 else { return }
        let q = retanguloZoom(q0)
        switch fase {
        case .began:
            let caixa = retanguloSelecao(q)
            // o ponto onde o dedo encostou (o UIKit só começa depois de alguns pontos de movimento)
            let p0 = CGPoint(x: ponto.x - t.width, y: ponto.y - t.height)
            let raio: CGFloat = 30
            var achou: Alvo?
            for k in 0..<4 {
                let sx = k % 2, sy = k / 2
                let c = CGPoint(x: sx == 0 ? caixa.minX : caixa.maxX, y: sy == 0 ? caixa.minY : caixa.maxY)
                if hypot(p0.x - c.x, p0.y - c.y) <= raio { achou = .canto(sx, sy); break }
            }
            alvo = achou ?? (caixa.contains(p0) ? .mover : .video)
            inicio = e.recorte
            deslocInicio = desloc
            fallthrough
        case .changed:
            guard let b = inicio else { return }
            switch alvo {
            case .mover?:
                e.recorte.x = min(max(0, b.x + Double(t.width / q.width)), 1 - b.largura)
                e.recorte.y = min(max(0, b.y + Double(t.height / q.height)), 1 - b.altura)
            case .canto(let sx, let sy)?:
                redimensionar(b, sx: sx, sy: sy, dx: Double(t.width / q.width), dy: Double(t.height / q.height))
            case .video?:
                let d = deslocInicio ?? .zero
                desloc = limitar(CGSize(width: d.width + t.width, height: d.height + t.height), q0, zoom)
            case nil: break
            }
        default:
            alvo = nil; inicio = nil; deslocInicio = nil
        }
    }

    private func pincar(_ fase: UIGestureRecognizer.State, _ escala: CGFloat, _ centro: CGPoint) {
        guard let q0 = ultimoQ0 else { return }
        switch fase {
        case .began:
            zoomInicio = zoom; deslocInicio = desloc; ancoraPinca = centro
            fallthrough
        case .changed:
            let z0 = zoomInicio ?? zoom, d0 = deslocInicio ?? desloc
            let z = min(max(1, z0 * escala), zoomMax)
            // o ponto que estava sob os dedos no começo segue os dedos (zoom + mover com dois dedos)
            let c = CGPoint(x: q0.midX + d0.width, y: q0.midY + d0.height)
            let f = z / max(z0, 0.01)
            let c2 = CGPoint(x: centro.x + (c.x - ancoraPinca.x) * f, y: centro.y + (c.y - ancoraPinca.y) * f)
            zoom = z
            desloc = limitar(CGSize(width: c2.x - q0.midX, height: c2.y - q0.midY), q0, z)
        default:
            zoomInicio = nil; deslocInicio = nil
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
        let z = min(max(1, novo), zoomMax)
        let f = z / zoom
        zoom = z
        desloc = CGSize(width: desloc.width * f, height: desloc.height * f)
        if let q0 = ultimoQ0 { desloc = limitar(desloc, q0, z) }
    }

    /// Enquadra a seleção na prévia (ocupando ~70% da área).
    private func focarSelecao() {
        guard let q0 = ultimoQ0 else { return }
        let r = e.recorte
        let z = min(zoomMax, max(1, 0.7 / max(CGFloat(r.largura), CGFloat(r.altura))))
        // centro da seleção em coordenadas da imagem sem zoom (relativo ao centro)
        let cx = (CGFloat(r.x + r.largura / 2) - 0.5) * q0.width
        let cy = (CGFloat(r.y + r.altura / 2) - 0.5) * q0.height
        zoom = z
        desloc = limitar(CGSize(width: -cx * z, height: -cy * z), q0, z)
    }

    @State private var areaAtual: CGSize = .zero
    private var ultimoQ0: CGRect? { areaAtual == .zero ? nil : encaixe(aspectoVideo, em: areaAtual) }

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


/// Camada transparente com gestos do UIKit: um dedo (arrastar), dois (pinça) e toque duplo,
/// reconhecidos juntos e sem atraso (os do SwiftUI seguravam o arrastar até soltar o dedo).
struct CamadaGestos: UIViewRepresentable {
    var aoArrastar: (UIGestureRecognizer.State, CGPoint, CGSize) -> Void
    var aoPincar: (UIGestureRecognizer.State, CGFloat, CGPoint) -> Void
    var aoTocarDuas: () -> Void

    func makeCoordinator() -> Coordenador { Coordenador() }

    func makeUIView(context: Context) -> UIView {
        let v = UIView()
        v.backgroundColor = .clear
        let c = context.coordinator
        let arrasto = UIPanGestureRecognizer(target: c, action: #selector(Coordenador.arrastou(_:)))
        arrasto.maximumNumberOfTouches = 1
        arrasto.delegate = c
        let pinca = UIPinchGestureRecognizer(target: c, action: #selector(Coordenador.pincou(_:)))
        pinca.delegate = c
        let duplo = UITapGestureRecognizer(target: c, action: #selector(Coordenador.tocou(_:)))
        duplo.numberOfTapsRequired = 2
        v.addGestureRecognizer(arrasto)
        v.addGestureRecognizer(pinca)
        v.addGestureRecognizer(duplo)
        c.arrasto = arrasto
        return v
    }

    func updateUIView(_ v: UIView, context: Context) {
        context.coordinator.pai = self
    }

    final class Coordenador: NSObject, UIGestureRecognizerDelegate {
        var pai: CamadaGestos?
        weak var arrasto: UIPanGestureRecognizer?

        @objc func arrastou(_ g: UIPanGestureRecognizer) {
            guard let v = g.view else { return }
            let t = g.translation(in: v)
            pai?.aoArrastar(g.state, g.location(in: v), CGSize(width: t.x, height: t.y))
        }

        @objc func pincou(_ g: UIPinchGestureRecognizer) {
            guard let v = g.view else { return }
            if g.state == .began, let a = arrasto, a.state == .began || a.state == .changed {
                // o segundo dedo chegou: cancela o arrastar de um dedo (a moldura não anda junto com o zoom)
                a.isEnabled = false; a.isEnabled = true
            }
            pai?.aoPincar(g.state, g.scale, g.location(in: v))
        }

        @objc func tocou(_ g: UITapGestureRecognizer) {
            if g.state == .ended { pai?.aoTocarDuas() }
        }

        func gestureRecognizer(_ g: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith outro: UIGestureRecognizer) -> Bool {
            true
        }
    }
}
