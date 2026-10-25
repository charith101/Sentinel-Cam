import Observation

/// Owns per-camera feeds. Decoding is demand-driven: `syncVisible` starts exactly the
/// cameras on screen and stops every other one, so hidden/minimized windows cost zero CPU.
@MainActor
@Observable
final class GridModel {
  let store: ConfigStore
  private(set) var feeds: [CameraFeed] = []

  /// Drives whether streams may run at all (window on screen = true).
  var windowVisible = false {
    didSet {
      guard windowVisible != oldValue, !windowVisible else { return }
      stopAll()
    }
  }

  /// View pokes this to force a re-sync (e.g. restore from close).
  var resyncTick = 0

  /// View pokes this to switch to the settings page.
  var settingsTick = 0

  /// View pokes this to switch to the all-cameras grid page.
  var gridTick = 0

  /// Set from the menu bar preview: tap the video to open that camera maximized.
  var requestedCamera: Int?

  /// Set on first run (or from the menu) to present the setup wizard once the
  /// main window exists. MainView consumes it.
  var wantsSetup = false

  init(store: ConfigStore) {
    self.store = store
  }

  func feed(for cameraID: Int) -> CameraFeed {
    if let existing = feeds.first(where: { $0.cameraID == cameraID }) { return existing }
    let feed = CameraFeed(cameraID: cameraID, store: store)
    feeds.append(feed)
    return feed
  }

  func feedIfExists(_ cameraID: Int) -> CameraFeed? {
    feeds.first { $0.cameraID == cameraID }
  }

  func syncVisible(_ ids: [Int], force: Bool = false) {
    guard windowVisible else { stopAll(); return }
    if force {
      for feed in feeds where ids.contains(feed.cameraID) { feed.stop() }
    }
    for feed in feeds where !ids.contains(feed.cameraID) { feed.stop() }
    for id in ids where feedIfExists(id)?.isStreaming != true {
      feed(for: id).start()
    }
    pruneIdleFeeds(keeping: ids)
  }

  func stopAll() {
    feeds.forEach { $0.stop() }
    pruneIdleFeeds(keeping: [])
  }

  /// A long session can visit many cameras. Idle feeds keep an
  /// `AVSampleBufferDisplayLayer` (and possibly an audio engine) alive, so cap
  /// them instead of letting GPU memory grow with every camera ever opened.
  /// Only feeds that are stopped and not on screen are eligible.
  private func pruneIdleFeeds(keeping visible: [Int], limit: Int = 8) {
    let idle = feeds.filter { !$0.isStreaming && !visible.contains($0.cameraID) }
    guard idle.count > limit else { return }
    let doomed = Set(idle.prefix(idle.count - limit).map(\.cameraID))
    for feed in feeds where doomed.contains(feed.cameraID) { feed.stop() }
    feeds.removeAll { doomed.contains($0.cameraID) }
  }

  func name(for cameraID: Int) -> String {
    store.config.name(for: cameraID)
  }

  func label(for cameraID: Int) -> String {
    store.config.label(for: cameraID)
  }
}
