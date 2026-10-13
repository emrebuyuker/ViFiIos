import Foundation

/// The fixed list of exam names offered in the "Sınav Ekle" flow, matching the exam types used across the
/// archive (e.g. "2019 FİNAL"). The user picks one — free text is intentionally not allowed for the exam name.
/// Each carries a canonical id (for later notification segments) and the uppercase display used in the archive.
enum ExamNameCatalog {
    static let names: [CatalogItem] = [
        CatalogItem(id: "vize", name: "VİZE"),
        CatalogItem(id: "final", name: "FİNAL"),
        CatalogItem(id: "butunleme", name: "BÜTÜNLEME"),
        CatalogItem(id: "mazeret", name: "MAZERET"),
        CatalogItem(id: "kisa-sinav", name: "KISA SINAV"),
        CatalogItem(id: "yaz-okulu", name: "YAZ OKULU"),
        CatalogItem(id: "ara-sinav", name: "ARA SINAV"),
    ]
}
