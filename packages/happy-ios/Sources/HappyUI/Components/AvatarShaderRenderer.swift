#if canImport(UIKit)
import HappyLayout
import Metal
import QuartzCore
import UIKit

/// Settings › Appearance › Animated Avatars: the placeholders drawn as the
/// shaders they were made from, moving, instead of their still pictures.
/// Kept on this phone for every account; off unless turned on. Real pictures
/// are never covered.
@MainActor
public enum LiveAvatars {
    static let key = "live-avatars"

    public static var isEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: key) }
        set {
            guard newValue != isEnabled else { return }
            UserDefaults.standard.set(newValue, forKey: key)
            for slot in slots.allObjects { (slot as? AvatarPlaceholderSlot)?.updateLive() }
            AvatarShaderRenderer.shared?.redrawAll()
        }
    }

    /// Every slot that may wear a live placeholder, so turning it on or off
    /// reaches the ones already on screen.
    static let slots = NSHashTable<AnyObject>.weakObjects()
}

/// What a shader view draws: which placeholder, how (`ShaderLook`), how
/// fast and how large, and which part of what canvas.
struct ShaderDrawing: Equatable {
    var index = 0
    var monochrome = false
    var look = ShaderLook.avatar
    /// The clock's rate; nil, an avatar's for its size (`AvatarShader.speed`).
    var speed: Float?
    /// How much of the avatar the canvas spans: 1 all of it.
    var zoom: Float = 1
    /// Pixels per point; nil, the screen's.
    var resolution: Float?
    /// This view's frame in the canvas it is a window onto, in points; nil,
    /// it is its own canvas, as an avatar is.
    var canvas: (frame: CGRect, size: CGSize)?
    /// It moves only while Animated Avatars is on (a still frame otherwise),
    /// as the header's glass does; an avatar's own is only ever there with
    /// it on.
    var followsSetting = false

    static func == (a: Self, b: Self) -> Bool {
        a.index == b.index && a.monochrome == b.monochrome && a.look == b.look && a.speed == b.speed && a.zoom == b.zoom
            && a.resolution == b.resolution && a.canvas?.frame == b.canvas?.frame && a.canvas?.size == b.canvas?.size
            && a.followsSetting == b.followsSetting
    }
}

/// One placeholder as its live shader, filling the view it is put in (which
/// clips it). Hidden until its first frame, so the still picture under it
/// shows until then; that frame is the still picture's own, at its phase.
final class LiveAvatarView: UIView {
    override class var layerClass: AnyClass { CAMetalLayer.self }
    var metalLayer: CAMetalLayer { layer as! CAMetalLayer }

    private(set) var drawing = ShaderDrawing()
    var index: Int { drawing.index }
    var monochrome: Bool { drawing.monochrome }
    /// When this placeholder first showed; its clock runs from there.
    private(set) var started = CACurrentMediaTime()
    /// A frame of the current placeholder is on screen.
    var drawn = false
    /// Draws its first frame as soon as it is laid out, in that frame's
    /// transaction, rather than at the next tick: what is on screen from
    /// the first frame (the chat's header).
    var drawsOnLayout = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        isHidden = true
        autoresizingMask = [.flexibleWidth, .flexibleHeight]
        metalLayer.pixelFormat = .bgra8Unorm
        metalLayer.framebufferOnly = true
        metalLayer.isOpaque = false
        // A first frame is presented with its transaction, so a reused cell
        // never shows its last avatar under a new one (`draw`).
        metalLayer.presentsWithTransaction = true
        if let device = AvatarShaderRenderer.shared?.device { metalLayer.device = device }
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    func show(index: Int, monochrome: Bool) {
        var drawing = drawing
        drawing.index = index
        drawing.monochrome = monochrome
        draw(drawing)
    }

