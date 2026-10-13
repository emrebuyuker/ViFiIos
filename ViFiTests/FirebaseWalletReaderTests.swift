import FirebaseFirestore
import Foundation
import Testing
@testable import ViFi

@Suite("FirebaseWalletReader.parse")
struct FirebaseWalletReaderTests {
    @Test("A balance and timestamp are parsed")
    func parsesBalanceAndTimestamp() {
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let wallet = FirebaseWalletReader.parse([
            "balance": 250,
            "updatedAt": Timestamp(date: date),
        ])
        #expect(wallet == CoinWallet(balance: 250, updatedAt: date))
    }

    @Test("A missing document reads as the empty wallet")
    func missingDocument() {
        #expect(FirebaseWalletReader.parse(nil) == .empty)
    }

    @Test("A missing balance field reads as zero")
    func missingBalance() {
        #expect(FirebaseWalletReader.parse(["updatedAt": Timestamp(date: Date())]).balance == 0)
    }

    @Test("A negative balance is clamped to zero")
    func clampsNegativeBalance() {
        #expect(FirebaseWalletReader.parse(["balance": -40]).balance == 0)
    }

    @Test("A non-numeric balance reads as zero")
    func nonNumericBalance() {
        #expect(FirebaseWalletReader.parse(["balance": "lots"]).balance == 0)
    }
}
