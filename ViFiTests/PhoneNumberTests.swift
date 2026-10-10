import Foundation
import Testing
@testable import ViFi

@Suite("PhoneNumber")
struct PhoneNumberTests {
    // MARK: - Parsing

    @Test("Pasted and typed numbers reduce to ten national digits", arguments: [
        "5321234567",
        "532 123 45 67",
        "0532 123 45 67",
        "05321234567",
        "0 532 123 45 67",
        "+90 532 123 45 67",
        "+905321234567",
        "+90 (532) 123-45-67",
        "0090 532 123 45 67",
        "905321234567",
        "90 532 123 45 67",
        "532-123-45-67",
        "532.123.45.67",
        "  532 123 45 67\n",
    ])
    func nationalDigitsOfPastedNumber(_ input: String) {
        #expect(PhoneNumber.nationalDigits(from: input) == "5321234567")
        #expect(PhoneNumber(input: input)?.nationalNumber == "5321234567")
    }

    @Test("A partial number keeps its digits so it can be completed", arguments: [
        ("5", "5"),
        ("53", "53"),
        ("0532", "532"),
        ("+90 532", "532"),
        ("+90", ""),
        ("0", ""),
        ("00", ""),
        ("", ""),
        ("   ", ""),
    ])
    func partialInput(input: String, expected: String) {
        #expect(PhoneNumber.nationalDigits(from: input) == expected)
        #expect(PhoneNumber(input: input) == nil)
    }

    @Test("Characters that are not ASCII digits are ignored", arguments: [
        ("abc532xyz", "532"),
        ("٥٣٢", ""),
        ("５３２", ""),
        ("5-3-2", "532"),
    ])
    func nonDigitsAreIgnored(input: String, expected: String) {
        #expect(PhoneNumber.nationalDigits(from: input) == expected)
    }

    @Test("Input longer than a national number is cut to ten digits")
    func overlongInputIsTruncated() {
        #expect(PhoneNumber.nationalDigits(from: "53212345678999") == "5321234567")
        #expect(PhoneNumber.nationalDigits(from: "+90 532 123 45 67 89") == "5321234567")
    }

    // MARK: - Validation

    @Test("Only ten digits starting with 5 are a valid number", arguments: [
        "",
        "5",
        "532123456",
        "4321234567",
        "0 432 123 45 67",
        "1234567890",
        "+44 7911 123456",
        "+1 532 123 45 67",
        "+90 212 123 45 67",
        "abc",
    ])
    func invalidNumbers(_ input: String) {
        #expect(PhoneNumber(input: input) == nil)
    }

    @Test("The national initializer is strict about length, prefix and digits", arguments: [
        "532123456",
        "53212345678",
        "05321234567",
        "4321234567",
        " 532123456",
        "532 123 45 67",
        "٥٣٢١٢٣٤٥٦٧",
        "5321234 67a",
    ])
    func strictNationalNumber(_ value: String) {
        #expect(PhoneNumber(nationalNumber: value) == nil)
    }

    @Test("A valid number exposes its E.164 and display forms")
    func valueForms() throws {
        let number = try #require(PhoneNumber(input: "0532 123 45 67"))

        #expect(number.nationalNumber == "5321234567")
        #expect(number.e164 == "+905321234567")
        #expect(number.formatted == "+90 532 123 45 67")
    }

    @Test("Numbers parsed from the same digits are equal however they were written")
    func equality() {
        #expect(PhoneNumber(input: "+90 532 123 45 67") == PhoneNumber(input: "05321234567"))
        #expect(PhoneNumber(input: "+90 532 123 45 67") != PhoneNumber(input: "05321234568"))
    }

    // MARK: - E.164

    @Test("A Turkish E.164 number round-trips")
    func e164RoundTrip() throws {
        let number = try #require(PhoneNumber(e164: "+905321234567"))

        #expect(number.nationalNumber == "5321234567")
        #expect(number.e164 == "+905321234567")
    }

