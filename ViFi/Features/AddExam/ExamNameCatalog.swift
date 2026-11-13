import Foundation

/// The fixed list of exam names offered in the "Sınav Ekle" flow (owner decision K27, 14 Nov 2026), in display order.
/// The user picks one — free text is intentionally not allowed for the exam name. The submitted exam text stays
/// `"<yıl> <AD>"`; each entry also has a stable slug id (unique per entry) and the `ExamType` its title parses to.
/// Android shows the same list in the same order (`STRUCTURED-EXAMS.md`).
enum ExamNameCatalog {
    struct Entry: Sendable {
        let id: String
        let name: String
        let examType: ExamType

        var catalogItem: CatalogItem { CatalogItem(id: id, name: name) }
    }

    static let entries: [Entry] = [
        Entry(id: "vize", name: "VİZE", examType: .vize),
        Entry(id: "ara-sinav", name: "ARA SINAV", examType: .araSinav),
        Entry(id: "final", name: "FİNAL", examType: .final),
        Entry(id: "butunleme", name: "BÜTÜNLEME", examType: .butunleme),
        Entry(id: "mazeret", name: "MAZERET", examType: .mazeret),
        Entry(id: "tek-ders", name: "TEK DERS", examType: .tekDers),
        Entry(id: "ek-sinav", name: "EK SINAV", examType: .ekSinav),
        Entry(id: "yaz-okulu-vize", name: "YAZ OKULU VİZE", examType: .vize),
        Entry(id: "yaz-okulu-ara-sinav", name: "YAZ OKULU ARA SINAV", examType: .araSinav),
        Entry(id: "yaz-okulu-final", name: "YAZ OKULU FİNAL", examType: .final),
        Entry(id: "kisa-sinav", name: "KISA SINAV", examType: .kisaSinav),
        Entry(id: "muafiyet", name: "MUAFİYET SINAVI", examType: .muafiyet),
        Entry(id: "seviye-tespit", name: "SEVİYE TESPİT SINAVI", examType: .seviyeTespit),
        Entry(id: "uygulama", name: "UYGULAMA SINAVI", examType: .uygulama),
        Entry(id: "laboratuvar", name: "LABORATUVAR", examType: .laboratuvar),
        Entry(id: "odev", name: "ÖDEV", examType: .odev),
        Entry(id: "proje", name: "PROJE", examType: .proje),
        Entry(id: "calisma-sorulari", name: "ÇALIŞMA SORULARI", examType: .calismaSorulari),
        Entry(id: "cozumlu-sorular", name: "ÇÖZÜMLÜ SORULAR", examType: .cozumluSorular),
    ]

    /// The picker options (`CatalogPickerView` takes plain catalog items).
    static let names: [CatalogItem] = entries.map(\.catalogItem)
}
