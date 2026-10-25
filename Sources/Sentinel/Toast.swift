import AppKit
import Observation
import SwiftUI

/// Severity for the toast banner.
enum ToastSeverity {
  case success, info, warning, error
}

/// A single toast message. The queue shows one at a time.
struct Toast: Identifiable, Equatable {
  let id: UUID
  let severity: ToastSeverity
  let message: String
  let detail: String?
  let actionTitle: String
  let action: (@MainActor () -> Void)?

  init(
    _ message: String, detail: String? = nil, severity: ToastSeverity = .info,
    actionTitle: String = "Retry", action: (@MainActor () -> Void)? = nil
  ) {
    id = UUID()
    self.message = message
    self.detail = detail
    self.severity = severity
    self.actionTitle = actionTitle
    self.action = action
  }

  static func == (lhs: Toast, rhs: Toast) -> Bool { lhs.id == rhs.id }
}

/// A tiny FIFO of toasts. One is visible at a time; the rest wait their turn.
/// Every mutation happens on the main actor, so the UI and the presenter never
/// race over `current`.
@MainActor
@Observable
final class ToastQueue {
  private(set) var current: Toast?
  @ObservationIgnored private var pending: [Toast] = []
  @ObservationIgnored private var dismissTask: Task<Void, Never>?
  @ObservationIgnored private var advanceTask: Task<Void, Never>?

  func show(_ toast: Toast) {
    advanceTask?.cancel()
    advanceTask = nil
    if current != nil {
      pending.append(toast)
      if pending.count > 4 { pending.removeFirst() }
      return
    }
    current = toast
    scheduleDismiss()
  }

  /// Dismiss the visible toast and immediately make room for the next one.
  func dismiss() {
    dismissTask?.cancel()
    current = nil
    scheduleAdvance()
  }

  /// Replace the visible toast immediately. Used for progress → result pairs
  /// ("Checking recorder…" → "Recorder online") where waiting in the queue
  /// would make the result feel stale.
  func replace(with toast: Toast) {
    dismissTask?.cancel()
    advanceTask?.cancel()
    advanceTask = nil
    current = toast
    scheduleDismiss()
  }

  private func scheduleDismiss() {
    dismissTask?.cancel()
    dismissTask = Task { @MainActor [weak self] in
      try? await Task.sleep(for: .seconds(3.5))
      guard !Task.isCancelled else { return }
      self?.current = nil
      self?.scheduleAdvance()
    }
  }

  private func scheduleAdvance() {
    advanceTask?.cancel()
    advanceTask = Task { @MainActor [weak self] in
      // A short gap lets the outgoing card animate away before the next one
      // arrives. If a new toast is shown in the meantime, `show` cancels us.
      try? await Task.sleep(for: .milliseconds(260))
      guard !Task.isCancelled, let self, self.current == nil else { return }
      guard !self.pending.isEmpty else { return }
      self.current = self.pending.removeFirst()
      self.scheduleDismiss()
    }
  }
}

// MARK: - Presentation

/// A one-line, dark banner. It sits on a transparent, non-activating panel so
/// it can appear over the popover, the main window, or a Save panel without
/// stealing focus.
struct ToastView: View {
  let toast: Toast
  let onDismiss: () -> Void

  var body: some View {
    HStack(spacing: 10) {
      Image(systemName: toast.severity.icon)
        .font(.system(size: 14, weight: .semibold))
        .foregroundStyle(tint)
        .frame(width: 18)

      VStack(alignment: .leading, spacing: 2) {
        Text(toast.message)
          .font(.footnote.weight(.semibold))
          .lineLimit(1)
        if let detail = toast.detail {
          Text(detail)
            .font(.caption2)
            .foregroundStyle(.white.opacity(0.62))
            .lineLimit(1)
        }
      }

      Spacer(minLength: 8)

      if let action = toast.action {
        Button(toast.actionTitle) { action() }
          .buttonStyle(.borderless)
          .controlSize(.small)
          .foregroundStyle(tint)
      }

      Button { onDismiss() } label: {
        Image(systemName: "xmark")
          .font(.system(size: 10, weight: .bold))
          .foregroundStyle(.white.opacity(0.55))
      }
      .buttonStyle(.borderless)
      .help("Dismiss")
    }
    .foregroundStyle(.white)
    .padding(.horizontal, 12)
    .padding(.vertical, 9)
    .background(
      Color.black.opacity(0.82), in: RoundedRectangle(cornerRadius: 10, style: .continuous)
    )
    .overlay(
      RoundedRectangle(cornerRadius: 10, style: .continuous)
        .strokeBorder(.white.opacity(0.12), lineWidth: 1)
    )
    .overlay(alignment: .leading) {
      Capsule()
        .fill(tint)
        .frame(width: 3)
        .padding(.vertical, 7)
    }
    .shadow(color: .black.opacity(0.3), radius: 12, y: 5)
  }

