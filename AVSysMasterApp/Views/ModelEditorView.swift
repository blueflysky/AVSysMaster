import SwiftUI

struct ModelEditorView: View {
  @EnvironmentObject private var modelStore: UnifiedModelStore
  @State private var fieldKey = "site"
  @State private var fieldValue = "room-a"
  @State private var alertMessage: AlertMessage?

  var body: some View {
    Form {
      Section("Schema") {
        Stepper("schemaVersion: \(modelStore.draft.meta.schemaVersion)", value: Binding(
          get: { modelStore.draft.meta.schemaVersion },
          set: { modelStore.draft.meta.schemaVersion = max(1, $0) }
        ), in: 1...99)
      }

      Section("Custom Fields") {
        TextField("Field Key", text: $fieldKey)
        TextField("Field Value", text: $fieldValue)
        Button("Apply to all controls") {
          modelStore.updateModelField(key: fieldKey, value: fieldValue)
        }
      }

      Section("Publish Flow") {
        Button(L10n.publish) {
          if !modelStore.publishDraft() {
            alertMessage = AlertMessage(message: L10n.validationFailed)
          }
        }
        Button(L10n.rollback) {
          modelStore.rollback()
        }
      }
    }
    .alert(item: $alertMessage) { item in
      Alert(title: Text(item.message))
    }
  }
}
