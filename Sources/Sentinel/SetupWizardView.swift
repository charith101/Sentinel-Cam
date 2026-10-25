import SwiftUI

/// First-run / "Add Camera…" entry point. The form itself lives in
/// `DeviceEditorView` so adding and editing share exactly one implementation.
struct SetupWizardView: View {
  let store: ConfigStore
  var onFinish: () -> Void

  var body: some View {
    DeviceEditorView(
      store: store, deviceID: nil, onboarding: !store.isConfigured, onFinish: onFinish)
  }
}