  private var tint: Color {
    switch toast.severity {
    case .success: Style.successColor
    case .info: Style.accentColor
    case .warning: Style.warningColor
    case .error: Style.errorColor
    }
  }
}

private extension ToastSeverity {
  var icon: String {
    switch self {
    case .success: "checkmark.circle.fill"
    case .info: "info.circle.fill"
    case .warning: "exclamationmark.triangle.fill"
    case .error: "xmark.circle.fill"
    }
  }
}

/// The app's single toast host. A transparent panel floats at the top-right of
/// the screen under the menu bar; it is ordered out whenever the queue is empty.
@MainActor
final class ToastPresenter {
  private static let panelWidth: CGFloat = 380
  private static let panelHeight: CGFloat = 76

  private let queue: ToastQueue
  private let panel: NSPanel
  private var screenObserver: NSObjectProtocol?

  init(queue: ToastQueue) {
    self.queue = queue
    panel = NSPanel(
      contentRect: NSRect(x: 0, y: 0, width: Self.panelWidth, height: Self.panelHeight),
      styleMask: [.borderless, .nonactivatingPanel],
      backing: .buffered,
      defer: true
    )
    panel.contentViewController = NSHostingController(rootView: ToastPanelView(queue: queue))
    panel.isOpaque = false
    panel.backgroundColor = .clear
    panel.hasShadow = false
    panel.level = .floating
    panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle, .stationary]
    panel.hidesOnDeactivate = false
    panel.isMovable = false
    panel.isReleasedWhenClosed = false
    panel.becomesKeyOnlyIfNeeded = true
    panel.isFloatingPanel = true

    screenObserver = NotificationCenter.default.addObserver(
      forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
    ) { [weak self] _ in
      Task { @MainActor in self?.refresh() }
    }

    observeQueue()
  }

  private func observeQueue() {
    withObservationTracking {
      _ = queue.current
    } onChange: { [weak self] in
      Task { @MainActor in
        self?.refresh()
        self?.observeQueue()
      }
    }
  }

  private func refresh() {
    guard queue.current != nil else {
      panel.orderOut(nil)
      return
    }
    let mouse = NSEvent.mouseLocation
    let screen =
      NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
      ?? NSScreen.screens.first
    guard let screen else { return }
    let visible = screen.visibleFrame
    let origin = NSPoint(
      x: visible.maxX - Self.panelWidth - 12,
      y: visible.maxY - Self.panelHeight - 8
    )
    panel.setFrame(
      NSRect(origin: origin, size: NSSize(width: Self.panelWidth, height: Self.panelHeight)),
      display: true
    )
    panel.orderFrontRegardless()
  }
}

private struct ToastPanelView: View {
  let queue: ToastQueue

  var body: some View {
    VStack(spacing: 0) {
      if let toast = queue.current {
        ToastView(toast: toast) { queue.dismiss() }
          .id(toast.id)
          .padding(.top, 8)
          .padding(.trailing, 8)
          .transition(.move(edge: .top).combined(with: .opacity))
      }
      Spacer(minLength: 0)
    }
    .frame(width: 380, height: 76, alignment: .topTrailing)
    .tint(Style.accentColor)
    .animation(.snappy(duration: 0.24), value: queue.current)
    .allowsHitTesting(queue.current != nil)
  }
}
