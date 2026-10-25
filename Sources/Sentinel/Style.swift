import AppKit
import SwiftUI

/// Sentinel's design language, adapted from Vorssaint's glass panel style:
/// translucent cards with hairline borders, uppercase micro section headers and
/// status colors that stay readable in light mode (Dark mode keeps iOS-green).
///
/// Everything here is `@Environment(\.colorScheme)` aware and concrete enough
/// to drop straight into any window, sheet or popover.
enum Style {
  static let cardRadius: CGFloat = 12
  static let tileRadius: CGFloat = 12
  static let sidebarWidth: CGFloat = 220
  static let headerHeight: CGFloat = 52
  /// Space reserved for the traffic lights when the window draws full-height
  /// content under a hidden title bar.
  static let titlebarInset: CGFloat = 28

  // MARK: Accent — the user's macOS accent color.

  /// The macOS system accent color (System Settings → Appearance → Accent
  /// color), resolved per appearance. AppKit has no `resolvedColor(with:)`
  /// (that is the UIColor API), so the equivalent is a dynamic `NSColor` whose
  /// provider resolves `controlAccentColor` under the appearance it is asked
  /// for. Used for interactive controls — buttons, pickers, switches,
  /// selection — while plain text stays `.primary`/`.secondary` so it never
  /// turns accent-colored.
  static var accentColor: Color {
    Color(nsColor: NSColor(name: nil) { appearance in
      var resolved = NSColor.controlAccentColor
      appearance.performAsCurrentDrawingAppearance {
        resolved = NSColor.controlAccentColor.usingColorSpace(.sRGB) ?? resolved
      }
      return resolved
    })
  }

  /// Semantic status colors, taken from AppKit so they follow the user's
  /// accessibility settings (Increase Contrast, color filters). These are for
  /// success / warning / failure meaning, never for interactive accents.
  static let successColor: Color = .init(nsColor: .systemGreen)
  static let warningColor: Color = .init(nsColor: .systemOrange)
  static let errorColor: Color = .init(nsColor: .systemRed)

  // MARK: Surfaces

  /// The sidebar plane: a hair lighter than the content in both appearances,
  /// the way Finder, Mail and Notes divide a window. Opaque, so the desktop
  /// never shows through behind labels or video.
  static func sidebarFill(_ scheme: ColorScheme) -> Color {
    scheme == .light
      ? Color(red: 0.984, green: 0.984, blue: 0.988)
      : Color(red: 0.173, green: 0.173, blue: 0.180)
  }

  /// The content plane behind pages.
  static func contentFill(_ scheme: ColorScheme) -> Color {
    scheme == .light
      ? Color(red: 0.949, green: 0.949, blue: 0.957)
      : Color(red: 0.110, green: 0.110, blue: 0.118)
  }

  /// A card sitting on the content plane.
  static func cardFill(_ scheme: ColorScheme) -> Color {
    scheme == .light
      ? Color(red: 0.992, green: 0.992, blue: 0.996)
      : Color(red: 0.149, green: 0.149, blue: 0.157)
  }

  /// Inset controls raised above a card.
  static func controlFill(_ scheme: ColorScheme) -> Color {
    scheme == .light ? Color.black.opacity(0.055) : Color.white.opacity(0.085)
  }

  /// The hairline that separates cards from the background.
  static func border(_ scheme: ColorScheme) -> Color {
    scheme == .light ? Color.black.opacity(0.09) : Color.white.opacity(0.11)
  }

  /// The native separator between the sidebar and the content, and under page
  /// headers. Dynamic, so it follows the system appearance.
  static let hairline = Color(nsColor: .separatorColor)

  /// The selected sidebar row's pill.
  static func selectionFill(_ scheme: ColorScheme) -> Color {
    accentColor.opacity(scheme == .light ? 0.14 : 0.22)
  }

  /// A pointer-hover wash for rows and cards that want one.
  static func rowHoverFill(_ scheme: ColorScheme) -> Color {
    Color.primary.opacity(scheme == .light ? 0.045 : 0.06)
  }

  // MARK: Status

  static func statusColor(_ state: FeedState, scheme: ColorScheme) -> Color {
    // Stock AppKit system colors: readable in both appearances and aware of
    // accessibility contrast settings.
    switch state {
    case .live: successColor
    case .connecting: .init(nsColor: .systemYellow)
    case .failed: errorColor
    case .idle: .init(nsColor: .systemGray)
    }
  }

  /// A soft tint for the status dot's halo, keyed by state.
  static func statusGlow(_ state: FeedState) -> Color {
    switch state {
    case .live: successColor.opacity(0.45)
    case .connecting: Color(nsColor: .systemYellow).opacity(0.45)
    case .failed: errorColor.opacity(0.45)
    case .idle: Color(nsColor: .systemGray).opacity(0.3)
    }
  }
}

