import Foundation

/// A Turkish mobile number (`+90 5XX XXX XX XX`), the only kind of number ViFi signs in with.
///
/// Pure parsing and formatting, independent of Firebase, so the login screen's input handling is unit-testable.
nonisolated struct PhoneNumber: Hashable, Sendable {
    /// The country calling code shown as a fixed prefix in front of the input.
    static let countryCode = "+90"
    /// Digits of a national mobile number, without the trunk prefix `0`.
    static let nationalLength = 10

    /// Ten digits starting with `5`, e.g. `5321234567`.
    let nationalNumber: String

    /// `nil` unless `nationalNumber` is exactly ten ASCII digits starting with `5`.
    init?(nationalNumber: String) {
        guard nationalNumber.count == Self.nationalLength,
              nationalNumber.first == "5",
              nationalNumber.allSatisfy(\.isASCIIDigit) else {
            return nil
        }
        self.nationalNumber = nationalNumber
    }

    /// Parses whatever the user typed or pasted: `532 123 45 67`, `0532-123-45-67`, `+90 532 123 45 67`…
    init?(input: String) {
        self.init(nationalNumber: Self.nationalDigits(from: input))
    }

    /// Parses an E.164 number as Firebase reports it (`+905321234567`); `nil` for other countries.
    init?(e164: String) {
        guard e164.hasPrefix(Self.countryCode) else { return nil }
        self.init(nationalNumber: String(e164.dropFirst(Self.countryCode.count)))
    }

    /// `+905321234567`, the format phone verification expects.
    var e164: String {
        Self.countryCode + nationalNumber
    }

    /// `+90 532 123 45 67`, for display.
    var formatted: String {
        "\(Self.countryCode) \(Self.formatNational(nationalNumber))"
    }
}

// MARK: - Input handling

extension PhoneNumber {
    /// The national digits in `input` (at most ten), with any country code or trunk prefix removed.
    ///
    /// Accepts the formats people paste — `+90 5…`, `0090 5…`, `90 5…`, `05…` — with spaces, dashes,
    /// dots or parentheses. A partial number keeps its digits so it can be completed.
    nonisolated static func nationalDigits(from input: String) -> String {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        var digits = Substring(trimmed.filter(\.isASCIIDigit))

        if digits.hasPrefix("0090") {
            digits = digits.dropFirst(4)
        } else if digits.hasPrefix("90"), trimmed.hasPrefix("+") || digits.count > nationalLength {
            // National mobile numbers start with 5, so a leading 90 is the country code.
            digits = digits.dropFirst(2)
        }
        while digits.first == "0" {
            digits = digits.dropFirst()
        }
        return String(digits.prefix(nationalLength))
    }

    /// Groups up to ten national digits as `5XX XXX XX XX`; partial input is grouped as far as it goes.
    nonisolated static func formatNational(_ digits: String) -> String {
        let groupSizes = [3, 3, 2, 2]
        var groups: [Substring] = []
        var remaining = Substring(digits.prefix(nationalLength))
        for size in groupSizes where !remaining.isEmpty {
            groups.append(remaining.prefix(size))
            remaining = remaining.dropFirst(size)
        }
        return groups.joined(separator: " ")
    }

    /// The user's input reformatted as `5XX XXX XX XX` (live formatting of the text field).
    nonisolated static func formattedInput(_ input: String) -> String {
        formatNational(nationalDigits(from: input))
    }
}

/// Verification codes sent by SMS.
nonisolated enum VerificationCode {
    /// Firebase phone verification codes are six digits.
    static let length = 6

    /// The ASCII digits of `input`, at most `length` of them (autofilled or pasted codes may contain spaces).
    static func digits(from input: String) -> String {
        String(input.filter(\.isASCIIDigit).prefix(length))
    }
}

private extension Character {
    /// `0`–`9` only; `isNumber` would also accept other scripts' digits and fractions.
    nonisolated var isASCIIDigit: Bool {
        isASCII && isWholeNumber
    }
}
