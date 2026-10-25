import SwiftUI

/// The right-pane home: a pager of 2×2 tiles, four cameras per page so at most
/// four streams decode at once.
///
/// Layout is a plain stack of fixed rows — one `VStack`/`HStack` per page —
/// instead of a LazyVGrid with aspect-fit geometry. Simple, single-pass layout
/// keeps AppKit's window constraint machinery quiet (see MainView).
struct GridPage: View {
  let model: GridModel
  @Binding var page: Int
  var onFocus: (Int) -> Void
  var onOpenSettings: () -> Void
  @Environment(\.colorScheme) private var scheme

  var body: some View {
    VStack(spacing: 0) {
      PageHeader("All Cameras", subtitle: subtitle) {
        if pageCount > 1 {
          HStack(spacing: 2) {
            pagerButton("chevron.left", help: "Previous page (←)", enabled: clampedPage > 0) {
              flipPage(forward: false)
            }
            Text("\(clampedPage + 1) / \(pageCount)")
              .font(.system(size: 11, weight: .medium))
              .monospacedDigit()
              .foregroundStyle(.secondary)
              .frame(minWidth: 34)
            pagerButton(
              "chevron.right", help: "Next page (→)", enabled: clampedPage < pageCount - 1
            ) {
              flipPage(forward: true)
            }
          }
        }
      }

      if model.store.config.enabledCameras.isEmpty {
        EmptyStateCard(
          icon: "video.slash",
          title: "No cameras enabled",
          message: "Add a camera in Settings and it will appear here.",
          actionTitle: "Open Settings",
          action: onOpenSettings
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
      } else {
        grid
      }
    }
    .background(Style.contentFill(scheme))
    .onMoveCommand { direction in
      switch direction {
      case .left: flipPage(forward: false)
      case .right: flipPage(forward: true)
      default: break
      }
    }
  }

  private var subtitle: String {
    let count = model.store.config.enabledCameras.count
    if count == 0 { return "No cameras enabled" }
    let cameras = count == 1 ? "1 camera" : "\(count) cameras"
    guard pageCount > 1 else { return cameras }
    return "\(cameras) · Page \(clampedPage + 1) of \(pageCount)"
  }

  private func pagerButton(
    _ systemName: String, help: String, enabled: Bool, action: @escaping () -> Void
  ) -> some View {
    Button(action: action) {
      Image(systemName: systemName)
        .font(.system(size: 11, weight: .semibold))
        .foregroundStyle(.secondary)
        .frame(width: 24, height: 24)
        .contentShape(.rect)
    }
    .buttonStyle(.borderless)
    .disabled(!enabled)
    .help(help)
  }

  /// One row pair per page: up to two HStacks of 16:9 tiles, always a uniform
  /// slot grid (unfilled slots stay empty, like the old grid).
  private var grid: some View {
    VStack(spacing: 12) {
      ForEach(rows.indices, id: \.self) { rowIndex in
        HStack(spacing: 12) {
          ForEach(rows[rowIndex], id: \.self) { slot in
            switch slot {
            case .camera(let cameraID):
              if let feed = model.feedIfExists(cameraID) {
                CameraTile(feed: feed, name: model.name(for: cameraID)) {
                  onFocus(cameraID)
                }
              } else {
                emptyBox
              }
            case .pad:
              Color.clear.tileFrame()
            }
          }
        }
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .padding(16)
  }

  private enum Slot: Hashable { case camera(Int), pad }

  private var emptyBox: some View {
    VStack(spacing: 12) {
      Image(systemName: "video.badge.plus")
        .font(.system(size: 24))
      Text("No Camera")
        .font(.callout.weight(.medium))
    }
    .foregroundStyle(.secondary.opacity(0.5))
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(Color(nsColor: .labelColor).opacity(0.03))
    .clipShape(RoundedRectangle(cornerRadius: Style.tileRadius, style: .continuous))
    .overlay(
      RoundedRectangle(cornerRadius: Style.tileRadius, style: .continuous)
        .stroke(.separator, lineWidth: 1).opacity(0.5))
    .tileFrame()
  }

  /// The page's enabled cameras split into rows of `.columns` slots; slots
  /// beyond what's enabled stay empty so every page keeps the same geometry.
  private var rows: [[Slot]] {
    var slots = pageIDs.map { Slot.camera($0) }
    slots += Array(repeating: .pad, count: max(density.perPage - slots.count, 0))
    return stride(from: 0, to: slots.count, by: density.columns).map {
      Array(slots[$0 ..< min($0 + density.columns, slots.count)])
    }
  }

  private var pageIDs: [Int] {
    let enabled = model.store.config.enabledCameraIDs
    let start = clampedPage * density.perPage
    return Array(enabled[start ..< min(start + density.perPage, enabled.count)])
  }

  private func flipPage(forward: Bool) {
    let next = min(max(page + (forward ? 1 : -1), 0), pageCount - 1)
    guard next != page else { return }
    withAnimation(.snappy(duration: 0.2)) { page = next }
  }

  private var clampedPage: Int { min(max(page, 0), max(pageCount - 1, 0)) }

  private var density: GridDensity {
    model.store.config.gridDensity
  }

  private var pageCount: Int {
    max((model.store.config.enabledCameras.count + density.perPage - 1) / density.perPage, 1)
  }
}

// MARK: - Tile

private struct CameraTile: View {
  let feed: CameraFeed
  let name: String
  let onMaximize: () -> Void

  @State private var hovering = false

  var body: some View {
    VideoStage(feed: feed)
      .clipShape(RoundedRectangle(cornerRadius: Style.tileRadius, style: .continuous))
      .overlay(alignment: .topLeading) { titleBar.allowsHitTesting(false) }
      .overlay(alignment: .bottom) { hoverActions }
      .contentShape(RoundedRectangle(cornerRadius: Style.tileRadius, style: .continuous))
      .onHover { hovering = $0 }
      .onTapGesture(count: 2) { onMaximize() }
      .contextMenu {
        Button("Maximize") { onMaximize() }
        Divider()
        Button("Save Snapshot…") { feed.snapshot() }
        Button("Copy Snapshot") { feed.copySnapshot() }
      }
      .animation(.easeOut(duration: 0.16), value: hovering)
      .tileFrame()
  }

  /// Slides up only while the pointer is on the tile: a bottom scrim plus
  /// three one-click actions. The scrim itself is click-through, so a
  /// double-click anywhere on the tile still maximizes.
  @ViewBuilder private var hoverActions: some View {
    if hovering {
      ZStack(alignment: .bottomTrailing) {
        LinearGradient(
          colors: [.clear, .black.opacity(0.62)],
          startPoint: .top,
          endPoint: .bottom
        )
        .allowsHitTesting(false)

        HStack(spacing: 6) {
          actionButton("camera", "Save snapshot") { feed.snapshot() }
          actionButton("doc.on.doc", "Copy snapshot") { feed.copySnapshot() }
          actionButton("arrow.up.left.and.arrow.down.right", "Maximize") { onMaximize() }
        }
        .padding(.horizontal, 10)
        .padding(.bottom, 8)
      }
      .frame(height: 58)
      .transition(.opacity)
    }
  }

  private func actionButton(
    _ systemName: String, _ help: String, action: @escaping () -> Void
  ) -> some View {
    Button(action: action) {
      Image(systemName: systemName)
        .font(.system(size: 13, weight: .semibold))
        .foregroundStyle(.white)
        .frame(width: 28, height: 28)
        .background(.black.opacity(0.48), in: Circle())
        .overlay(Circle().strokeBorder(.white.opacity(0.18), lineWidth: 1))
    }
    .buttonStyle(.plain)
    .help(help)
  }

  private var titleBar: some View {
    HStack(spacing: 6) {
      StatusDot(state: feed.state)
      Text(name)
        .font(.callout.weight(.medium))
        .foregroundStyle(.white)
        .lineLimit(1)
    }
    .padding(.horizontal, 9)
    .padding(.vertical, 5)
    .background(Color.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 8))
    .padding(8)
    .frame(maxWidth: .infinity, alignment: .topLeading)
  }
}

extension View {
  /// Every grid tile is the same true-16:9 box that fills its row width.
  func tileFrame() -> some View {
    frame(maxWidth: .infinity)
      .aspectRatio(16 / 9, contentMode: .fit)
  }
}