// MARK: Building blocks

/// AppKit's own indeterminate spinner, wrapped for SwiftUI. SwiftUI's
/// `ProgressView` proved unreliable inside NSPopover-hosted hosting views
/// (spinner not drawn); the native control always animates and is forced to a
/// dark appearance so its arcs stay visible on any surface.
struct SpinnerView: NSViewRepresentable {
  var size: CGFloat

  func makeNSView(context: Context) -> NSProgressIndicator {
    let indicator = NSProgressIndicator()
    indicator.isIndeterminate = true
    indicator.style = .spinning
    indicator.controlSize = .small
    indicator.appearance = NSAppearance(named: .darkAqua)
    indicator.sizeToFit()
    indicator.startAnimation(nil)
    return indicator
  }

  func updateNSView(_ indicator: NSProgressIndicator, context: Context) {}

  static func dismantleNSView(_ indicator: NSProgressIndicator, coordinator: ()) {
    indicator.stopAnimation(nil)
  }
}

/// Shown while a stream connects: a compact dark pill with a spinner and
/// label. The video beneath it is always black (CameraFeed discards the last
/// frame on every connect attempt), so "connecting" can never be mistaken for
/// a frozen picture.
struct ConnectingOverlay: View {
  /// Text inside the pill, or nil for a spinner-only center marker.
  var caption: String? = "Connecting…"

  var body: some View {
    if let caption {
      HStack(spacing: 9) {
        SpinnerView(size: 16)
        Text(caption)
          .font(.footnote.weight(.medium))
          .foregroundStyle(.white.opacity(0.9))
      }
      .padding(.horizontal, 15)
      .padding(.vertical, 10)
      .background(Color.black.opacity(0.6), in: Capsule())
      .overlay(
        Capsule().strokeBorder(.white.opacity(0.14), lineWidth: 1))
      .transition(.opacity)
    } else {
      SpinnerView(size: 24)
        .allowsHitTesting(false)
    }
  }
}

/// The micro header above a card group: "CONNECTION", uppercase, 10pt, kerned.
struct SectionHeader: View {
  let text: String

  var body: some View {
    Text(text)
      .font(.system(size: 10, weight: .semibold))
      .kerning(0.5)
      .foregroundStyle(.secondary)
      .padding(.leading, 4)
  }
}

/// The in-content title bar shared by every page: a title, an optional
/// one-line subtitle, and trailing controls, all on the content surface with a
/// native hairline underneath. Replaces the SwiftUI toolbar deliberately — the
/// app draws its own header so AppKit's title-bar constraint machinery stays
/// out of the layout graph (see MainView).
struct PageHeader<Trailing: View>: View {
  let title: String
  let subtitle: String?
  let trailing: Trailing
  @Environment(\.colorScheme) private var scheme

  init(_ title: String, subtitle: String? = nil, @ViewBuilder trailing: () -> Trailing) {
    self.title = title
    self.subtitle = subtitle
    self.trailing = trailing()
  }

  var body: some View {
    HStack(alignment: .center, spacing: 12) {
      VStack(alignment: .leading, spacing: 1) {
        Text(title)
          .font(.system(size: 15, weight: .semibold))
          .lineLimit(1)
          .truncationMode(.middle)
        if let subtitle, !subtitle.isEmpty {
          Text(subtitle)
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }
      }
      Spacer(minLength: 8)
      trailing
    }
    .padding(.horizontal, 16)
    .frame(height: Style.headerHeight)
    .frame(maxWidth: .infinity)
    .background(Style.contentFill(scheme))
    .overlay(alignment: .bottom) {
      Rectangle().fill(Style.hairline).frame(height: 1)
    }
  }
}

extension PageHeader where Trailing == EmptyView {
  init(_ title: String, subtitle: String? = nil) {
    self.init(title, subtitle: subtitle) { EmptyView() }
  }
}

/// A plain stock-color status dot (green / amber / red / gray). Pass
/// `pulses: true` for a live feed's breathing halo — used only in the popover,
/// where a single dot is a useful "this is live right now" cue.
struct StatusDot: View {
  let state: FeedState
  var pulses = false
  @Environment(\.colorScheme) private var scheme

  var body: some View {
    if pulses, state == .live {
      TimelineView(.animation(minimumInterval: 1.0 / 20.0)) { context in
        let phase = context.date.timeIntervalSinceReferenceDate
          .truncatingRemainder(dividingBy: 1.8) / 1.8
        ZStack {
          Circle()
            .fill(color.opacity(0.42 * (1 - phase)))
            .frame(width: 7, height: 7)
            .scaleEffect(1 + phase * 1.7)
          Circle()
            .fill(color)
            .frame(width: 7, height: 7)
        }
        .frame(width: 7, height: 7)
      }
    } else {
      Circle()
        .fill(color)
        .frame(width: 7, height: 7)
    }
  }