    func draw(_ drawing: ShaderDrawing) {
        guard drawing != self.drawing || !drawn else { return }
        if drawing.index != self.drawing.index { started = CACurrentMediaTime() }
        let restyled = drawing.index != self.drawing.index || drawing.monochrome != self.drawing.monochrome
        self.drawing = drawing
        drawn = false
        // A new placeholder waits for its frame; a new crop or look of the
        // same one keeps what it shows until the next.
        if restyled { isHidden = true }
        AvatarShaderRenderer.shared?.wake()
        if drawsOnLayout { setNeedsLayout() }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        if drawsOnLayout, !drawn { AvatarShaderRenderer.shared?.drawNow(self) }
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil { AvatarShaderRenderer.shared?.add(self) } else { AvatarShaderRenderer.shared?.remove(self) }
    }
}

/// The one pipeline every live placeholder draws with, compiled off the main
/// thread from `avatarShaderMetal`, and the display link that draws the ones
/// on screen: `AvatarShader.framesPerSecond` (they drift slowly), at most
/// 32 at once, largest first. With Reduce Motion or Low
/// Power Mode each holds one frame, and in the background nothing is drawn.
/// Nil without Metal.
@MainActor
final class AvatarShaderRenderer {
    static let shared = AvatarShaderRenderer()
    static let maxLive = 32
    /// `AvatarShader.framesPerSecond`, unless a harness compares another.
    static var framesPerSecond = AvatarShader.framesPerSecond
    /// The most pixels across a placeholder is drawn at.
    static let maxPixels = 512
    /// The most pixels along the longer side of anything else.
    static let maxCanvasPixels = 1024

    let device: MTLDevice
    private let queue: MTLCommandQueue
    private var pipeline: MTLRenderPipelineState?
    private var compiling: Task<MTLRenderPipelineState?, Never>?
    private let views = NSHashTable<LiveAvatarView>.weakObjects()
    private var link: CADisplayLink?
    private var background = false
    /// Frames put on screen so far, for tests.
    private(set) var presented = 0
    /// What drawing costs, for tests and the performance gym.
    private(set) var cost = Cost()

    struct Cost {
        /// Command buffers the GPU finished, and the time it spent on them.
        var buffers = 0
        var gpuSeconds: Double = 0
        var gpuMax: Double = 0
        /// Ticks that drew, and the main thread's time encoding them.
        var ticks = 0
        var cpuSeconds: Double = 0
        var cpuMax: Double = 0
        var gpuMean: Double { buffers == 0 ? 0 : gpuSeconds / Double(buffers) }
        var cpuMean: Double { ticks == 0 ? 0 : cpuSeconds / Double(ticks) }
    }

    func resetCost() { cost = Cost() }

