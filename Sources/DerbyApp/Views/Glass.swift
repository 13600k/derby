import SwiftUI
import AppKit

// MARK: - Palette

extension Color {
    /// Derby's brand accent: teal, `#008080`.
    ///
    /// Used everywhere in place of `Color.accentColor` so the app reads the same
    /// whatever the user's macOS accent colour happens to be. The root view
    /// applies `.tint(.derbyAccent)`, which carries it into system controls
    /// (prominent buttons, toggles, pickers, sidebar selection).
    static let derbyAccent = Color(.sRGB, red: 0, green: 128.0 / 255.0, blue: 128.0 / 255.0, opacity: 1)

    /// The accent taken darker, for the far corner of the window ground where
    /// the accent itself would read as washed out.
    static let derbyDeepTeal = Color(.sRGB, red: 0, green: 0.32, blue: 0.36, opacity: 1)

    /// The ground laid under text on every glass surface.
    ///
    /// The system appearance picks the *text* colour; this picks a background
    /// whose brightness matches it — pale teal under black text, deep teal
    /// under white. That pairing is the whole job: without it, text over clear
    /// glass sits on whatever window happens to be behind Derby, which is how
    /// black text ends up on somebody else's dark editor.
    static let derbyGlassScrim = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? NSColor(srgbRed: 0.03, green: 0.145, blue: 0.155, alpha: 1)
            : NSColor(srgbRed: 0.855, green: 0.945, blue: 0.945, alpha: 1)
    })
}

// MARK: - Tuning

/// The knobs worth turning when the look is not right.
enum GlassTuning {
    /// Blurs the desktop behind the window.
    ///
    /// On. Without it the window has no ground at all: text lands on whatever
    /// happens to be behind Derby, which is both unreadable — black text over
    /// somebody else's dark window — and a privacy leak, since the app behind
    /// stays perfectly legible through the app in front.
    ///
    /// It costs some warp, because glass can only refract what it can see and
    /// this blurs the detail away. That trade is settled deliberately: the
    /// *window* provides opacity, the *surfaces* stay clear and refract the
    /// window's own ground. Set to `false` for maximum warp and no legibility.
    static let frostedBackdrop = true

    /// Teal poured over the whole window before any surface is drawn.
    static let backdropStain = 0.17

    /// Pins the window's appearance instead of following the system.
    ///
    /// Appearance is what picks the text colour, and every scrim below is an
    /// adaptive system colour, so light and dark both work as they stand. Set
    /// this to `.darkAqua` to force the look most people picture for stained
    /// glass — light text over deep teal — whatever the system is set to.
    static let pinnedAppearance: NSAppearance.Name? = nil
}

// MARK: - The glass vocabulary

/// The kinds of glass Derby is built from.
///
/// On macOS 26 these are real Liquid Glass: `glassEffect` refracts and lenses
/// whatever sits behind the surface, so a card over the desktop genuinely warps
/// it and its edges pick up a specular highlight as the window moves. macOS 14
/// and 15 have no such API, so every call site falls back to a blurred material
/// under a tinted wash — translucent and stained, minus the warp. Nothing
/// outside this file needs to know which one it got.
///
/// The cases are named for the *role* a surface plays, not for how it looks, so
/// the whole app can be restained by editing the numbers here.
enum GlassSurface {
    /// Window chrome: the sidebar, page headers, the gateway footer.
    case chrome
    /// A content panel: cards, stat tiles, list rows.
    case panel
    /// Something small floating on a panel: pills, chips, inline fields.
    case chip
    /// A surface that must read as lifted off the page: banners, sheets.
    case raised
    /// A well recessed *into* a panel: code blocks, JSON dumps, text editors.
    /// Barely stained, because it is where the densest small text lives.
    case inset

    /// Which of the two glass materials the surface is cut from.
    ///
    /// `.clear` is the transparent, strongly refracting one — it is what makes
    /// a card visibly bend the desktop behind it, and it is the default here.
    /// `.regular` frosts instead of refracting, so it is kept for the one
    /// surface that has to stay readable over anything at all: a banner, which
    /// appears precisely when something has gone wrong.
    @available(macOS 26.0, *)
    var base: Glass {
        switch self {
        case .raised: return .regular
        case .chrome, .panel, .chip, .inset: return .clear
        }
    }

    /// An adaptive fill laid between the glass and the content.
    ///
    /// This is what fixes text sitting on nothing. Clear glass shows through to
    /// whatever is behind the window, so text ends up over an unpredictable
    /// luminance — black on a dark window, and unreadable. The scrim is a
    /// *system* colour, so it is light under black text and dark under white
    /// text automatically, and it sits above the glass, which goes on
    /// refracting underneath it.
    var scrim: Double {
        switch self {
        case .chrome: return 0.26
        case .panel: return 0.26
        case .chip: return 0.14
        case .raised: return 0.42
        case .inset: return 0.18
        }
    }

