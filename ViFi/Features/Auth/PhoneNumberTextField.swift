import SwiftUI
import UIKit

/// The national part of a Turkish mobile number, formatted as `5XX XXX XX XX` while typing.
///
/// A `UITextField` underneath: a SwiftUI `TextField` whose text is reformatted on change leaves the caret at
/// its old offset, so the next digit lands in the middle of the number. Here every edit is formatted in the
/// delegate and the caret is put back after the same digit.
struct PhoneNumberTextField: UIViewRepresentable {
    @Binding var text: String
    @Binding var isFocused: Bool
    var placeholder: String = "5XX XXX XX XX"

    func makeUIView(context: Context) -> UITextField {
        let textField = UITextField()
        textField.delegate = context.coordinator
        textField.keyboardType = .numberPad
        textField.textContentType = .telephoneNumber
        textField.placeholder = placeholder
        textField.font = UIFontMetrics(forTextStyle: .title3)
            .scaledFont(for: .monospacedDigitSystemFont(ofSize: 20, weight: .regular))
        textField.adjustsFontForContentSizeCategory = true
        textField.setContentHuggingPriority(.defaultLow, for: .horizontal)
        textField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return textField
    }

    func updateUIView(_ textField: UITextField, context: Context) {
        context.coordinator.parent = self
        // While the field is being edited its own text is the newest: SwiftUI can run an update that started
        // before the latest keystroke, carrying the previous model value, and applying it would drop that key.
        // The delegate keeps the model in step with every edit, so there is nothing to push in the meantime.
        if !textField.isFirstResponder, textField.text != text {
            textField.text = text
        }
        textField.isEnabled = context.environment.isEnabled

        // Responder changes during a view update would re-enter SwiftUI; defer them to the next turn.
        if isFocused != textField.isFirstResponder {
            let shouldFocus = isFocused
            DispatchQueue.main.async {
                if shouldFocus {
                    textField.becomeFirstResponder()
                } else {
                    textField.resignFirstResponder()
                }
            }
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    final class Coordinator: NSObject, UITextFieldDelegate {
        var parent: PhoneNumberTextField

        init(parent: PhoneNumberTextField) {
            self.parent = parent
        }

        func textFieldDidBeginEditing(_ textField: UITextField) {
            if !parent.isFocused {
                parent.isFocused = true
            }
        }

        func textFieldDidEndEditing(_ textField: UITextField) {
            if parent.isFocused {
                parent.isFocused = false
            }
        }

        func textField(
            _ textField: UITextField,
            shouldChangeCharactersIn range: NSRange,
            replacementString string: String
        ) -> Bool {
            let current = textField.text ?? ""
            let edit = PhoneNumberEdit.apply(replacing: range, with: string, in: current)
            textField.text = edit.text
            if let position = textField.position(from: textField.beginningOfDocument, offset: edit.caretOffset) {
                textField.selectedTextRange = textField.textRange(from: position, to: position)
            }
            if parent.text != edit.text {
                parent.text = edit.text
            }
            // The text was set above, already formatted.
            return false
        }
    }
}

/// The pure editing rules of `PhoneNumberTextField`, separate from UIKit so they can be unit-tested.
nonisolated enum PhoneNumberEdit {
    /// The formatted text after replacing `range` (UTF-16, as UIKit reports it) of `text` with `replacement`,
    /// and the caret offset (UTF-16) that keeps the caret after the same digit.
    ///
    /// - Pasted or autofilled text (`+90 5…`, `05…`) is normalised and the caret goes to the end.
    /// - Deleting only a separator deletes the digit in front of it, as people expect from Backspace.
    static func apply(replacing range: NSRange, with replacement: String, in text: String) -> (text: String, caretOffset: Int) {
        let nsText = text as NSString
        guard range.location != NSNotFound, NSMaxRange(range) <= nsText.length else {
            let formatted = PhoneNumber.formattedInput(text)
            return (formatted, (formatted as NSString).length)
        }

        var range = range
        let removed = nsText.substring(with: range)
        if replacement.isEmpty, range.length > 0, !removed.contains(where: \.isASCIIDigitCharacter) {
            // Backspace over a space: take the digit before it as well.
            let before = nsText.substring(to: range.location)
            if let digitIndex = before.lastIndex(where: \.isASCIIDigitCharacter) {
                let location = before.utf16.distance(from: before.startIndex, to: digitIndex)
                range = NSRange(location: location, length: NSMaxRange(range) - location)
            }
        }

        let proposed = nsText.replacingCharacters(in: range, with: replacement)
        let formatted = PhoneNumber.formattedInput(proposed)
        let formattedLength = (formatted as NSString).length

        // A paste may drop a country code or trunk prefix; put the caret at the end.
        guard replacement.count <= 1 else { return (formatted, formattedLength) }

        let caretInProposed = range.location + (replacement as NSString).length
        let digitsBeforeCaret = (proposed as NSString).substring(to: caretInProposed).count(where: \.isASCIIDigitCharacter)
        return (formatted, offset(afterDigit: digitsBeforeCaret, in: formatted))
    }

    /// The UTF-16 offset just after the `count`-th digit of `text` (the end when there are fewer digits).
    private static func offset(afterDigit count: Int, in text: String) -> Int {
        guard count > 0 else { return 0 }
        var seen = 0
        var offset = 0
        for character in text {
            offset += character.utf16.count
            if character.isASCIIDigitCharacter {
                seen += 1
                if seen == count {
                    return offset
                }
            }
        }
        return offset
    }
}

private extension Character {
    nonisolated var isASCIIDigitCharacter: Bool {
        isASCII && isWholeNumber
    }
}