    private init?() {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else { return nil }
        self.device = device
        self.queue = queue
        // Turning Reduce Motion or Low Power Mode on or off draws each
        // again, still or moving.
        for name in [UIAccessibility.reduceMotionStatusDidChangeNotification, Notification.Name.NSProcessInfoPowerStateDidChange] {
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { AvatarShaderRenderer.shared?.redrawAll() }
            }
        }
        // Nothing is drawn in the background.
        NotificationCenter.default.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { AvatarShaderRenderer.shared?.setBackground(true) }
        }
        NotificationCenter.default.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { AvatarShaderRenderer.shared?.setBackground(false) }
        }
    }

    /// Whether they move: not with Reduce Motion or in Low Power Mode.
    static var animates: Bool {
        !UIAccessibility.isReduceMotionEnabled && !ProcessInfo.processInfo.isLowPowerModeEnabled
    }

    func add(_ view: LiveAvatarView) {
        views.add(view)
        wake()
    }

    func remove(_ view: LiveAvatarView) {
        views.remove(view)
    }

    private func setBackground(_ background: Bool) {
        self.background = background
        link?.isPaused = background
    }

    /// Compiles the pipeline ahead of the first view, off the main thread,
    /// so the first header draws on its first frame.
    func warm() {
        if pipeline == nil { compile() }
    }

    /// Compiles the pipeline if it isn't, and runs the link while any
    /// placeholder is in a window.
    func wake() {
        guard views.count > 0 else { return }
        if pipeline == nil {
            compile()
            return
        }
        guard link == nil else { return }
        let link = CADisplayLink(target: Tick(self), selector: #selector(Tick.tick(_:)))
        let rate = Self.framesPerSecond
        link.preferredFrameRateRange = CAFrameRateRange(minimum: min(10, rate), maximum: max(30, rate), preferred: rate)
        link.isPaused = background
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    /// The pipeline, ready; compiled off the main thread on first use.
    func ready() async -> MTLRenderPipelineState? {
        if let pipeline { return pipeline }
        compile()
        let made = await compiling?.value
        return made
    }

    private func compile() {
        guard compiling == nil else { return }
        let device = device
        compiling = Task.detached(priority: .userInitiated) { Self.makePipeline(device) }
        Task { [weak self] in
            let made = await self?.compiling?.value
            guard let self, let made else { return }
            pipeline = made
            for view in views.allObjects where view.drawsOnLayout { view.setNeedsLayout() }
            wake()
        }
    }

    private nonisolated static func makePipeline(_ device: MTLDevice) -> MTLRenderPipelineState? {
        let options = MTLCompileOptions()
        options.mathMode = .safe
        options.mathFloatingPointFunctions = .precise
        guard let library = try? device.makeLibrary(source: avatarShaderMetal, options: options) else { return nil }
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = library.makeFunction(name: "avatar_vertex")
        descriptor.fragmentFunction = library.makeFunction(name: "avatar_fragment")
        descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
        return try? device.makeRenderPipelineState(descriptor: descriptor)
    }

    func redrawAll() {
        for view in views.allObjects { view.drawn = false }
        wake()
    }

    /// Whether `view` moves now: the system allows it, and the setting does
    /// when it follows it.
    private static func moves(_ view: LiveAvatarView) -> Bool {
        animates && (!view.drawing.followsSetting || LiveAvatars.isEnabled)
    }

    fileprivate func tick() {
        let all = views.allObjects
        guard !all.isEmpty else {
            link?.invalidate()
            link = nil
            return
        }
        guard let pipeline, !background else { return }
        // Past the cap the largest keep moving; the rest show their pictures.
        let showing = all.filter(Self.isShowing).sorted { $0.bounds.width > $1.bounds.width }
        let live = showing.prefix(Self.maxLive)
        for view in showing.dropFirst(Self.maxLive) where view.drawn {
            view.drawn = false
            view.isHidden = true
        }
        draw(live.filter { Self.moves($0) || !$0.drawn }, pipeline: pipeline)
    }

    /// `view`'s first frame, now, in the current transaction; nothing until
    /// the pipeline is compiled (then it lays out again).
    func drawNow(_ view: LiveAvatarView) {
        guard let pipeline, !background, Self.isShowing(view) else {
            wake()
            return
        }
        draw([view], pipeline: pipeline)
        wake()
    }

    /// A first frame is presented with the transaction it was laid out in,
    /// which waits on the main thread until the GPU has it scheduled; the
    /// frames after it go to the screen on their own, without the wait.
    private func draw(_ due: [LiveAvatarView], pipeline: MTLRenderPipelineState) {
        let began = CACurrentMediaTime()
        let first = due.filter { !$0.drawn }
        let next = due.filter(\.drawn)
        let drewFirst = draw(first, pipeline: pipeline, now: began, inTransaction: true)
        let drewNext = draw(next, pipeline: pipeline, now: began, inTransaction: false)
        guard drewFirst || drewNext else { return }
        let cpu = CACurrentMediaTime() - began
        cost.ticks += 1
        cost.cpuSeconds += cpu
        cost.cpuMax = max(cost.cpuMax, cpu)
    }

    private func draw(_ due: [LiveAvatarView], pipeline: MTLRenderPipelineState, now: CFTimeInterval, inTransaction: Bool) -> Bool {
        guard !due.isEmpty, let buffer = queue.makeCommandBuffer() else { return false }
        var drawables: [(LiveAvatarView, CAMetalDrawable)] = []
        for view in due {
            guard let frame = Self.frame(view, now: now) else { continue }
            if view.metalLayer.drawableSize != frame.size { view.metalLayer.drawableSize = frame.size }
            view.metalLayer.presentsWithTransaction = inTransaction
            guard let drawable = view.metalLayer.nextDrawable() else { continue }
            Self.encode(buffer, pipeline: pipeline, into: drawable.texture, frame: frame)
            drawables.append((view, drawable))
        }
        guard !drawables.isEmpty else { return false }
        buffer.addCompletedHandler { buffer in
            let gpu = buffer.gpuEndTime - buffer.gpuStartTime
            Task { @MainActor in AvatarShaderRenderer.shared?.noteGPU(gpu) }
        }
        if !inTransaction { for (_, drawable) in drawables { buffer.present(drawable) } }
        buffer.commit()
        if inTransaction {
            buffer.waitUntilScheduled()
            for (_, drawable) in drawables { drawable.present() }
        }
        for (view, _) in drawables {
            presented += 1
            view.drawn = true
            view.isHidden = false
        }
        return true
    }

    private func noteGPU(_ seconds: Double) {
        guard seconds > 0 else { return }
        cost.buffers += 1
        cost.gpuSeconds += seconds
        cost.gpuMax = max(cost.gpuMax, seconds)
    }

    /// In a window, its size known, and nothing above it hidden or faded out.
    private static func isShowing(_ view: LiveAvatarView) -> Bool {
        guard let window = view.window, !window.isHidden, view.bounds.width > 0, view.bounds.height > 0 else { return false }
        var ancestor = view.superview
        while let current = ancestor {
            if current.isHidden || current.alpha < 0.01 { return false }
            ancestor = current.superview
        }
        return view.convert(view.bounds, to: window).intersects(window.bounds)
    }

    /// One frame's inputs, in pixels.
    struct Frame {
        var size: CGSize
        var parameters: AvatarShader.Parameters
        var drawing: ShaderDrawing
        var time: Float
        var origin: SIMD2<Float>
        var canvas: SIMD2<Float>
    }

    private static func frame(_ view: LiveAvatarView, now: CFTimeInterval) -> Frame? {
        let drawing = view.drawing
        let bounds = view.bounds.size
        guard bounds.width > 0, bounds.height > 0 else { return nil }
        var perPoint = CGFloat(drawing.resolution ?? Float(min(view.window?.screen.scale ?? 3, 3)))
        let cap = CGFloat(drawing.canvas == nil ? maxPixels : maxCanvasPixels)
        perPoint = min(perPoint, cap / max(bounds.width, bounds.height))
        let size = CGSize(width: max(1, (bounds.width * perPoint).rounded(.up)), height: max(1, (bounds.height * perPoint).rounded(.up)))
        let parameters = AvatarShader.parameters(drawing.index)
        let speed = drawing.speed ?? AvatarShader.speed(side: Float(max(bounds.width, bounds.height)))
        let elapsed = moves(view) ? (now - view.started) * Double(speed) : 0
        let canvas = drawing.canvas ?? (CGRect(origin: .zero, size: bounds), bounds)
        let kx = size.width / bounds.width
        return Frame(
            size: size, parameters: parameters, drawing: drawing,
            time: AvatarShader.time(parameters, elapsed: elapsed),
            origin: SIMD2(Float(canvas.frame.minX * kx), Float(canvas.frame.minY * kx)),
            canvas: SIMD2(Float(canvas.size.width * kx), Float(canvas.size.height * kx))
        )
    }

    private struct Uniforms {
        var col1, col2, col3, col4: SIMD4<Float>
        var layout: SIMD4<Float>
        var fx: Float
        var t: Float
        var angle: Float
        var warp: Float
        var scale: Float
        var grain: Float
        var grainCell: Float
        var mono: Float
        var origin: SIMD2<Float>
        var canvas: SIMD2<Float>
        var tint: SIMD4<Float>
        var saturation: Float
        var opacity: Float
        var soften: Float
        var pad: Float = 0
    }

    private static func encode(_ buffer: MTLCommandBuffer, pipeline: MTLRenderPipelineState, into texture: MTLTexture, frame: Frame) {
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = texture
        pass.colorAttachments[0].loadAction = .dontCare
        pass.colorAttachments[0].storeAction = .store
        guard let encoder = buffer.makeRenderCommandEncoder(descriptor: pass) else { return }
        let parameters = frame.parameters
        func color(_ index: Int) -> SIMD4<Float> {
            let c = index < parameters.colors.count ? parameters.colors[index] : .zero
            return SIMD4(c, 1)
        }
        let look = frame.drawing.look
        var uniforms = Uniforms(
            col1: color(0), col2: color(1), col3: color(2), col4: color(3),
            layout: parameters.layout,
            fx: Float(parameters.effect.rawValue),
            t: frame.time,
            angle: parameters.angle,
            warp: AvatarShader.warp,
            scale: AvatarShader.scale / frame.drawing.zoom,
            grain: look.grain,
            grainCell: AvatarShader.grainCell(pixels: Int(max(frame.size.width, frame.size.height))),
            mono: frame.drawing.monochrome ? 1 : 0,
            origin: frame.origin,
            canvas: frame.canvas,
            tint: SIMD4(look.tint, look.tintAmount),
            saturation: look.saturation,
            opacity: look.opacity,
            soften: look.soften
        )
        encoder.setRenderPipelineState(pipeline)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
    }

    /// One frame of placeholder `index` at `time` (its phase when nil),
    /// `pixels` across, read back: for tests and comparisons.
    func image(index: Int, pixels: Int, time: Float? = nil, monochrome: Bool = false) async -> CGImage? {
        guard let pipeline = await ready() else { return nil }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: pixels, height: pixels, mipmapped: false)
        descriptor.usage = [.renderTarget, .shaderRead]
        descriptor.storageMode = .shared
        guard let texture = device.makeTexture(descriptor: descriptor), let buffer = queue.makeCommandBuffer() else { return nil }
        let parameters = AvatarShader.parameters(index)
        let side = SIMD2(Float(pixels), Float(pixels))
        let frame = Frame(
            size: CGSize(width: pixels, height: pixels), parameters: parameters,
            drawing: ShaderDrawing(index: index, monochrome: monochrome),
            time: time ?? parameters.phase, origin: .zero, canvas: side
        )
        Self.encode(buffer, pipeline: pipeline, into: texture, frame: frame)
        await withCheckedContinuation { continuation in
            buffer.addCompletedHandler { _ in continuation.resume() }
            buffer.commit()
        }
        let bytesPerRow = pixels * 4
        var bytes = [UInt8](repeating: 0, count: bytesPerRow * pixels)
        texture.getBytes(&bytes, bytesPerRow: bytesPerRow, from: MTLRegionMake2D(0, 0, pixels, pixels), mipmapLevel: 0)
        let info = CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        guard let provider = CGDataProvider(data: Data(bytes) as CFData) else { return nil }
        return CGImage(width: pixels, height: pixels, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: bytesPerRow, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: info, provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }
}

/// The display link's target, so the link doesn't keep the renderer alive.
private final class Tick: NSObject {
    weak var renderer: AvatarShaderRenderer?
    init(_ renderer: AvatarShaderRenderer) { self.renderer = renderer }
    @MainActor @objc func tick(_ link: CADisplayLink) {
        guard let renderer else { return link.invalidate() }
        renderer.tick()
    }
}
#endif