    @Test("Other countries and malformed E.164 numbers are rejected", arguments: [
        "+4915112345678",
        "+1 202 555 0100",
        "905321234567",
        "5321234567",
        "+90532123456",
        "+9053212345678",
        "+90 5321234567",
        "+904321234567",
        "",
    ])
    func invalidE164(_ value: String) {
        #expect(PhoneNumber(e164: value) == nil)
    }

    // MARK: - Formatting

    @Test("National digits are grouped as far as they go", arguments: [
        ("", ""),
        ("5", "5"),
        ("53", "53"),
        ("532", "532"),
        ("5321", "532 1"),
        ("532123", "532 123"),
        ("5321234", "532 123 4"),
        ("53212345", "532 123 45"),
        ("532123456", "532 123 45 6"),
        ("5321234567", "532 123 45 67"),
        ("53212345678", "532 123 45 67"),
    ])
    func formatNational(digits: String, expected: String) {
        #expect(PhoneNumber.formatNational(digits) == expected)
    }

    @Test("Live formatting turns any pasted form into 5XX XXX XX XX", arguments: [
        ("05321234567", "532 123 45 67"),
        ("+90 532 123 45 67", "532 123 45 67"),
        ("0090 532 123 45 67", "532 123 45 67"),
        ("532", "532"),
        ("0532 12", "532 12"),
        ("", ""),
    ])
    func formattedInput(input: String, expected: String) {
        #expect(PhoneNumber.formattedInput(input) == expected)
    }

    @Test("Formatting is idempotent, so re-formatting the field's own text changes nothing", arguments: [
        "5", "532", "5321", "532123", "5321234", "53212345", "532123456", "5321234567",
    ])
    func formattingIsIdempotent(digits: String) {
        let once = PhoneNumber.formattedInput(digits)

        #expect(PhoneNumber.formattedInput(once) == once)
        #expect(PhoneNumber.nationalDigits(from: once) == digits)
    }

    @Test("Deleting from the formatted text keeps the remaining digits")
    func deletingDigits() {
        #expect(PhoneNumber.formattedInput("532 123 45 6") == "532 123 45 6")
        #expect(PhoneNumber.formattedInput("532 123 45 ") == "532 123 45")
        #expect(PhoneNumber.formattedInput("532 123 ") == "532 123")
    }
}

@Suite("VerificationCode")
struct VerificationCodeTests {
    @Test("Only the first six ASCII digits are kept", arguments: [
        ("123456", "123456"),
        ("123 456", "123456"),
        ("12-34-56", "123456"),
        ("1234567", "123456"),
        ("12345", "12345"),
        ("ab12cd", "12"),
        ("١٢٣٤٥٦", ""),
        ("", ""),
    ])
    func digits(input: String, expected: String) {
        #expect(VerificationCode.digits(from: input) == expected)
    }

    @Test("Codes have six digits")
    func length() {
        #expect(VerificationCode.length == 6)
    }
}

@Suite("AuthUser")
struct AuthUserTests {
    @Test("A Turkish number is formatted for display")
    func formattedTurkishNumber() {
        #expect(Fixture.user.formattedPhoneNumber == "+90 532 123 45 67")
    }

    @Test("Another country's number is shown as it is")
    func foreignNumber() {
        let user = AuthUser(id: "user-2", phoneNumber: "+4915112345678")

        #expect(user.formattedPhoneNumber == "+4915112345678")
    }

    @Test("A user without a number has nothing to show")
    func noNumber() {
        #expect(AuthUser(id: "user-3", phoneNumber: nil).formattedPhoneNumber == nil)
    }
}

/// The editing rules of the number field: every edit comes out formatted, with the caret after the same digit.
@Suite("PhoneNumberEdit")
struct PhoneNumberEditTests {
    private func edit(
        _ text: String,
        replacing location: Int,
        length: Int = 0,
        with replacement: String
    ) -> (text: String, caretOffset: Int) {
        PhoneNumberEdit.apply(replacing: NSRange(location: location, length: length), with: replacement, in: text)
    }

