import SwiftUI
import UIKit

struct SelectableAddressBar: UIViewRepresentable {
    @Binding var text: String
    var placeholder: String
    var onSubmit: (String) -> Void
    var onPasteAndGo: ((String) -> Void)?

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeUIView(context: Context) -> UITextField {
        let tf = UITextField(frame: .zero)
        tf.delegate = context.coordinator
        tf.placeholder = placeholder
        tf.font = .systemFont(ofSize: 15, weight: .regular)
        tf.keyboardType = .URL
        tf.returnKeyType = .go
        tf.autocorrectionType = .no
        tf.autocapitalizationType = .none
        tf.clearButtonMode = .whileEditing
        tf.borderStyle = .none
        tf.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        tf.addTarget(context.coordinator, action: #selector(Coordinator.textChanged(_:)), for: .editingChanged)

        // 40pt Keyboard Quick Input Accessory Bar
        let bar = UIToolbar(frame: CGRect(x: 0, y: 0, width: UIScreen.main.bounds.width, height: 40))
        bar.barStyle = .default
        bar.isTranslucent = true

        var items: [UIBarButtonItem] = []
        for token in ["https://", ".", "/", ".com"] {
            let btn = UIBarButtonItem(title: token, style: .plain, target: context.coordinator, action: #selector(Coordinator.insertQuickToken(_:)))
            items.append(btn)
        }
        items.append(UIBarButtonItem(barButtonSystemItem: .flexibleSpace, target: nil, action: nil))
        items.append(
            UIBarButtonItem(
                title: L10n.t("📋 粘贴并前往", "📋 Paste & Go"),
                style: .plain,
                target: context.coordinator,
                action: #selector(Coordinator.pasteAndGo)
            )
        )
        items.append(
            UIBarButtonItem(
                image: UIImage(systemName: "keyboard.chevron.compact.down"),
                style: .plain,
                target: context.coordinator,
                action: #selector(Coordinator.dismissKeyboard)
            )
        )
        bar.items = items
        tf.inputAccessoryView = bar

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
            tf.becomeFirstResponder()
        }
        return tf
    }

    func updateUIView(_ uiView: UITextField, context: Context) {
        if uiView.text != text {
            uiView.text = text
        }
        context.coordinator.parent = self
    }

    final class Coordinator: NSObject, UITextFieldDelegate {
        var parent: SelectableAddressBar
        weak var textField: UITextField?

        init(_ parent: SelectableAddressBar) {
            self.parent = parent
        }

        func textFieldDidBeginEditing(_ textField: UITextField) {
            self.textField = textField
            DispatchQueue.main.async {
                textField.selectAll(nil)
            }
        }

        @objc func textChanged(_ sender: UITextField) {
            self.textField = sender
            parent.text = sender.text ?? ""
        }

        func textFieldShouldReturn(_ textField: UITextField) -> Bool {
            let val = (textField.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !val.isEmpty else { return false }
            parent.onSubmit(val)
            return true
        }

        @objc func insertQuickToken(_ sender: UIBarButtonItem) {
            guard let tf = textField, let token = sender.title else { return }
            if let range = tf.selectedTextRange {
                tf.replace(range, withText: token)
                parent.text = tf.text ?? ""
            } else {
                tf.insertText(token)
                parent.text = tf.text ?? ""
            }
        }

        @objc func pasteAndGo() {
            let pasted = UIPasteboard.general.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !pasted.isEmpty else { return }
            parent.text = pasted
            if let cb = parent.onPasteAndGo {
                cb(pasted)
            } else {
                parent.onSubmit(pasted)
            }
        }

        @objc func dismissKeyboard() {
            textField?.resignFirstResponder()
        }
    }
}