  private var color: Color {
    Style.statusColor(state, scheme: scheme)
  }
}

/// A single keyboard key drawn like a physical keycap (e.g. ⌘, , ←).
struct KeyCap: View {
  let label: String

  var body: some View {
    Text(label)
      .font(.system(size: 11, weight: .semibold, design: .rounded))
      .frame(minWidth: 20, minHeight: 21)
      .padding(.horizontal, 4)
      .background(
        RoundedRectangle(cornerRadius: 5, style: .continuous)
          .fill(Color.primary.opacity(0.07))
      )
      .overlay(
        RoundedRectangle(cornerRadius: 5, style: .continuous)
          .strokeBorder(Color.primary.opacity(0.14), lineWidth: 1)
      )
  }
}

/// A row of keycaps for one shortcut, e.g. ["⌘", ","].
struct ShortcutCaps: View {
  let keys: [String]

  var body: some View {
    HStack(spacing: 3) {
      ForEach(Array(keys.enumerated()), id: \.offset) { _, key in
        KeyCap(label: key)
      }
    }
  }
}

/// Shown when a stream fails: a centered dark card over the dead surface.
struct ErrorCover: View {
  let message: String
  let retry: () -> Void

  var body: some View {
    VStack(spacing: 10) {
      Image(systemName: "wifi.exclamationmark")
        .font(.system(size: 22))
      Text(message)
        .font(.callout)
        .multilineTextAlignment(.center)
        .lineLimit(3)
      Button("Retry", action: retry)
        .buttonStyle(.bordered)
        .controlSize(.small)
    }
    .foregroundStyle(.white)
    .padding(16)
    .background(
      Color.black.opacity(0.68), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    .overlay(
      RoundedRectangle(cornerRadius: 12, style: .continuous)
        .strokeBorder(.white.opacity(0.12), lineWidth: 1))
  }
}

/// The friendly card shown when there is nothing to watch yet: no cameras
/// enabled, no recorder configured, or an empty search/filter result.
struct EmptyStateCard: View {
  let icon: String
  let title: String
  let message: String
  var actionTitle: String? = nil
  var action: (() -> Void)? = nil
  @Environment(\.colorScheme) private var scheme

  var body: some View {
    VStack(spacing: 14) {
      ZStack {
        RoundedRectangle(cornerRadius: 14, style: .continuous)
          .fill(Style.accentColor.opacity(0.12))
          .frame(width: 56, height: 56)
        Image(systemName: icon)
          .font(.system(size: 24, weight: .medium))
          .foregroundStyle(Style.accentColor)
      }

      VStack(spacing: 5) {
        Text(title)
          .font(.title3.weight(.semibold))
        Text(message)
          .font(.callout)
          .foregroundStyle(.secondary)
          .multilineTextAlignment(.center)
          .fixedSize(horizontal: false, vertical: true)
      }

      if let actionTitle, let action {
        Button(actionTitle, action: action)
          .buttonStyle(.borderedProminent)
          .tint(Style.accentColor)
      }
    }
    .padding(.horizontal, 28)
    .padding(.vertical, 26)
    .frame(maxWidth: 420)
    .background(
      Style.cardFill(scheme),
      in: RoundedRectangle(cornerRadius: Style.cardRadius + 4, style: .continuous)
    )
    .overlay(
      RoundedRectangle(cornerRadius: Style.cardRadius + 4, style: .continuous)
        .strokeBorder(Style.border(scheme), lineWidth: 1)
    )
  }
}

/// Video surface + universal overlays (error cover, live status capsule).
struct VideoStage: View {
  let feed: CameraFeed

  var body: some View {
    ZStack {
      Color.black
      VideoLayerView(surface: feed.surface)
      errorCover
    }
  }

  @ViewBuilder private var errorCover: some View {
    switch feed.state {
    case .failed(let message):
      ErrorCover(message: message) { feed.restart() }
    case .connecting:
      ConnectingOverlay()
        .environment(\.colorScheme, .dark)
    case .idle:
      Image(systemName: "video.slash")
        .foregroundStyle(.white.opacity(0.45))
        .font(.title3)
    case .live:
      EmptyView()
    }
  }
}

/// Reads a feed's fps without dragging the whole layout graph into
/// Observation tracking: fps ticks once per second per stream and would
/// flush SwiftUI's graph (and AppKit's window constraint passes) at
/// display-cycle frequency. Poll into local state instead so this readout
/// flushes at most once per second, and only when the value changes.
struct FpsReadout: View {
  let feed: CameraFeed
  @State private var fps = 0

  var body: some View {
    Text("\(fps) fps")
      .task {
        while !Task.isCancelled {
          try? await Task.sleep(for: .seconds(1))
          if fps != feed.fps { fps = feed.fps }
        }
      }
  }
}