    @Test("Typing a digit at the end appends it and keeps the caret at the end", arguments: [
        ("", "5", "5", 1),
        ("5", "3", "53", 2),
        ("53", "2", "532", 3),
        ("532", "1", "532 1", 5),
        ("532 123", "4", "532 123 4", 9),
        ("532 123 45 6", "7", "532 123 45 67", 13),
    ])
    func typingAtTheEnd(text: String, typed: String, expected: String, caret: Int) {
        let result = edit(text, replacing: (text as NSString).length, with: typed)

        #expect(result.text == expected)
        #expect(result.caretOffset == caret)
    }

    @Test("A digit beyond the tenth is dropped")
    func eleventhDigit() {
        let result = edit("532 123 45 67", replacing: 13, with: "8")

        #expect(result.text == "532 123 45 67")
        #expect(result.caretOffset == 13)
    }

    @Test("Typing in the middle keeps the caret after the typed digit")
    func typingInTheMiddle() {
        let result = edit("532 123", replacing: 2, with: "9")

        #expect(result.text == "539 212 3")
        #expect(result.caretOffset == 3)
    }

    @Test("Backspace removes the last digit")
    func backspaceAtTheEnd() {
        let result = edit("532 1", replacing: 4, length: 1, with: "")

        #expect(result.text == "532")
        #expect(result.caretOffset == 3)
    }

    @Test("Backspace over a space removes the digit in front of it")
    func backspaceOverSeparator() {
        let result = edit("532 1", replacing: 3, length: 1, with: "")

        #expect(result.text == "531")
        #expect(result.caretOffset == 2)
    }

    @Test("Deleting a selection that spans digits keeps the rest")
    func deletingASelection() {
        let result = edit("532 123", replacing: 3, length: 3, with: "")

        #expect(result.text == "532 3")
        #expect(result.caretOffset == 3)
    }

    @Test("Deleting everything empties the field")
    func deletingEverything() {
        let result = edit("532 123 45 67", replacing: 0, length: 13, with: "")

        #expect(result.text.isEmpty)
        #expect(result.caretOffset == 0)
    }

    @Test("A pasted number with a country code or trunk prefix is normalised, caret at the end", arguments: [
        "+90 532 123 45 67",
        "+905321234567",
        "05321234567",
        "0532 123 45 67",
        "0090 532 123 45 67",
    ])
    func paste(_ pasted: String) {
        let result = edit("", replacing: 0, with: pasted)

        #expect(result.text == "532 123 45 67")
        #expect(result.caretOffset == 13)
    }

    @Test("Pasting over the whole text replaces it")
    func pasteOverSelection() {
        let result = edit("555 111", replacing: 0, length: 7, with: "+90 532 123 45 67")

        #expect(result.text == "532 123 45 67")
        #expect(result.caretOffset == 13)
    }

    @Test("A leading trunk zero typed by hand is not shown")
    func typedTrunkZero() {
        let result = edit("", replacing: 0, with: "0")

        #expect(result.text.isEmpty)
        #expect(result.caretOffset == 0)
    }

    @Test("Characters other than digits are not entered")
    func typedLetter() {
        let result = edit("532", replacing: 3, with: "a")

        #expect(result.text == "532")
        #expect(result.caretOffset == 3)
    }

    @Test("An invalid range formats the whole text, caret at the end", arguments: [
        NSRange(location: NSNotFound, length: 0),
        NSRange(location: 10, length: 2),
        NSRange(location: 3, length: 50),
    ])
    func invalidRange(range: NSRange) {
        let result = PhoneNumberEdit.apply(replacing: range, with: "1", in: "532123")

        #expect(result.text == "532 123")
        #expect(result.caretOffset == 7)
    }
}
