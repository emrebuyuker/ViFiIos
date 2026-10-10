# ViFi iOS

Üniversitelerin geçmiş sınavlarını tek yerde toplayan sınav arşivi uygulaması (SwiftUI, iOS 17+).

> **Not:** Bu dosya Claude'a özel çalışma talimatlarını ve hızlı başvuru bilgilerini içerir. Ürün, mimari, kurulum
> ve adım adım geliştirme rehberi kökteki [`README.md`](README.md) dosyasındadır (özellikle *Geliştirici Rehberi*
> bölümü). Kod yazmadan önce ikisini birlikte oku.

---

## ⚠️ Claude İçin Kritik Talimatlar

1. **Türkçe cevap ver.** İş bittiğinde ne yapıldığını ve nasıl doğrulandığını kısa bir "bitti" özetiyle bildir.
2. **Belirsizlikte sor, varsayma.** Net olmayan her durumda kullanıcıya ayrıntılı soru sor. İstenmeyen değişiklik
   yapma, mevcut yapıyı bozma.
3. **Dosya oluşturmadan önce kontrol et.** Aynı isimli dosya var mı bak (`find . -name '<Ad>.swift'`); kopya oluşturma.
4. **Her değişiklikten sonra doğrula.** Derle, SwiftLint'i çalıştır, ilgili testleri (gerekirse tüm paketi) koştur;
   sonucu olduğu gibi raporla.
5. **Canlı Firebase'e dokunmadan önce onay al.** `vifi-831a8` projesinde kural yayını (`firebase deploy`), veri
   yazma, App Check / Authentication ayarı değişikliği ve token script'inin `--apply` ile çalıştırılması yalnızca
   kullanıcının açık onayıyla yapılır. Kalıcı veri silme işlemini kullanıcı kendisi yapar.
