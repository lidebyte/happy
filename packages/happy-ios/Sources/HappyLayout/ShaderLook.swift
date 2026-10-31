/// How an avatar's shader is drawn where it isn't an avatar: drained of some
/// colour, washed toward a tint, faded, slowed, and cropped from a larger
/// canvas. `.avatar` is the shader as it is.
public struct ShaderLook: Equatable, Sendable {
    /// 1 keeps the shader's colours, 0 is grey.
    public var saturation: Float
    /// What it is washed toward (sRGB), and how far: 0 not at all, 1 all tint.
    public var tint: SIMD3<Float>
    public var tintAmount: Float
    /// 1 opaque; less shows what is under it.
    public var opacity: Float
    /// The film grain's strength (the package's is 0.07).
    public var grain: Float
    /// How far around each point it is averaged, in the avatar's units
    /// (it is 1 across): softens the hard edges of a colour held between
    /// two blends, which read as a seam across a pill. 0, not at all.
    public var soften: Float

    public init(saturation: Float = 1, tint: SIMD3<Float> = .zero, tintAmount: Float = 0, opacity: Float = 1, grain: Float = AvatarShader.grain, soften: Float = 0) {
        self.soften = soften
        self.saturation = saturation
        self.tint = tint
        self.tintAmount = tintAmount
        self.opacity = opacity
        self.grain = grain
    }

    public static let avatar = ShaderLook()
}

/// The chat header's glass (Back, the title capsule, Compose) over the
/// chat's own avatar shader: one shader across the whole bar, each piece of
/// glass a window onto its part, tinted so it stays a quiet colour under
/// the glass and the words and glyphs on it read. Everything it is drawn
/// with is here.
public enum ChatPillShader {
    /// Where the shader goes: under the glass, which blurs and lights it
    /// as it does whatever is behind it, or inside the glass, over its
    /// material and under the words.
    public enum Placement: String, Sendable, CaseIterable {
        case behindGlass
        case inGlass
    }

    public struct Style: Equatable, Sendable {
        public var placement: Placement
        public var light: ShaderLook
        public var dark: ShaderLook
        /// The clock's rate: 1 is the avatar's own.
        public var speed: Float
        /// How much of the avatar the bar's width spans: 1 is all of it;
        /// less zooms in, so a pill shows a broad stretch of one colour.
        public var zoom: Float
        /// Pixels drawn per point. Under glass the shader is blurred, so
        /// a fraction of the screen's resolution is the same picture.
        public var resolution: Float

        public init(placement: Placement, light: ShaderLook, dark: ShaderLook, speed: Float, zoom: Float, resolution: Float) {
            self.placement = placement
            self.light = light
            self.dark = dark
            self.speed = speed
            self.zoom = zoom
            self.resolution = resolution
        }

        public func look(dark isDark: Bool) -> ShaderLook { isDark ? dark : light }
    }

    static let white = SIMD3<Float>(1, 1, 1)
    static let black = SIMD3<Float>(0, 0, 0)

    /// What was tried, by name. Picked from: `chosen`.
    public static let candidates: [(name: String, style: Style)] = [
        // The shader as it is, under the glass: the glass alone tints it.
        ("A raw under glass", Style(
            placement: .behindGlass,
            light: ShaderLook(grain: 0), dark: ShaderLook(grain: 0),
            speed: 1, zoom: 1, resolution: 1
        )),
        // Half its colour, washed toward the screen's ground, under glass.
        ("B washed under glass", Style(
            placement: .behindGlass,
            light: ShaderLook(saturation: 0.75, tint: white, tintAmount: 0.45, grain: 0),
            dark: ShaderLook(saturation: 0.75, tint: black, tintAmount: 0.5, grain: 0),
            speed: 0.6, zoom: 0.8, resolution: 0.5
        )),
        // Faded, so the glass shows a little of the shader and a little of
        // the chat behind it.
        ("C faded under glass", Style(
            placement: .behindGlass,
            light: ShaderLook(opacity: 0.55, grain: 0),
            dark: ShaderLook(opacity: 0.5, grain: 0),
            speed: 0.6, zoom: 0.8, resolution: 0.5
        )),
        // Inside the glass, a thin wash of colour over its material.
        ("D wash in glass", Style(
            placement: .inGlass,
            light: ShaderLook(saturation: 0.9, opacity: 0.22, grain: 0),
            dark: ShaderLook(saturation: 0.9, opacity: 0.28, grain: 0),
            speed: 0.6, zoom: 0.8, resolution: 0.5
        )),
        // Inside the glass, drained and tinted to the ground, more opaque.
        ("E tinted in glass", Style(
            placement: .inGlass,
            light: ShaderLook(saturation: 0.6, tint: white, tintAmount: 0.6, opacity: 0.6, grain: 0),
            dark: ShaderLook(saturation: 0.6, tint: black, tintAmount: 0.6, opacity: 0.6, grain: 0),
            speed: 0.6, zoom: 0.8, resolution: 0.5
        )),
        // Under the glass, drained and washed most of the way to the
        // screen's ground: a quiet tint of the chat's colours.
        ("F tint under glass", Style(
            placement: .behindGlass,
            light: ShaderLook(saturation: 0.6, tint: white, tintAmount: 0.65, grain: 0),
            dark: ShaderLook(saturation: 0.6, tint: black, tintAmount: 0.72, grain: 0),
            speed: 0.5, zoom: 0.7, resolution: 0.5
        )),
        // F with a little more colour in the light and a little less wash
        // in the dark.
        ("G tint under glass, warmer", Style(
            placement: .behindGlass,
            light: ShaderLook(saturation: 0.7, tint: white, tintAmount: 0.55, grain: 0),
            dark: ShaderLook(saturation: 0.65, tint: black, tintAmount: 0.66, grain: 0),
            speed: 0.5, zoom: 0.7, resolution: 0.5
        )),
        ("H chosen: G light, F dark", chosen),
    ]

    /// The header's look: under the glass, drained to 70% of its colour and
    /// washed 55% of the way to white in the light; to 60% and 72% of the
    /// way to black in the dark; at half the avatar's speed, zoomed so the
    /// bar spans 70% of the avatar, drawn at half a pixel per point.
    ///
    /// Why: under the glass it is one look for the title and for Back and
    /// Compose, which are the system's glass and take nothing inside; the
    /// glass keeps its own light and edge, and its blur hides the drawing at
    /// half a pixel a point. Tinted, it is the chat's colour, quietly, and
    /// it hides what scrolls under the bar: over the busiest ground tried (a
    /// bright picture) the name is 14.9:1 against the glass in the light and
    /// 6.8:1 in the dark, where plain glass is 7.7:1 and 3.1:1, and the grey
    /// status line 2.3:1 and 2.1:1, where it is 1.2:1 and 1.1:1. The raw
    /// shader (A) and a faded one (C) are louder than the words in the dark;
    /// a wash inside the glass (D, E) muddies them. More colour in the light
    /// (G) reads as well as F there; in the dark F's deeper wash is needed.
    /// Slower and zoomed in, a pill holds a colour or two that drift, rather
    /// than bands that run; softened over 4% of the avatar, a colour the
    /// shader holds between two blends is no thin seam across the name.
    /// Compared in the chat harness's `-screen pillShaders`.
    public static let chosen = Style(
        placement: .behindGlass,
        light: ShaderLook(saturation: 0.7, tint: white, tintAmount: 0.55, grain: 0, soften: 0.04),
        dark: ShaderLook(saturation: 0.6, tint: black, tintAmount: 0.72, grain: 0, soften: 0.04),
        speed: 0.5, zoom: 0.7, resolution: 0.5
    )
}