    /// How much of the tint is dissolved into the glass.
    ///
    /// Stain runs inversely to text density. Chrome and chips carry short
    /// labels and can take the colour; panels hold paragraphs, tables and
    /// numbers, so they stay near-clear or the contrast goes.
    var stain: Double {
        switch self {
        case .chrome: return 0.16
        case .panel: return 0.11
        case .chip: return 0.18
        case .raised: return 0.12
        case .inset: return 0.06
        }
    }

    /// Opacity of the white specular edge along the top-left — the cue that
    /// says "this has thickness" rather than "this is a coloured rectangle".
    var highlight: Double {
        switch self {
        case .chrome: return 0.34
        case .panel: return 0.44
        case .chip: return 0.38
        case .raised: return 0.50
        case .inset: return 0.28
        }
    }

    /// Opacity of the leading: the darker tinted line that closes the bottom
    /// -right of the piece, the way came closes a pane of stained glass.
    var leading: Double {
        switch self {
        case .chrome: return 0.22
        case .panel: return 0.30
        case .chip: return 0.26
        case .raised: return 0.36
        case .inset: return 0.24
        }
    }

    var lineWidth: CGFloat {
        switch self {
        case .chrome: return 0.9
        case .panel: return 1.0
        case .chip: return 0.8
        case .raised: return 1.1
        case .inset: return 0.9
        }
    }

    /// The blur behind the fallback surface on macOS 14/15, which have no
    /// glass to be clear with. Without refraction a surface needs *some* blur
    /// to separate itself from the desktop, so the fallback stays frosted where
    /// the real thing is transparent — the one place the two paths part ways.
    var fallbackMaterial: Material {
        switch self {
        case .chrome: return .ultraThinMaterial
        case .panel: return .ultraThinMaterial
        case .chip: return .ultraThinMaterial
        case .raised: return .thinMaterial
        case .inset: return .ultraThinMaterial
        }
    }
}

extension View {
    /// Renders this view as a piece of tinted glass.
    ///
    /// - Parameters:
    ///   - surface: the role the piece plays, which sets stain and edge weight.
    ///   - shape: the outline of the pane. Insettable so the leading can be
    ///     stroked *inside* the edge and not bleed a half-pixel outside it.
    ///   - tint: overrides the teal stain — status pills stain themselves green
    ///     or red so the colour still carries meaning.
    ///   - interactive: on macOS 26, makes the glass flex and brighten under
    ///     the pointer. Worth it on rows and controls, distracting on static
    ///     panels.
    func glassSurface<S: InsettableShape>(
        _ surface: GlassSurface,
        in shape: S,
        tint: Color? = nil,
        interactive: Bool = false
    ) -> some View {
        modifier(GlassSurfaceModifier(surface: surface, shape: shape,
                                      tint: tint ?? .derbyAccent, interactive: interactive))
    }

    /// A full-bleed translucent pane: the replacement for an opaque
    /// `windowBackgroundColor` fill.
    ///
    /// Keeps the window backdrop — and the desktop behind it — visible, with a
    /// faint teal cast so panes still separate from one another.
    func glassPane(stain: Double = 0.07) -> some View {
        background {
            Rectangle()
                .fill(Color.derbyAccent.opacity(stain))
                .ignoresSafeArea()
        }
    }
}

private struct GlassSurfaceModifier<S: InsettableShape>: ViewModifier {
    var surface: GlassSurface
    var shape: S
    var tint: Color
    var interactive: Bool

    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content
                .background { scrim }
                .glassEffect(liquid, in: shape)
                .overlay { leading }
        } else {
            content
                .background { scrim }
                .background {
                    shape
                        .fill(surface.fallbackMaterial)
                        .overlay(shape.fill(tint.opacity(surface.stain)))
                }
                .overlay { leading }
        }
    }

    @available(macOS 26.0, *)
    private var liquid: Glass {
        let stained = surface.base.tint(tint.opacity(surface.stain))
        return interactive ? stained.interactive() : stained
    }

    /// Sits above the glass and below the text, so the glass keeps refracting
    /// while the text gets a ground whose brightness matches its own colour.
    private var scrim: some View {
        shape.fill(Color.derbyGlassScrim.opacity(surface.scrim))
    }

    /// Light catches the top-left of a pane and the came closes the
    /// bottom-right. One gradient stroke does both.
    private var leading: some View {
        shape.strokeBorder(
            LinearGradient(
                colors: [
                    .white.opacity(surface.highlight),
                    tint.opacity(surface.leading * 0.5),
                    .black.opacity(surface.leading * 0.55),
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing),
            lineWidth: surface.lineWidth)
    }
}

