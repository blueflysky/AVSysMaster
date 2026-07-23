import SwiftUI
import UIKit

struct FourFingerLongPressCaptureView: UIViewRepresentable {
  let minimumDuration: TimeInterval
  let onTriggered: () -> Void

  init(minimumDuration: TimeInterval = 1.0, onTriggered: @escaping () -> Void) {
    self.minimumDuration = minimumDuration
    self.onTriggered = onTriggered
  }

  func makeCoordinator() -> Coordinator {
    Coordinator(onTriggered: onTriggered)
  }

  func makeUIView(context: Context) -> GestureCarrierView {
    let view = GestureCarrierView()
    view.backgroundColor = .clear
    view.isUserInteractionEnabled = false

    let recognizer = UILongPressGestureRecognizer(
      target: context.coordinator,
      action: #selector(Coordinator.handleLongPress(_:))
    )
    recognizer.minimumPressDuration = minimumDuration
    recognizer.numberOfTouchesRequired = 4
    recognizer.allowableMovement = 24
    recognizer.cancelsTouchesInView = false
    view.longPressRecognizer = recognizer
    return view
  }

  func updateUIView(_ uiView: GestureCarrierView, context: Context) {}

  final class GestureCarrierView: UIView {
    var longPressRecognizer: UIGestureRecognizer?

    override func didMoveToWindow() {
      super.didMoveToWindow()
      guard let recognizer = longPressRecognizer else { return }
      recognizer.view?.removeGestureRecognizer(recognizer)
      window?.addGestureRecognizer(recognizer)
    }

    override func willMove(toWindow newWindow: UIWindow?) {
      if newWindow == nil, let recognizer = longPressRecognizer {
        recognizer.view?.removeGestureRecognizer(recognizer)
      }
      super.willMove(toWindow: newWindow)
    }
  }

  final class Coordinator: NSObject {
    private let onTriggered: () -> Void

    init(onTriggered: @escaping () -> Void) {
      self.onTriggered = onTriggered
    }

    @objc func handleLongPress(_ recognizer: UILongPressGestureRecognizer) {
      if recognizer.state == .began {
        onTriggered()
      }
    }
  }
}
