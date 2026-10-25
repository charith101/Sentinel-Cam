import Carbon.HIToolbox
import Foundation
import os

/// The one global shortcut Sentinel owns. Carbon's hot-key API is used instead
/// of an NSEvent global monitor because it needs no Accessibility permission.
enum SentinelHotKey {
  static let keyCode = UInt32(kVK_ANSI_C)
  static let modifiers = UInt32(optionKey | shiftKey)
  static let label = "⌥⇧C"
}

/// A process-wide Carbon hot-key registry. The center is a singleton because
/// the C event callback cannot capture context; it only reads the hot-key ID
/// and hops to the main actor.
@MainActor
final class GlobalHotKeyCenter {
  static let shared = GlobalHotKeyCenter()

  private let log = Logger(subsystem: "com.charith.sentinel", category: "hotkey")
  private var eventHandler: EventHandlerRef?
  private var registrations: [UInt32: (ref: EventHotKeyRef, action: @MainActor () -> Void)] = [:]
  private var nextID: UInt32 = 1

  private init() {}

  /// Registers a shortcut. Returns nil when macOS or another app already owns
  /// it, so callers can surface a useful warning instead of silently failing.
  @discardableResult
  func register(
    keyCode: UInt32, modifiers: UInt32, action: @escaping @MainActor () -> Void
  ) -> UInt32? {
    installHandlerIfNeeded()

    let id = nextID
    nextID += 1
    var ref: EventHotKeyRef?
    let status = RegisterEventHotKey(
      keyCode, modifiers, EventHotKeyID(signature: hotKeySignature, id: id),
      GetApplicationEventTarget(), 0, &ref
    )
    guard status == noErr, let ref else {
      log.error("could not register hot key \(id): OSStatus \(status)")
      return nil
    }
    registrations[id] = (ref, action)
    return id
  }

  func unregister(_ id: UInt32) {
    guard let registration = registrations.removeValue(forKey: id) else { return }
    UnregisterEventHotKey(registration.ref)
  }

  fileprivate func fire(_ id: UInt32) {
    registrations[id]?.action()
  }

  private func installHandlerIfNeeded() {
    guard eventHandler == nil else { return }
    var eventType = EventTypeSpec(
      eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
    let status = InstallEventHandler(
      GetApplicationEventTarget(),
      { _, event, _ in
        guard let event else { return OSStatus(eventNotHandledErr) }
        var hotKeyID = EventHotKeyID()
        let result = GetEventParameter(
          event, EventParamName(kEventParamDirectObject),
          EventParamType(typeEventHotKeyID), nil, MemoryLayout<EventHotKeyID>.size, nil,
          &hotKeyID
        )
        guard result == noErr, hotKeyID.signature == hotKeySignature else {
          return OSStatus(eventNotHandledErr)
        }
        let id = hotKeyID.id
        Task { @MainActor in GlobalHotKeyCenter.shared.fire(id) }
        return noErr
      },
      1, &eventType, nil, &eventHandler
    )
    if status != noErr {
      log.error("could not install hot key handler: OSStatus \(status)")
    }
  }
}

/// File-scope constant so the C callback can read it without touching a
/// main-actor-isolated static.
private let hotKeySignature: OSType = 0x5345_4E54