// MARK: - The window itself

/// Clears the host window so the glass has something to refract.
///
/// Liquid Glass lenses what is *behind* it. Inside an opaque window the only
/// thing behind a card is the window's own fill, so the effect collapses into a
/// flat tint — the surfaces stop reading as glass and start reading as coloured
/// rectangles. Clearing the window background is what lets the desktop through,
/// and it is the single change the whole look depends on.
///
/// Attached as a zero-sized view because `NSViewRepresentable` is the only way
/// to reach the `NSWindow` from SwiftUI; it draws nothing.
struct GlassWindowConfigurator: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { ConfiguringView() }

    // Re-applied on update, not just on attach: SwiftUI recreates the window's
    // backing on appearance changes and full-screen transitions, and an opaque
    // window coming back mid-session turns every pane into a flat rectangle.
    func updateNSView(_ nsView: NSView, context: Context) {
        (nsView as? ConfiguringView)?.applyGlassWindowStyle()
    }

    private final class ConfiguringView: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            applyGlassWindowStyle()
        }

        func applyGlassWindowStyle() {
            guard let window else { return }
            window.isOpaque = false
            window.backgroundColor = .clear
            // A titlebar drawn in its own material would sit as an opaque strip
            // above panes that are transparent, which is exactly the seam the
            // glass is meant to remove.
            window.titlebarAppearsTransparent = true
            if let name = GlassTuning.pinnedAppearance {
                window.appearance = NSAppearance(named: name)
            }
        }
    }
}

/// The blurred desktop that every other surface is layered over.
///
/// `blendingMode = .behindWindow` is what samples the desktop rather than the
/// window's own content, and it only works on a window whose background has
/// been cleared — see `GlassWindowConfigurator`.
struct WindowBackdrop: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .underWindowBackground

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = .behindWindow
        view.isEmphasized = true
        // `.followsWindowActiveState` would drop the blur to grey whenever the
        // user clicks away, and a gateway's dashboard is mostly watched from
        // behind another window.
        view.state = .active
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {
        view.material = material
        view.state = .active
    }
}

extension View {
    /// The app's ground: blurred desktop, a teal stain poured over it, and the
    /// window transparency that makes both visible.
    func derbyGlassBackground() -> some View {
        background {
            ZStack {
                if GlassTuning.frostedBackdrop {
                    WindowBackdrop()
                }
                // Base wash, then two soft pools of colour. The pools are the
                // point: a pane of glass over an even wash has nothing to bend,
                // and the warp only becomes visible where it crosses a change
                // in what is behind it.
                LinearGradient(
                    colors: [
                        Color.derbyAccent.opacity(GlassTuning.backdropStain),
                        Color.derbyAccent.opacity(GlassTuning.backdropStain * 0.85),
                    ],
                    startPoint: .top,
                    endPoint: .bottom)
                RadialGradient(
                    colors: [Color.derbyAccent.opacity(GlassTuning.backdropStain * 1.9), .clear],
                    center: .topLeading, startRadius: 0, endRadius: 620)
                RadialGradient(
                    colors: [Color.derbyDeepTeal.opacity(GlassTuning.backdropStain * 1.5), .clear],
                    center: .bottomTrailing, startRadius: 0, endRadius: 720)
            }
            .ignoresSafeArea()
        }
        .background { GlassWindowConfigurator().frame(width: 0, height: 0) }
    }
}

// MARK: - Controls

extension View {
    /// A prominent call to action, in glass where the OS has it.
    @ViewBuilder
    func derbyProminentButton() -> some View {
        if #available(macOS 26.0, *) {
            buttonStyle(.glassProminent).tint(.derbyAccent)
        } else {
            buttonStyle(.borderedProminent).tint(.derbyAccent)
        }
    }

    /// Sheets get their own window, which arrives opaque. This gives one the
    /// same ground the main window has, so a sheet reads as another pane of the
    /// same glass rather than a solid card dropped on top of it.
    func derbyGlassSheet() -> some View {
        presentationBackground {
            ZStack {
                Rectangle().fill(.ultraThinMaterial).opacity(0.5)
                LinearGradient(
                    colors: [Color.derbyAccent.opacity(0.13), Color.derbyAccent.opacity(0.05)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing)
            }
            .ignoresSafeArea()
        }
    }

    /// Removes the opaque fill a `List` or `ScrollView` paints for itself, so
    /// the window backdrop shows through it.
    func clearScrollBackground() -> some View {
        scrollContentBackground(.hidden)
    }
}