6. **Simülatör testi.** Başlamadan önce kullanıcıya hangi test telefon numarasıyla giriş yapılacağını sor. Oturum
   açıksa önce *Hesap › Çıkış Yap* ile çık, verilen numarayla gir, kod olarak `111111` yaz. Canlı Firebase'le
   simülatörde uygulamayı `-ViFiPhoneAuthTesting` argümanıyla başlat (yalnızca Console'daki test numaralarıyla çalışır).
7. **Sır ve kişisel veri yazma.** GitHub deposu herkese açıktır. Test telefon numaraları, App Check debug token'ları,
   kişisel e-posta adresleri, servis hesabı anahtarları ve `firebase/backups/` içeriği hiçbir dosyaya ve commit'e girmez.
8. **Modeli işe göre seç.** Mekanik işler (test, doküman, tarama) için daha hafif modeller; güvenlik kuralları,
   eşzamanlılık, mimari ve canlı ortam işleri için Opus kullan.

---

## Hızlı Referans

| Konu | Değer |
|---|---|
| **Platform** | iOS / iPadOS 17+, Swift 6 (strict concurrency), Xcode 26 |
| **UI** | SwiftUI. UIKit yalnızca `UIViewRepresentable` sarmalayıcılarında (`PDFKitView`, `ZoomableImageView`, `PhoneNumberTextField`) |
| **Mimari** | MVVM + Observation: `@Observable` view model, view tarafından `@State` ile sahiplenilir |
| **İzolasyon** | `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`; ağır iş `@concurrent nonisolated static` fonksiyonlarda |
| **DI** | `AppEnvironment` → `.environment(_:)`; `live()` (Firebase) / `mock()` (örnek veri, yalnızca Debug) |
| **Gezinme** | `Router` + `NavigationStack` (`Route.browse`, `Route.exam`) |
| **Veri** | Firebase Realtime Database (`FirebaseArchiveRepository`, disk kalıcılığı + `keepSynced`) |
| **Dosyalar** | `RemoteFileLoader`: URLSession + URLCache + disk; ID token ve App Check başlıklarıyla indirir |
| **Giriş** | Firebase Phone Auth, yalnızca +90 → `AuthServicing`, `SessionStore` |
| **Güvenlik** | App Check (Release'te App Attest, desteklemeyen cihazda DeviceCheck; Debug ve simülatörde debug provider), `firebase/` altındaki kurallar |
| **Günlük** | OSLog: `Logger.archive`, `Logger.files`, `Logger.app` |
| **Bağımlılık** | SwiftPM, Firebase 12 (`FirebaseDatabase`, `FirebaseAuth`, `FirebaseAppCheck`, `FirebaseAnalyticsCore`) |
| **Proje dosyası** | XcodeGen: `project.yml` tek kaynak; `ViFi.xcodeproj` üretilir ve depoda tutulmaz (yalnızca içindeki SwiftPM `Package.resolved` commit'lenir) |
| **Test** | Swift Testing (`ViFiTests`), XCUITest (`ViFiUITests`), Firebase Emulator (`firebase/tests`) |
| **❌ Yasak** | Combine / `ObservableObject` / `@Published`, `print`, force unwrap, CocoaPods, Storyboard/XIB, `downloadURL`'deki `token=` parametresine güvenmek |

---

## Proje Yapısı

```
ViFi-iOS/
├── CLAUDE.md                 # Bu dosya (Claude talimatları)
├── README.md                 # Ürün, mimari, kurulum, Geliştirici Rehberi
├── project.yml               # XcodeGen tanımı: hedefler, ayarlar, paketler, Info.plist
├── .swiftlint.yml            # Lint kuralları (her derlemede çalışır)
├── ViFi/
│   ├── App/                  # ViFiApp, AppDelegate (ortamı kurar), AppEnvironment, RootView (giriş kapısı), Router
│   ├── Core/
│   │   ├── Models/           # ArchivePath, ArchiveItem / ExamDocument, PhoneNumber
│   │   ├── Services/         # Protokoller (ServiceProtocols, AuthServicing), Firebase servisleri, ArchiveParser,
│   │   │                     # RemoteFileLoader, SessionStore, RecentExamsStore, App Check fabrikası
│   │   └── Utilities/        # Loadable, Logger+ViFi
│   ├── DesignSystem/         # IconBadge, durum görünümleri (Loading/Error/Empty), seviye stilleri
│   ├── Features/
│   │   ├── Home/             # Ana sayfa, son görüntülenenler, Hakkında
│   │   ├── Browse/           # Fakülte → sınav listeleri, breadcrumb
│   │   ├── Exam/             # Görsel (sayfalayıcı, yakınlaştırma) ve PDF görüntüleyiciler
│   │   ├── Auth/             # Telefon + SMS kodu ile giriş
│   │   └── Account/          # Hesap: çıkış, hesap silme (yeniden doğrulamalı)
│   ├── Resources/            # Assets, Info.plist (üretilir), String Catalog'lar, PrivacyInfo, ViFi.entitlements,
│   │                         # GoogleService-Info.plist
│   └── Preview Content/      # MockServices (örnek veri, MockAuthService) + örnek sınav dosyaları — yalnızca Debug
├── ViFiTests/                # Birim testleri (Swift Testing) + TestDoubles.swift
├── ViFiUITests/              # Arayüz testleri (örnek veriyle)
└── firebase/                 # Güvenlik kuralları, emulator testleri, token script'i (ayrıntı: firebase/README.md)
    └── backups/              # Yerel yedekler — git'e girmez, asla commit'leme
```

---

## Temel Kurallar

### Ekran ve view model
- **Ekran iki parçadır:** Dışarıdaki `XView`, bağımlılıkları `@Environment(AppEnvironment.self)` ile alır. İçerideki
  `private struct XScreen`, view model'i `@State` ile sahiplenir (`init`'te `_viewModel = State(initialValue: …)`).
  Örnekler: `HomeView`/`HomeScreen`, `BrowseView`/`BrowseScreen`, `LoginView`/`LoginScreen`.
- **View model:** `@Observable final class XViewModel`. Ekran durumu `Loadable<Value>` (`loading` / `loaded` /
  `failed(message:)`). Bağımlılıklar `@ObservationIgnored private let` ve protokol tipinde (`any ArchiveRepository`).
- **Asenkron işler:** `async/await`. `.task` ekran her göründüğünde yeniden çalışır; yalnızca yarım kalan yükleme
  yeniden başlatılır. Çift dokunmayı ve yarışı engellemek için devam eden işi işaretle (`isFetching`, `isWorking`).
- **Önizleme:** Her ekranın `#if DEBUG` içinde `#Preview`'ı vardır ve `AppEnvironment.mock()` kullanır.

### Servisler ve veri
- **Her servis bir protokolün arkasındadır:** Protokol `ServiceProtocols.swift` ya da kendi dosyasında
  (`AuthServicing.swift`). Canlı implementasyon `Core/Services/Firebase…swift`, Debug örneği
  `Preview Content/MockServices.swift`, test double'ı `ViFiTests/TestDoubles.swift`. Hepsi `AppEnvironment` üzerinden verilir.
- **Hatalar:** Kullanıcıya gösterilen hatalar `ArchiveError` / `AuthError` (Türkçe `errorDescription`). UI'da `error.userMessage`.
- **Firebase callback'leri** arka plan kuyruğunda gelir. `DataSnapshot` callback dışına çıkmaz; orada `ArchiveParser`
  ile `Sendable` modellere çevrilir. Modeller `nonisolated struct/enum … : Sendable`.
- **Firebase başlatma sırası kritik:** `AppEnvironment.live()` yalnızca `AppDelegate.environment` → `makeDefault()`
  zinciriyle (yani `UIApplication` oluştuktan sonra) çağrılır. Aksi halde Phone Auth'un APNs/bildirim yöneticileri hiç kurulmaz.
  `AppCheck.setAppCheckProviderFactory` her zaman `FirebaseApp.configure()`'dan **önce** çalışır.
- **Örnek veri modunda (`-ViFiMockData`) Firebase hiç yapılandırılmaz.** Bu modda `Auth.auth()` veya `Database.database()`
  çağırmak çökme demektir; `FirebaseAuthService.configuredAuth` gibi korumalı yolları kullan.
- **Dosya indirme:** Veritabanındaki `downloadURL`'lerin `token=` parametresi iptal edildi, kullanılmaz. Storage
  dosyaları yalnızca `RemoteFileLoader` (`canonicalURL` + `RequestAuthorizing`) üzerinden indirilir. Yeni bir indirme
  yolu eklenecekse bu yoldan geç; kimlik bilgisini yalnızca uygulamanın kendi bucket'ına gönder.

### Arayüz
- **Metinler:** Kullanıcıya görünen metinler Türkçe literal (`Text("…")`, `String(localized: "…")`). String Catalog
  (`Localizable.xcstrings`) derlemede güncellenir. Kod yorumları ve dokümantasyon yorumları İngilizce.
- **Erişilebilirlik kimlikleri UI testleriyle sözleşmedir:** Mevcutları değiştirme. Yeni etkileşimli öğeye
  `<ekran>.<öğe>` biçiminde kimlik ver (ör. `login.sendCode`, `account.signOut.confirm`, `row.<ad>`).
- **Erişilebilirlik:** Dynamic Type (`@ScaledMetric`, üst sınırla), VoiceOver etiketleri. Turuncu zeminde siyah metin
  kullan; beyaz metin 3:1 kontrastın altında kalır.
- **Analytics:** Otomatik ekran raporlama kapalı. Ekran görüntülemeleri `environment.analytics.track(.screenView(name:))` ile elle gönderilir.

### Proje ve kalite
- **XcodeGen:** Hedef, ayar, paket ve Info.plist değişikliği yalnızca `project.yml`'da yapılır, ardından
  `xcodegen generate` çalıştırılır. `ViFi/Resources/Info.plist` üretilen bir dosyadır; elle düzenleme. Entitlement
  değerleri `ViFi/Resources/ViFi.entitlements` dosyasında düzenlenir (yolu `project.yml`'de `CODE_SIGN_ENTITLEMENTS`).
- **SwiftLint** (her derlemede): satır 160 (hata 200), dosya 500 (hata 800), fonksiyon 60, tip gövdesi 300 satır,
  iç içe tip 2 seviye; `print` ve Combine yasakları özel kuralla denetlenir. Yeni uyarı bırakma.
- **Gizlilik:** Yeni bir veri türü toplanırsa `PrivacyInfo.xcprivacy` ve App Store gizlilik etiketi birlikte güncellenir.
- **Güvenlik kuralları:** `firebase/database.rules.json` ve `firebase/storage.rules` her değişiklikte emulator testleriyle
  birlikte güncellenir (`cd firebase && npm test`); yayın kullanıcı onayıyla yapılır.

---

## Komutlar

```bash
# Xcode projesini üret (project.yml değiştikten sonra)
xcodegen generate

# Derle (çıktı ./build altına)
xcodebuild -project ViFi.xcodeproj -scheme ViFi -destination 'platform=iOS Simulator,name=<simülatör>' -derivedDataPath build build

# Birim + arayüz testleri (birim testlerin host uygulaması örnek veriyle çalışır)
xcodebuild test -project ViFi.xcodeproj -scheme ViFi -destination 'platform=iOS Simulator,name=<simülatör>' -derivedDataPath build

# Lint
swiftlint lint --quiet --config .swiftlint.yml

# Firebase kural testleri (Java 21 gerekir; yalnızca yerel emulator, proje demo-vifi)
cd firebase && JAVA_HOME=/opt/homebrew/opt/openjdk@21 npm test

# Kural yayını — YALNIZCA kullanıcı onayıyla. Global CLI hesabı farklı olabilir: proje sahibi hesabı sor.
cd firebase && firebase deploy --only database,storage --project vifi-831a8 --account <proje-sahibi-hesabı>
```

### Başlatma argümanları

| Argüman | Etki |
|---|---|
| `-ViFiMockData` | Firebase ve ağ olmadan paket içi örnek arşivle çalışır (yalnızca Debug; UI testleri bunu kullanır) |
| `-ViFiSignedOut` | `-ViFiMockData` ile birlikte: giriş ekranından başlar (örnek modda kod `111111`) |
| `-ViFiPhoneAuthTesting` | Yalnızca Debug: Phone Auth uygulama doğrulamasını kapatır; yalnızca Console'daki test numaralarıyla çalışır |
| `-ViFiForceUpdate` | `-ViFiMockData` ile birlikte (yalnızca Debug): kapatılamayan zorunlu güncelleme ekranından başlar (UI testi) |

---

## Firebase

| Konu | Değer |
|---|---|
| **Proje** | `vifi-831a8` (Blaze planı; Storage bucket `vifi-831a8.appspot.com`) |
| **Canlı iOS uygulaması** | Console'daki adı *"Vifi iOS Push Notification"* → `com.BuyukerYazilim.ViFi2` (adı yanıltıcı, asıl uygulama bu) |
| **Diğer kayıtlar** | *"ViFiIOS"* → `com.BuyukerYazilim.ViFi` (eski kayıt, dokunma); Android `com.salticusteam.vifi` (henüz giriş/App Check yok, şu an kullanılmıyor) |
| **Veritabanı** | `Universitiess/<üniversite>/<fakülte>/<bölüm>/<ders>/<sınav>/<JPG\|PDF>/<pushId>/downloadURL` |
| **Güncelleme politikası** | `config/appUpdate/ios/{minimumVersion, latestVersion, storeURL, message}` — `RemoteAppUpdateChecker` okur. `minimumVersion`'ın altı kapatılamaz zorunlu ekran, `latestVersion`'dan eski kapatılabilir öneri. Herkese okunur (App Check korumalı), yazma yalnızca `admin`. `storeURL` App Store adresidir; `AppStoreLink.productURL` yedeğidir |
| **Storage** | `imagess/<uuid>.jpg`, `pdfs/<uuid>.pdf`; ileride yükleme için `pending/<uid>/<submissionId>/<dosya>` |
| **Erişim** | Arşivi (`Universitiess`, `imagess/`, `pdfs/`) yalnızca +90 numarayla giriş yapanlar ve admin okur; Storage'da yalnızca tek dosya okunur, listeleme yok. Arşive yazma yalnızca `admin: true` custom claim'i olanlarda |
| **Gönderimler** | `pendingExams/<uid>/<submissionId>` ve Storage `pending/<uid>/…`: sahibi (+90) oluşturur ve okur, bekleyen kaydını silebilir; admin okur ve yazar. Kök ve tanımsız diğer düğümler herkese kapalı |
| **App Check** | Storage, Realtime Database ve Authentication için zorunlu (enforced). Yeni simülatör/cihaz → debug token Console'a eklenmeli |
| **İndirme token'ları** | Tümü iptal edildi; uygulamanın kendi indirmeleri yeni token üretmez. Yedek yalnızca yerelde (`firebase/backups/`) |
| **Bilinen sınır** | Okuma yetkisi olan bir kullanıcı `getMetadata`/`getDownloadURL` ile tek bir dosyaya kalıcı genel bağlantı üretebilir; kurallarla kapatılamaz |

---

## 💬 Claude'a Nasıl Prompt Yazmalı?

### ✅ Doğru prompt örneği

```
Hakkında ekranına "Geri bildirim gönder" satırı ekle.
CLAUDE.md'deki Temel Kurallar'a ve README'deki Geliştirici Rehberi'ne uy;
erişilebilirlik kimliği ver, birim/UI testini ekle, derleyip testleri çalıştır.
```

### ✅ Kısa versiyon

```
Sınav listesine tarih filtresi ekle. [CLAUDE.md + Geliştirici Rehberi'ne uy, belirsizse sor]
```

### ❌ Kaçınılacak prompt

```
Firebase kurallarını güncelle ve yayınla.
```
*(Ne değişeceği belirsiz; canlı ortama onaysız dokunur. Önce değişikliği tarif et, emulator testinden sonra
yayın için ayrıca onay ver.)*

---

**Son güncelleme:** Ekim 2026
**Proje:** ViFi iOS (`com.BuyukerYazilim.ViFi2`)
