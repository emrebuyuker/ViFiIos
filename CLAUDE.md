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
| **UI** | SwiftUI. UIKit yalnızca `UIViewRepresentable` sarmalayıcılarında (`PDFKitView`, `ZoomableImageView`, `ProtectedImageView`, `PhoneNumberTextField`) |
| **Mimari** | MVVM + Observation: `@Observable` view model, view tarafından `@State` ile sahiplenilir |
| **İzolasyon** | `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`; ağır iş `@concurrent nonisolated static` fonksiyonlarda |
| **DI** | `AppEnvironment` → `.environment(_:)`; `live()` (Firebase) / `mock()` (örnek veri, yalnızca Debug) |
| **Gezinme** | `Router` + `NavigationStack` (`Route.browse`, `Route.exam`) |
| **Veri** | **Arşiv:** Cloud Firestore (isimli `vifi` DB → `FirestoreArchiveRepository` + kalıcı önbellek; giriş sonrası `ArchivePrefetcher` ile çevrimdışı ısıtma). **Bildirimler ve kullanıcı başı durum (inbox, cihaz, ayarlar, kilitler, cüzdan):** Firestore `vifi` DB. **Profil ve force-update config:** Realtime Database (RTDB; bildirim kitlesi de profillerden okunur). RTDB arşiv repo'su (`FirebaseArchiveRepository`) + `Universitiess` ağacı rollback için duruyor (bkz. `FIRESTORE-MIGRATION.md`). **Yapılandırılmış sınav (4.2.0):** aynı `vifi` DB'de `questions` (yayınlanmış, düz) + `examConversions` (admin taslak/iş) + `questionPools` + `subjects` + `aiUsage`; sınav `exams/<id>.format == structured`, orijinal `files` korunur (bkz. *Temel Kurallar › Yapılandırılmış sınavlar*) |
| **Bildirimler** | Hedefli bildirim sistemi, **sunucu gönderir** (Cloud Functions, `firebase/functions/notifications/`): veri **Cloud Firestore** (`notifications`, `announcements`, `users/<uid>/{inbox,devices,settings}`; ayrıntı: *Firebase › Bildirim sistemi*). İstemci: `InboxStore` (iki kaynak + `readAt`), `NotificationRouter` (push dokunuşu), `DeviceRegistrationStore` (FCM token), `NotificationSettingsStore` + `NotificationPromptCoordinator` (izin/onay akışı), admin `NotificationComposer`. Push görseli + rozet: `ViFiNotificationService` extension. 4.2.0'da admin'e üç otomatik bildirim eklenir: `conversionReady` (taslak hazır), `conversionFailed`, `conversionBudgetExceeded` (aylık yapay zekâ sınırı). Hepsi `admins` kitlesi, aksiyonsuz, onay süzgecine tabi değil. **Backend canlıda (30 Ekim 2026)**; 4.1.0 (10) incelemeden geri çekildi; ekran koruması + reCAPTCHA SDK ile **4.1.0 (11)** 8 Kasım 2026'da yeniden incelemeye gönderildi (onaylanınca otomatik yayın) — bkz. *Firebase › Bildirim sistemi › Yayın durumu* |
| **Dosyalar** | `RemoteFileLoader`: URLSession + URLCache + disk; ID token ve App Check başlıklarıyla indirir |
| **Giriş** | Firebase Phone Auth, yalnızca +90 → `AuthServicing`, `SessionStore`. Telefon doğrulaması reCAPTCHA Enterprise belirteci taşır (SMS Defense; bkz. *Firebase › SMS Defense*) |
| **Güvenlik** | App Check (Release'te App Attest, desteklemeyen cihazda DeviceCheck; Debug ve simülatörde debug provider), `firebase/` altındaki kurallar |
| **Ekran koruması** | Sınav pikseli çizen her UIKit yüzeyi `CaptureShieldedView` içinde (`CaptureShield` katman takası: ekran görüntüsü/kayıtta sayfa yerine "Sınav içeriği korumalıdır" kartı). Yedekler: kayıt/yansıtma örtüsü (`screenCaptureProtection()`, `CaptureCoverPolicy`), app switcher örtüsü (`appSwitcherCover()`). Uzaktan anahtar RTDB `config/captureProtection/ios`. Fail-open. **Cihazda doğrulanmadan "korunuyor" denmez** (ayrıntı: *Temel Kurallar › Ekran koruması*) |
| **Yapılandırılmış sınavlar (4.2.0)** | Sınavı sayfa yerine **soru soru** gösterir: metin (Markdown + LaTeX, SwiftMath), şıklar, orijinal sayfadan kırpılmış şekil, "Cevabı Göster" + adım adım çözüm + yapay zekâ notu. Sorular sunucuda yapay zekâyla (Vertex AI: **Claude Opus 5.5 veya Gemini Pro**, admin her işlemde seçer) üretilir; **iki onaylı** akış (1. onay coin + dönüştürme, 2. onay yayın); aylık **50 $** sınır. Sözleşme: `firebase/functions/conversions/schema.js` ↔ iOS `ExamQuestion` / `ExamConversion` + parser'lar; Android için yerel `STRUCTURED-EXAMS.md`. **Canlıya HİÇBİR ŞEY yayınlanmadı** (kurallar, indeksler, Function'lar, kuyruk, Vertex AI sahibin onayını ve 4.1.0'ın yayınını bekliyor); 4.2.0 Android hazır olana kadar incelemeye gönderilmez (K16). Ayrıntı: *Temel Kurallar › Yapılandırılmış sınavlar (4.2.0)* |
| **Günlük** | OSLog: `Logger.archive`, `Logger.files`, `Logger.app` |
| **Hedefler** | `ViFi` (uygulama), `ViFiNotificationService` (Notification Service Extension, uygulamaya gömülü; paylaşılan kod yalnızca `NotificationBadgeCounter.swift`), `ViFiTests`, `ViFiUITests` |
| **Bağımlılık** | SwiftPM, Firebase 12 (`FirebaseFirestore`, `FirebaseDatabase`, `FirebaseAuth`, `FirebaseAppCheck`, `FirebaseAnalyticsCore`, `FirebaseStorage`, `FirebaseFunctions`, `FirebaseMessaging`) + **GoogleMaps / GooglePlaces 11.2.0** (yalnızca admin konum seçicisi) + **RecaptchaEnterprise 18.9.1** (telefon girişi SMS Defense; yalnızca `ViFi` hedefine bağlı, extension'a değil; `-ObjC` linker bayrağı şart) + **SwiftMath 1.7.3** (`exactVersion`; formül çizimi, yalnızca `ViFi` hedefine bağlı, extension'a değil). Cloud Functions: Node 22, `firebase-functions` v2 (+ bir adet v1 auth tetikleyicisi); 4.2.0 yapay zekâ hattı: `@anthropic-ai/vertex-sdk` (Claude), `@google/genai` (Gemini, `vertexai: true`), `sharp` (şekil kırpma), `pdfjs-dist` + `@napi-rs/canvas` (PDF sayfası çizimi); kimlik Functions servis hesabıdır, API anahtarı yok |
| **Gizli yapılandırma** | `Config/Base.xcconfig` (commit'li) + `Config/Secrets.xcconfig` (**git-dışı**, şablon `Config/Secrets.example.xcconfig`): `GOOGLE_MAPS_API_KEY` → Info.plist `GMSApiKey` (`GoogleMapsConfiguration`). Dosya yoksa proje yine derlenir; harita özelliği "kullanılamıyor" der |
| **Proje dosyası** | XcodeGen: `project.yml` tek kaynak; `ViFi.xcodeproj` üretilir ve depoda tutulmaz (yalnızca içindeki SwiftPM `Package.resolved` commit'lenir) |
| **Test** | Swift Testing (`ViFiTests`), XCUITest (`ViFiUITests`), Firebase Emulator (`firebase/tests`; kurallar + Function handler'ları, `schema.js` birim testleri dahil; 4.2.0: `conversionSchema` / `conversionPipeline` / `conversionAdmin` / `convertLegacyExams`). iOS 4.2.0: `StructuredExam*`, `ExamTitleParser`, `MathTextTokenizer`, `FormulaRendering`, `QuestionContentView`, `ExamRouting`, `ConversionAdminViewModel`, `ExamConversionCalls`, `StructuredExamUITests` |
| **❌ Yasak** | Combine / `ObservableObject` / `@Published`, `print`, force unwrap, CocoaPods, Storyboard/XIB, `downloadURL`'deki `token=` parametresine güvenmek, Google Maps anahtarını commit'lemek, bildirim görselinin imzalı URL'sini Firestore'a yazmak (görsel yalnızca `storagePath` ile tutulur), Vertex/Claude/Gemini API anahtarı kullanmak ya da commit'lemek, soru içeriğini `CaptureShieldedView` dışında çizmek |

---

## Proje Yapısı

```
ViFi-iOS/
├── CLAUDE.md                 # Bu dosya (Claude talimatları)
├── README.md                 # Ürün, mimari, kurulum, Geliştirici Rehberi
├── NOTIFICATIONS.md          # Bildirim sistemi tasarım sözleşmesi (yerel, git-dışı; kalıcı bilgi bu dosyada + README'de)
├── project.yml               # XcodeGen tanımı: hedefler, ayarlar, paketler, Info.plist
├── .swiftlint.yml            # Lint kuralları (her derlemede çalışır; ViFiNotificationService dahil)
├── Config/                   # Base.xcconfig (commit'li), Secrets.example.xcconfig (şablon); Secrets.xcconfig git-dışı (Google Maps anahtarı)
├── ViFiNotificationService/  # Notification Service Extension: her push'ta ikon rozetini +1 yapar, kampanya görselini ekler
│                             # (+ kendi Info.plist ve App Group entitlement'ı). Yalnızca sistem framework'leri + FirebaseMessaging
├── ViFi/
│   ├── App/                  # ViFiApp, AppDelegate (ortamı kurar; FCM token + push dokunuşu), AppEnvironment, RootView (giriş kapısı;
│   │                         # inbox sheet'i + izin akışı sunumu), Router, NotificationRouter (push dokunuşu → inbox),
│   │                         # NotificationPromptCoordinator (izin/onay akışının ne zaman sunulacağı)
│   ├── Core/
│   │   ├── Models/           # ArchivePath, ArchiveItem / ExamDocument, PhoneNumber, UserProfile (+ Gender);
│   │   │                     # AppNotification (InboxItem, NotificationAction/Location/Audience), NotificationAdmin
│   │   │                     # (NotificationDraft, AudienceFacets, SentNotification), NotificationConsent;
│   │   │                     # ExamQuestion (+ QuestionChoice/Figure/Answer, AIProvider, ExamType), ExamConversion, ExamConversionAdmin
│   │   ├── Services/         # Protokoller (ServiceProtocols, AuthServicing, ProfileServicing), Firebase servisleri,
│   │   │                     # ArchiveParser, UserProfileParser, RemoteFileLoader, SessionStore, ProfileStore,
│   │   │                     # UniversityCatalog, RecentExamsStore, App Check fabrikası.
│   │   │                     # Bildirim: NotificationPayloadParser (saf), InboxStore + FirebaseInboxReader,
│   │   │                     # DeviceRegistrationStore + FirebaseDeviceRegistrar, NotificationSettingsStore + Firebase…SettingsService,
│   │   │                     # NotificationPromptHistory, NotificationEventTracker, NotificationAdminServicing +
│   │   │                     # FirebaseNotificationAdminService, GoogleMapsConfiguration / GoogleMapsSDK
│   │   │                     # Yapılandırılmış sınav (4.2.0): StructuredExamServicing (ExamQuestionReading + ExamConversionServicing), FirebaseExamQuestionReader,
│   │   │                     # FirebaseExamConversionService + ExamConversionCalls (callable'lar), ExamQuestionParser / ExamConversionParser (saf)
│   │   └── Utilities/        # Loadable, Logger+ViFi, FirstOutcome, Slug (kanonik id üretimi), ExamTitleParser (sınav adı → tür + yıl),
│   │                         # MathTextTokenizer (Markdown + LaTeX ayırıcı), NotificationBadgeCounter
│   │                         # (App Group rozet sayacı; hem uygulamaya hem extension'a derlenir), ModalPresentation
│   ├── DesignSystem/         # IconBadge, durum görünümleri (Loading/Error/Empty), seviye stilleri
│   ├── Features/
│   │   ├── Home/             # Ana sayfa, son görüntülenenler, Hakkında, "Sınav Ekle" kapısı
│   │   ├── Browse/           # Fakülte → sınav listeleri, breadcrumb
│   │   ├── Exam/             # Görsel (sayfalayıcı, yakınlaştırma) ve PDF görüntüleyiciler + ekran koruması
│   │   │                     # (CaptureShield, CaptureShieldedView, CaptureShieldCrashGuard, ProtectedImageView, ScreenCaptureProtection)
│   │   │   └── Questions/    # 4.2.0 soru ekranı: StructuredExamView/ViewModel (liste), QuestionCardView (yeniden kullanılabilir kart),
│   │   │                     # QuestionContentView (kalkan içindeki UIKit içerik), FormulaText (SwiftMath + Markdown)
│   │   ├── AddExam/          # Kullanıcı sınav ekleme: üniv/fakülte/bölüm bundled listeden (profilden ön-dolu) + ders (arşiv dersleri/serbest, LessonPicker) + sabit sınav-adı listesi + görsel/PDF yükleme + kademe-bazlı coin tahmini
│   │   ├── Moderation/       # Admin paneli: bekleyen gönderimleri incele (dosya önizleme) + iki düğmeli 1. onay ("Onayla · Claude/Gemini ile ilerle": coin + dosya kopyası + dönüştürme) / Reddet;
│   │   │                     # Gönderen (ad soyad, üniv., fakülte, bölüm): `SubmitterProfileReading` RTDB profilinden okur, uid başı önbellekli; telefon numarası modelde bile tutulmaz (KVKK)
│   │   │                     # dönüştürme ekranları: ConversionReviewView (hazır sınavlar: orijinal + taslak, düzenle, yeniden üret, yayınla/iptal), ConversionJobsView (başarısızlar),
│   │   │                     # BulkConversionView (toplu kuyruk + aylık sınır göstergesi), ExamConversionAdminButton ("Yeni yapıya geçir"), PublishedQuestionAdminActions (K15)
│   │   ├── Notifications/    # Bildirim sayfası (InboxView: kartlar, vurgulama, aksiyon düğmeleri, InboxExamGate = kilit kuralı,
│   │   │                     # LocationChoiceSheet + MapsLinks = "Konuma Git") + izin/onay akışı (priming 1/2, kampanya onayı 2/2,
│   │   │                     # NotificationPermissionFlowModel, NotificationPromptPresenter)
│   │   ├── NotificationComposer/  # Admin "Bildirim Gönder" (tür/başlık/mesaj, kitle seçicileri, görsel, aksiyon, zamanlama,
│   │   │                     # önizleme + onay, "Bana test gönder") + geçmiş/istatistik/iptal; LocationPicker/ = Google Maps + Places seçici
│   │   ├── Auth/             # Telefon + SMS kodu ile giriş
│   │   ├── Profile/          # Zorunlu profil tamamlama kapısı + Hesap'tan düzenleme (ad/soyad/üniv./fakülte/bölüm/cinsiyet)
│   │   └── Account/          # Hesap: profil düzenle, Bildirim Ayarları (sistem izni + kampanya anahtarı), çıkış, hesap silme (yeniden doğrulamalı)
│   ├── Resources/            # Assets, Info.plist (üretilir), String Catalog'lar, PrivacyInfo, ViFi.entitlements,
│   │                         # GoogleService-Info.plist
│   └── Preview Content/      # MockServices (örnek veri, MockAuthService) + Mock bildirim servisleri (MockNotificationServices,
│                             # MockNotificationSettingsService, MockLocationPicker) + örnek sınav dosyaları — yalnızca Debug
├── ViFiTests/                # Birim testleri (Swift Testing) + TestDoubles.swift, NotificationTestDoubles, InboxTestDoubles, NotificationPromptTestDoubles
├── ViFiUITests/              # Arayüz testleri (örnek veriyle): Inbox, NotificationComposer, NotificationPermission, LocationCampaign, StructuredExam
├── STRUCTURED-EXAMS.md       # Android sözleşmesi: yapılandırılmış sınav veri modeli, ayrıştırma/çizim kuralları (yerel, git-dışı)
└── firebase/                 # Güvenlik kuralları, emulator testleri, token + geçiş script'leri (ayrıntı: firebase/README.md)
    ├── functions/            # Cloud Functions (europe-west1): unlockExam, recordLoginDiagnostic, purchaseExamUnlock +
    │   │                     # bildirimler (index.js yalnızca bağlar). accountCleanup.js = hesap silme temizliği
    │   ├── notifications/    # schema.js (sözleşme: doğrulama, şekillendirme, push payload), admin.js, audience.js, deliver.js,
    │   │                     # schedule.js, automatic.js, stats.js, devices.js — handler'lar bağımlılık enjeksiyonlu
    │   └── conversions/      # 4.2.0 yapılandırılmış sınav hattı: schema.js (sözleşme, AI çıktı şeması, sınav adı ayrıştırıcı), prompt.js,
    │       │                 # jobs.js, admin.js (8 callable), publish.js (2. onay, K15, K20–K22), pipeline.js (kuyruk gövdesi), usage.js (50 $ sınır),
    │       │                 # subjects.js, pdf.js, images.js, files.js, slug.js; providers/ (claude.js, gemini.js, config.js — model kimliği/fiyat tek yerde)
    ├── scripts/              # revoke-download-tokens.mjs, convert-legacy-exams.mjs (tek seferlik geçiş, K12c/K24)
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
- **Arşiv Cloud Firestore'dan okunur** (`FirestoreArchiveRepository`): `DocumentSnapshot.data()` sözlükleri
  `FirestoreArchiveParser` ile `Sendable` modellere çevrilir (saf, Firestore'suz test edilir); dosya URL'leri
  `storagePath`→`StorageURL`. Rollback RTDB yolunda (`FirebaseArchiveRepository`) `DataSnapshot` callback dışına
  çıkmaz, `ArchiveParser` ile çevrilir. Firebase callback'leri arka plan kuyruğunda gelir; modeller
  `nonisolated struct/enum … : Sendable`.
- **Firebase başlatma sırası kritik:** `AppEnvironment.live()` yalnızca `AppDelegate.environment` → `makeDefault()`
  zinciriyle (yani `UIApplication` oluştuktan sonra) çağrılır. Aksi halde Phone Auth'un APNs/bildirim yöneticileri hiç kurulmaz.
  `AppCheck.setAppCheckProviderFactory` her zaman `FirebaseApp.configure()`'dan **önce** çalışır.
- **Örnek veri modunda (`-ViFiMockData`) Firebase hiç yapılandırılmaz.** Bu modda `Auth.auth()`, `Database.database()`
  veya `Firestore.firestore()` çağırmak çökme demektir; `FirebaseAuthService.configuredAuth` / `ViFiFirestore` gibi
  korumalı yolları kullan.
- **Dosya indirme:** Firestore `exams` dokümanları dosyayı `storagePath` olarak saklar; indirme URL'i
  `StorageURL.canonical` ile kurulur (eski RTDB `downloadURL`'lerinin `token=` parametresi iptal edildi, kullanılmaz).
  Storage dosyaları yalnızca `RemoteFileLoader` (`canonicalURL` + `RequestAuthorizing`) üzerinden indirilir. Yeni bir
  indirme yolu eklenecekse bu yoldan geç; kimlik bilgisini yalnızca uygulamanın kendi bucket'ına gönder.

### Bildirimler
- **Sunucu gönderir, istemci göndermez.** Tüm teslim yolları (admin composer, zamanlayıcı, otomatik bildirimler) tek
  `deliverNotification` fonksiyonundan geçer ve yalnızca `status == 'sending'` kaydı teslim eder; yeni bir gönderim
  yolu eklenecekse buradan geç. Kayıt (`notifications/<id>`) ve teslim kopyası yalnızca Function'larla yazılır.
- **Sözleşme üç yerde aynı olmalı:** `firebase/functions/notifications/schema.js` (yetkili), iOS modelleri
  (`AppNotification.swift`, `NotificationAdmin.swift`) ve `NotificationPayloadParser`. Tür, aksiyon tipi, limit ya da alan
  değişirse üçü ve testleri (`notificationSchema.test.mjs`, `NotificationPayloadParserTests`) birlikte güncellenir.
- **Kampanya (`promo`) her zaman sunucuda onay süzgecinden geçer** (`settings/notifications.marketing == true`; Apple 4.5.4).
  `promo` asla topic/`announcements` yoluna girmez, yalnızca kişi başı `fanout` olur. Konum aksiyonlu bildirim sunucuda
  zorla `promo` yapılır; composer'da Tür "Kampanya"ya kilitlenir. Onay varsayılan kapalıdır, atlanamaz, karşılığında
  coin/ödül verilmez (Apple 5.1.1). `settings/notifications` kaydı `{marketing, source: prompt|settings, version, updatedAt}`.
- **Sessiz saatler (22:00–09:00, Europe/Istanbul):** `promo` ve otomatik "yeni sınav" 09:00'a ertelenir; kişisel sistem
  bildirimleri, admin'e giden bildirimler ve test gönderimi anında gider. Saat mantığı yalnızca `schema.js`'te.
- **Görsel yalnızca `image.storagePath` ile tutulur** (`notificationImages/<id>.jpg`, JPEG ≤ 1 MiB, bir kez yüklenir).
  Bildirim sayfası onu `RemoteFileLoader` (kimlikli) ile indirir; push için sunucu gönderim anında 7 günlük imzalı URL
  üretir ve yalnızca FCM payload'ına koyar. İmzalı URL Firestore'a yazılmaz.
- **Google Maps anahtarı asla commit'lenmez** (`Config/Secrets.xcconfig`, git-dışı). SDK'lar uygulama açılışında değil,
  admin ilk konum seçiciyi açarken `GoogleMapsSDK.startIfPossible()` ile başlatılır; anahtar yoksa seçici "kullanılamıyor"
  gösterir (SDK çökerdi). **Örnek veri modunda Google SDK'sı hiç başlatılmaz:** `LocationPicking` protokolü +
  `MockLocationPicker`. Konum seçiciye yeni bir yol eklersen aynı korumayı koru. **CoreLocation yalnızca admin konum seçicisinde** (kullanıcı
  isteği, 30 Ekim 2026): açılışta "Uygulamayı Kullanırken" izni bir kez istenir, harita cihaz konumuna odaklanır
  (düzenlenen bir konum ya da admin'in kaydırması/araması varsa odaklanmaz), haritadaki yer etiketine dokunmak o yeri
  seçer. Konum yalnızca haritada gösterilir; saklanmaz, log'lanmaz, sunucuya gitmez (`DeviceLocating` / `CoreLocationProvider`).
  Örnek veri ve anahtarsız modda CoreLocation'a dokunulmaz; uygulamanın başka hiçbir yerinde kullanıcı konumu kullanılmaz.
- **Push dokunuşu doğrudan gezinmez.** `AppDelegate` yalnızca `NotificationRouter.receive(notificationId:)` çağırır;
  `HomeView` (tüm kapılardan sonra var olan ekran) engelleyen modal kalmayınca inbox'ı açar. Çıkışta bekleyen dokunuş silinir; oturum kapalıyken yapılan dokunuş da
  sonraki girişte atılır (`NotificationRouter.sessionDidChange`; soğuk başlatmadaki dokunuş korunur).
- **Cihaz kaydı:** `users/<uid>/devices/<kurulum-UUID'si>` = `{token, platform, appVersion, updatedAt}`
  (`DeviceRegistrationStore`; token + oturum birlikte olunca yazar). Çıkış ve hesap silmeden **önce** kayıt silinir
  (en çok 3 sn bekler, başarısızlık çıkışı engellemez). Aynı token başka hesapta görülürse sunucu eskisini siler.
- **Rozet:** uygulama arka plana geçerken ikon rozeti = okunmamış sayısı, açılınca 0. Sayaç App Group
  `group.com.BuyukerYazilim.ViFi2` UserDefaults'unda (`NotificationBadgeCounter`); extension her push'ta +1 yapar.
  Extension kodu `nonisolated`'dır ve yalnızca sistem framework'leri + FirebaseMessaging kullanır; uygulama kodunu
  extension'a ancak `project.yml`'de açıkça listelenen, yalnızca Foundation kullanan dosya (`NotificationBadgeCounter`) kadar paylaş.
- **Okunmamış** = `createdAt > users/<uid>/settings/inbox.readAt` (cihazlar arası senkron; sayfa açılınca tek yazım).
  İşaret sunucuda **yoksa** (yeni hesap) bir kez "şimdi" yazılır: eski duyurular listelenir ama rozeti yakmaz
  (kullanıcı kararı); okuma hatasında asla yazılmaz, yalnız önbellekten gelen "yok" beklenir (`includeMetadataChanges`).
  Bir kaynak okunamazsa boş liste gibi gösterilmez (`Loadable.failed` / `hasPartialFailure`).
- **Bildirimden açılan sınav arşivin kilit kuralından geçer** (`ExamAccessResolver`): kilitliyse kilit sayfası çıkar.
- **Analytics:** `notification_priming_*` ve `marketing_consent_*` (shown/accepted/declined, `source` parametresiyle);
  admin geçmişindeki `opened` / `actionTapped` sayıları `NotificationEventTracker` → `trackNotificationEvent` ile
  (fire-and-forget, kullanıcı başı tek; yalnızca teslim kopyası olan alıcı sayılır).

### Ekran koruması
- **Sınav pikseli çizen her UIKit yüzeyi `CaptureShieldedView` içinde kurulur** (pager `CaptureShieldedView<ZoomableImageScrollView>`,
  PDF `<ExamPDFView>`, liste ve moderasyon önizlemesi `ProtectedImageView` = `<UIImageView>`). Kap `makeUIView`'da bir kez
  kurulur; `updateUIView` `content`'i **yerinde** günceller, asla yenisiyle değiştirmez (yeni görünüm bayraksız kalır).
  `content` opaktır; onu soldurup gösteren kart `.compositingGroup()` ister. Yeni bir sınav yüzeyi eklersen aynı kaba al.
- **Mekanizma:** `CaptureShield` pencereye girmeyen donör `UITextField`'ın canvas'ını **sınıf adıyla** (`TextLayoutCanvasView`)
  bulur, KVC `layer` ile hedef katmana bağlayıp `isSecureTextEntry` false→true yapar. `UITextField` alt görünümleri **asla sıra
  numarasıyla** seçilmez (eski `SecureHostingView` hatası: `subviews.first` iOS 17+'da bayraksız `_UITouchPassthroughView`).
  Özel `disableUpdateMask` anahtarı ve özel selector'lar asla doğrudan kullanılmaz; `CaptureShield`'ın public API imzaları
  (`shared`, `isAvailable`, `isActive`, `setProtected(_:on:)`) değiştirilmez.
- **Fail-open (sahip kararı K7):** kalkan bulunamazsa, uzaktan kapatılırsa ya da `CaptureShieldCrashGuard` (aynı build + iOS'ta
  takas sırasında üst üste iki ölüm) devre dışı bırakırsa sayfa gösterilir, `Logger.app.fault` yazılır, kayıt örtüsü devreye girer.
- **Örtü kararı tek yerde:** `CaptureCoverPolicy.shouldCover` (saf). `fallback` (varsayılan, K4): kayıt sırasında cihazda sayfa
  görünür, örtü yalnızca kalkan aktif değilse; `always`: her kayıt/yansıtmada. `RootView`, `captureShieldIsActive` ve
  `captureCoverMode` ortam değerlerini verir. Uzaktan değer (`CaptureShieldRemoteSwitch`) `UserDefaults`'a yansır, **sonraki açılışta** uygulanır.
- **Sınav ekranlarında yasak:** `render(in:)`, `ImageRenderer`, snapshot tabanlı geçiş, `.drawingGroup()`, `shouldRasterize`,
  `contextMenu(preview:)`, `draggable`, paylaş/yazdır. Bunlar bayraklı katmanı atlar ya da düzleştirir. Generic `UIView`
  alt sınıflarında **açık `deinit {}`** (Swift 6.3.3 `-O` + iOS < 18.4'te örtük deinit çöküyor); her adımda Release derlemesi.
- **PDF metin kilidi (K9):** `ExamPDFView` seçim, kopyala, paylaş, sözlükte ara, Bul ve sürüklemeyi kapatır. `document` özelliğini
  override etme: PDFKit onu arka plan iş parçacığında okur, MainActor izolasyon denetimi uygulamayı çökertir.
- **Doğrulama:** simülatörde yakalama kâhini yalnızca `XCUIScreen.main.screenshot()` / `drawHierarchy`'dir; `simctl io screenshot`
  ve `CALayer.render(in:)` bayrağı uygulamaz, kanıt sayılmaz. Debug öz-denetim `-ViFiCaptureShieldSelfTest` → `exam.shield.selfTest`
  (`verified`/`unverified`/`off`; `CaptureShieldUITests`). Bu bir hiyerarşi denetimidir, cihaz kanıtı değildir: **her iOS betasında
  ve her Xcode/SDK değişiminde** cihaz çekirdek seti (`SCREEN-CAPTURE-RESEARCH-FABLE.md` Bölüm 9.3, D1–D4, D10, D12) geçmeden sürüm çıkmaz.
- **Ekran görüntüleri** (App Store, README) `-ViFiCaptureShieldOff` ile alınır; yoksa sayfalar boş çıkar. Sürüm notu ve
  arayüz metni iddiasızdır: "yakalanamaz" denmez; iPhone Yansıtma (Mirroring) bilinen bir sızıntıdır.

### Yapılandırılmış sınavlar (4.2.0)
> **Durum:** kod `v-4.2.0` dalında; canlıya **hiçbir şey yayınlanmadı** (Firestore/Storage kuralları, indeksler, 8 callable +
> `processExamConversion` kuyruğu, Vertex AI etkinleştirme). Sıra: 4.1.0 canlıda olsun → sahibin onayıyla kural + Function yayını →
> uçtan uca deneme. 4.2.0 Android hazır olana kadar incelemeye gönderilmez; iki platform aynı anda yayına alınır (K16).

- **Sözleşme tek yerde, üç yerde aynalanır.** Yetkili: `firebase/functions/conversions/schema.js`. iOS tarafı: `ExamQuestion`,
  `ExamConversion`, `ExamQuestionParser`, `ExamConversionParser`, `ExamTitleParser`. Alan, limit, durum ya da id biçimi değişirse
  JS + Swift + testleri (`conversionSchema.test.mjs`, `StructuredExamParserTests`, `ExamTitleParserTests`; sınav adı ayrıştırıcının
  16 ortak vakası) ve yerel `STRUCTURED-EXAMS.md` (Android sözleşmesi) birlikte güncellenir. `schemaVersion`'ı bilinmeyen sorular atlanır.
- **Veri:** Yayınlanmış soru düz `questions/<examId>-<nnn>` (kalıcı id; yer imi/ilerleme ileride buna bağlanır; `canReadArchive()` okur,
  yalnız sunucu yazar). Taslak `examConversions/<jobId>/questions/<nnn>`, iş `examConversions/<jobId>` (`exam-<examId>` eski sınav,
  `sub-<submissionId>` gönderim; yalnız admin okur). Soru sorgu anahtarları (`subjectId`, `courseId`, `universityId`, `examType`, `year`…)
  ve `questionPools` / `subjects` gelecekteki "Sınava gir" modu (ROADMAP #4) içindir; 4.2.0'da o mod **geliştirilmez**.
- **Model seçimi her işlemde adminindir (K9).** Claude ya da Gemini; varsayılan yok. `provider` isteğe girer, `examConversions/<jobId>.model`
  yazılır. Uzaktan "varsayılan model" ayarı ekleme. Model kimliği, bölge (`global`, K18), fiyat ve düşünme ayarı yalnızca
  `providers/config.js`'te (`VERIFY` işaretli değerler ilk canlı Vertex çağrısından önce doğrulanır; Vertex'te Anthropic batch API yok).
  Kimlik Functions servis hesabıdır; API anahtarı yok, repoya girmez.
- **İki onaylı akış (K1).** 1. onay (`FirebaseModerationService.approve`) coin verir ve dosyaları `imagess/` / `pdfs/`'e kopyalar
  ama `catalogNodes`/`exams`'e **yazmaz**; gönderime `publishPlan` + `conversionProvider` yazar, `onSubmissionModerated` işi (`sub-<id>`)
  açıp kuyruğa verir. Taslak hazır → adminlere `conversionReady`. 2. onay `publishExamConversion` (tek transaction, sunucuda). Gönderene
  2. bildirim gitmez (K19). Red = "tekrar dene" (`regenerateExamConversion`); kalıcı vazgeçme "Sınavı iptal et" (`discarded`, coin geri
  alınmaz; gönderimin kopyalanmış dosyaları Storage'dan silinir, K20). 4.1.0 admin istemcisi onayda hâlâ doğrudan yayınlar: sunucu
  `exam-<id>` işini sağlayıcısız bekletir. **Yeni bir yayın yolu ekleme**; `exams`'e yazan tek yol `publishExamConversion`.
- **Orijinal dosyalar korunur (K7).** Yapılandırılmış sınavda `exams/<id>.files` silinmez/değişmez (yalnız mükerrer değiştirmede, aşağıda);
  sınav `format: 'structured'`, `questionCount`, `structuredAt`, `conversionJobId` alır. 4.1.0 ve Android eski görünümü göstermeye
  devam eder. Dosyaların kapatılması yalnız Faz 4'tedir (iki platformun zorunlu güncellemesinden sonra).
- **Mükerrer gönderim = değiştir (K22).** `publishPlan.mode == 'replace'`: moderasyon sayfası "Bu sınav arşivde zaten yüklü" der, iki onay
  düğmesi aynıdır; 2. onay mevcut sınavı yeni yapıya çevirir ya da sorularını değiştirir, `files`'ı gönderimin kopyalarıyla değiştirir,
  eski dosyaları Storage'dan siler (başka bir sınavın listelediği dosya silinmez, `files.js`); arşive ikinci kopya eklenmez.
- **Ders kimliği (K21).** 2. onayda admin farklı `subjectId` / `newSubjectName` seçerse dersin daha önce yayınlanmış TÜM soruları ve havuz
  kayıtları yeni kimliğe taşınır (`moveCourseSubject`; yarım kalan taşıma `publishExamConversion` tekrarıyla sürer).
- **Düzenleme.** Admin taslağı doğrudan Firestore'da düzenler (kural: yalnız `text/speech/choices/answer/solution/needsReview` + `editedBy`/`editedAt`);
  yayındaki soruyu `updatePublishedQuestion` (K15, id değişmez, anında yayında). Tek soruyu yeniden üretme (`regenerateDraftQuestion` /
  `regeneratePublishedQuestion`): taslakta `regenerationLeaseUntil` (sürerken) ve `regenerationError` (son denemede başarısızsa) tutulur,
  admin ekranı ikisini gösterir. Yeniden üretilen sorunun şekilleri **sürümlü yola** yazılır (`questionFigures/<jobId>/<nnn>-<k>-r<rev>.jpg`),
  URL-anahtarlı önbellek eski görseli göstermesin diye; şekil yolu hiç yeniden kullanılmaz.
- **Soru içeriği yalnız `CaptureShieldedView` içinde çizilir.** Soru, şık, şekil, cevap ve çözümün hepsi `QuestionContentView` (UIKit) içindedir; kap
  `QuestionContentRepresentable`'da bir kez kurulur, `configure` içeriği yerinde günceller. `QuestionCardView`'da yalnız başlık ve
  "Cevabı Göster" düğmesi SwiftUI'dir. Soru için SwiftUI `Text`/`Image`, `.drawingGroup()`, `ImageRenderer`, paylaş/kopyala/sürükle yok
  (*Ekran koruması* yasakları aynen). Yeni bir soru yüzeyi → aynı kap + `CaptureShieldUITests` kapsamı.
- **SwiftMath yalnızca kalkanın içinde ve sabit sürümde.** `MTMathUILabel` / `MTMathImage` yalnız `FormulaText` → `QuestionContentView` yoluyla kullanılır;
  `project.yml`'de `exactVersion: 1.7.3` (yerleşim değişimi yayınlanmış tüm soruları kaydırır; güncelleme `FormulaRenderingTests` + gerçek cihazda görsel
  kontrolle). Metin `MathTextTokenizer` ile ayrılır (Pandoc `$` kuralı: `\$` düz dolar, kapanışı olmayan `$` metin, `$5 ve $6` metin); bozuk LaTeX çökmez,
  kaynağı metin olarak gösterilir. Satır içi Markdown yalnız kalın/italik/kod/üstü çizili.
- **Önceden çekme yok.** `ArchivePrefetcher` soruları, havuzları ve şekilleri çekmez. Sınav açılınca yalnızca
  `questions where examId == X order by order` (`FirebaseExamQuestionReader`, ~10–30 okuma; `questions (examId, order)` indeksi), şekiller ekrana
  gelince `RemoteFileLoader` ile (kimlikli, disk önbelleği). Sorular yüklenemez/boş gelirse bugünkü gibi hata ("Tekrar dene" / "Bu sınavda soru yok");
  orijinal sayfalara **otomatik dönüş yok** (K23).
- **Kilit ve yönlendirme aynen.** Kilit kuralı (`ExamLock`, `ExamAccessResolver`) değişmez; kilitli sınav soru ekranına ulaşmaz. "Cevabı Göster"
  ek kilit taşımaz (K4). Soru ekranı mı dosya görünümü mü kararı tek yerde (`ExamRouting`, saf): `format == structured` **ve** `questionCount > 0`
  (uzaktan anahtar yok: Apple App Review uzaktan değişen davranışı sevmez, K25). Browse, arama, son görüntülenenler ve bildirimden sınav aynı karardan geçer.
- **Uzaktan anahtar yok (K25, 14 Kasım 2026).** Yapılandırılmış sınav her zaman soru ekranında açılır; uygulama davranışını uzak bayrakla değiştirmez
  (Apple App Review riski). `exams/<id>.files` eski istemciler (4.1.0 / eski Android) için korunur.
- **Yapay zekâ notu ve erişilebilirlik.** Açılan her cevabın altında sade not: "Bu çözüm yapay zekâ ile hazırlanmış ve incelenmiştir." (K10; hata bildir
  düğmesi yok; `QuestionContentView.aiNote`). Arayüz ve sürüm metni doğruluk garantisi vermez. VoiceOver formülü LaTeX okumaz: soru `speech`, cevap
  `answer.speech ?? answer.text`, yoksa `MathTextTokenizer.plainText`. Kimlikler `questions.list`, `questions.card.<n>`, `questions.reveal.<n>`,
  `questions.question.<n>`, `questions.answer.<n>`; admin: `questionAdmin.menu|edit|regenerate`. Analytics: `exam_open` (`kind: structured`, `question_count`), `answer_revealed` (soru başına ekranda bir kez).
- **Aylık 50 $ yapay zekâ sınırı (K11).** `usage.js` `MONTHLY_CAP_USD`; harcama `aiUsage/<YYYY-MM>` (Europe/Istanbul ayı), her çalışma modelin cevabından hemen
  sonra (reddedilse bile) kaydedilir. Sınır aşılırsa yeni işler `queued` bekler, ay başında kendiliğinden devam eder, adminlere ayda tek `conversionBudgetExceeded`
  gider. Sınırı atlatan bir istemci/Function yolu ekleme; bir istisna yalnız betiğin `budget: 'oneTime'` işleri (ayrı toplanır). Toplu tahmin
  (`ESTIMATED_COST_PER_PAGE_USD`) kabadır; gerçek maliyet işin `usage`'ındadır.
- **Eski sınav geçişi (K12/K24): üç yol.** (a) sınav ekranında admin'e "Yeni yapıya geçir", (b) Moderasyon'da ders/bölüm için toplu kuyruk (en çok 200 sınav; önce
  tahmin, sonra onay), (c) `firebase/scripts/convert-legacy-exams.mjs`. Betik güvenliği: `--provider` zorunlu, varsayılan **dry-run** (yalnız sayı + tahmini maliyet),
  emulator dışında `--project` + eşleşen `--confirm-project` yoksa reddeder, `--apply` canlı veri yazar ve Vertex parası harcar → **yalnızca sahibin açık
  onayıyla ve aynı kapsamın dry-run'ından sonra**; idempotent (yapılandırılmış / işi olan sınavı atlar); hiçbir şey yayınlamaz, her taslak yine tek tek incelenir.
- **Sınav silme temizliği:** admin istemcisi `exams/<id>`'yi doğrudan siler; `onExamDeleted` tetikleyicisi `deleteStructuredExamData` ile sorular + havuz kayıtları + `questionFigures/` + iş temizliğini yapar (düz sınavda no-op, idempotent).

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
  Extension'ın entitlement'ı `ViFiNotificationService/ViFiNotificationService.entitlements`, Info.plist'i `project.yml`'deki
  `ViFiNotificationService.info` bloğundan üretilir. Uygulama ile extension aynı App Group'u taşır; birini değiştirirsen ikisini de değiştir.
  Paylaşılan xcconfig `Config/Base.xcconfig`'tir (`#include? "Secrets.xcconfig"`); sır eklenecekse `Secrets.xcconfig` + şablonuna eklenir.
- **SwiftLint** (her derlemede): satır 160 (hata 200), dosya 500 (hata 800), fonksiyon 60, tip gövdesi 300 satır,
  iç içe tip 2 seviye; `print` ve Combine yasakları özel kuralla denetlenir. Yeni uyarı bırakma.
- **Gizlilik:** Yeni bir veri türü toplanırsa `PrivacyInfo.xcprivacy` ve App Store gizlilik etiketi birlikte güncellenir.
  Uygulamanın ve bildirim eklentisinin ayrı manifesti vardır (`ViFiNotificationService/PrivacyInfo.xcprivacy`): Required
  Reason API kullanan her hedef kendi manifestinde beyan eder (App Group `UserDefaults` → `1C8F.1`), yoksa yükleme
  ITMS-91053 ile reddedilir. Kampanya hedeflemesi User ID / Device ID / Other Data Types'ta "Developer's Advertising or
  Marketing" amacıyla beyanlıdır (Tracking yok); Google Maps SDK'nın Crash + Performance Data'sı SDK manifestinde, App Store
  etiketinde de beyan edilir. Admin seçicisindeki cihaz konumu toplanmaz, etikete girmez (kullanıcı kararı, 30 Ekim 2026). reCAPTCHA Enterprise SDK'sının kendi manifesti vardır (Crash Data, Device ID, Performance Data, Product Interaction; hepsi Linked, Tracking yok, amaç App Functionality; `UserDefaults` CA92.1): uygulamanın manifesti değişmez, App Store etiketinde bu 4 tür beyan edilir.
- **Güvenlik kuralları:** `firebase/database.rules.json`, `firebase/firestore.rules` (+ `firestore.indexes.json`) ve
  `firebase/storage.rules` her değişiklikte emulator testleriyle birlikte güncellenir (`cd firebase && npm test`);
  yayın kullanıcı onayıyla yapılır. Function değişikliği de aynı testlerle (handler'lar emulator'e karşı) doğrulanır.

---

## Komutlar

```bash
# Google Maps anahtarı (yalnızca admin konum seçicisi için; yoksa proje yine derlenir). Dosya git-dışıdır, asla commit'leme
cp Config/Secrets.example.xcconfig Config/Secrets.xcconfig   # sonra GOOGLE_MAPS_API_KEY değerini doldur

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

# Bildirim epiği: Firestore kuralı + indeks, Storage kuralı ve Function yayını — YALNIZCA kullanıcı onayıyla. Yeni istemciden
# ÖNCE yayınlanır (4.0.0 ile geriye uyumlu; gerçek cihaz/TestFlight testi buna bağlı). Ayrıntı: Firebase › Bildirim sistemi.
cd firebase && firebase deploy --only firestore,storage,functions --project vifi-831a8 --account <proje-sahibi-hesabı>

# 4.2.0 yapılandırılmış sınavlar da aynı komutla yayınlanır (yeni kural + indeks: questions, examConversions, aiUsage…; storage.rules: questionFigures/;
# 8 callable + `processExamConversion` kuyruk Function'ı, kuyruğu da o yaratır). YALNIZCA kullanıcı onayıyla; 4.1.0 canlıya çıktıktan SONRA.
# Önkoşul: Vertex AI API açık + Model Garden'da Claude etkin (yoksa işler `failed` olur), `npm --prefix firebase/functions ci`. Henüz HİÇBİRİ yayınlanmadı.

# Eski sınavları yeni yapıya geçirme betiği (K12c/K24). Varsayılan DRY-RUN: sınav sayısı + tahmini sayfa/maliyet yazar, hiçbir şey yazmaz.
cd firebase && node scripts/convert-legacy-exams.mjs --provider claude|gemini [--course <id> | --department <id>] [--limit N]            # yerel emulator
cd firebase && node scripts/convert-legacy-exams.mjs --provider gemini --project vifi-831a8 --confirm-project vifi-831a8 [--limit 10]    # canlı, yalnız okur
# --apply canlı veri yazar + Vertex parası harcar (budget: 'oneTime', aylık 50 $ sınırına girmez): YALNIZCA sahibin açık onayıyla, aynı kapsamın dry-run'ından sonra.
# cd firebase && node scripts/convert-legacy-exams.mjs --provider gemini --project vifi-831a8 --confirm-project vifi-831a8 --apply [--limit 10]
```

### Başlatma argümanları

| Argüman | Etki |
|---|---|
| `-ViFiMockData` | Firebase ve ağ olmadan paket içi örnek arşivle çalışır (yalnızca Debug; UI testleri bunu kullanır) |
| `-ViFiSignedOut` | `-ViFiMockData` ile birlikte: giriş ekranından başlar (örnek modda kod `111111`) |
| `-ViFiPhoneAuthTesting` | Yalnızca Debug: Phone Auth uygulama doğrulamasını kapatır; yalnızca Console'daki test numaralarıyla çalışır |
| `-ViFiForceUpdate` | `-ViFiMockData` ile birlikte (yalnızca Debug): kapatılamayan zorunlu güncelleme ekranından başlar (UI testi) |
| `-ViFiProfileIncomplete` | `-ViFiMockData` ile birlikte (yalnızca Debug): profilsiz başlar, zorunlu "Profilini Tamamla" kapısından açılır (UI testi) |
| `-ViFiAdmin` | `-ViFiMockData` ile birlikte (yalnızca Debug): kullanıcı admin sayılır; Hesap'ta Moderasyon ve **Bildirim Gönder** görünür |
| `-ViFiNoCoins` | `-ViFiMockData` ile birlikte (yalnızca Debug): coin bakiyesi 0 başlar (kilitli sınav / coin kazan istemi) |
| `-ViFiSubscribed` | `-ViFiMockData` ile birlikte (yalnızca Debug): aktif Premium abonelikle başlar (arşiv açık, coin gizli; bildirimde "Premium'a Göz At" düğmesi çıkmaz) |
| `-ViFiShowOnboarding` | `-ViFiMockData` ile birlikte (yalnızca Debug): ilk açılış tanıtım turunu zorla gösterir (örnek mod normalde turu geçmiş başlar) |
| `-ViFiNotificationsPrompt` | `-ViFiMockData` ile birlikte (yalnızca Debug): bildirim izni "sorulmamış" ve geçmiş boş (taze kurulum) → izin akışı açılır: 1/2 "Bildirimleri Aç" → 2/2 kampanya onayı |
| `-ViFiNotificationsDenied` | `-ViFiMockData` ile birlikte (yalnızca Debug): sistem bildirim izni reddedilmiş (Hesap › Bildirim Ayarları "Ayarlar'ı aç" durumu) |
| `-ViFiNotificationsReask` | `-ViFiMockData` ile birlikte (yalnızca Debug): izin adımı 31 gün önce reddedilmiş, izin "provisional" → sonraki başarılı sınav gönderiminden sonra tek seferlik tekrar sorulur |
| `-ViFiConsentReask` | `-ViFiMockData` ile birlikte (yalnızca Debug): kampanya onayı 31 gün önce reddedilmiş, kampanyalar kapalı → bildirim sayfası açılınca onay bir kez daha sorulur |
| `-ViFiOpenNotification <id>` | `-ViFiMockData` ile birlikte (yalnızca Debug): `<id>` bir sonraki argümandır; o push'a dokunulmuş gibi başlar, kapılardan sonra bildirim sayfası açılır ve `<id>` vurgulanır (UI testlerinde `p-paywall`, `a1` gibi örnek id'ler) |
| `-ViFiCaptureShieldOff` | Yalnızca Debug (canlı ya da örnek veri): ekran koruma kalkanı bu açılışta kapalı. App Store/README ekran görüntüleri için; kayıt örtüsü `fallback` modunda devreye girer |
| `-ViFiCaptureShieldSelfTest` | Yalnızca Debug: her korumalı yüzey ekrana gelince ölçülür, sonuç `exam.shield.selfTest` öğesinde (`verified`/`unverified`/`off`). Cihaz listesinde D1 |
| `-ViFiCaptureLog` | Yalnızca Debug: yakalama sinyallerini (açılıştaki değer, her değişim, `didMoveToWindow`) zaman damgalı OSLog'a (`Logger.app`) yazar; cihazda kayıt/örtü sorunu ayıklamak için |
| `-ViFiSimulateCapture` | Yalnızca Debug: kayıt/yansıtma varmış gibi davranır (UI testleri). Kalkan aktifken `fallback` modda örtü çıkmaz; örtüyü görmek için `-ViFiCaptureShieldOff` ile birlikte |

Yeni argüman yok (4.2.0): yapılandırılmış sınav `-ViFiMockData` ile örnek arşivde `KOCAELİ ÜNİVERSİTESİ › MÜHENDİSLİK FAKÜLTESİ › MATEMATİK BÖLÜMÜ › TOPOLOJİ 1 › 2003 FİNAL` olarak açılır (3 örnek soru, `sample-questions.json`; `StructuredExamUITests`); admin dönüştürme ekranları `-ViFiAdmin` ile görünür. Soru ekranının kalkanı için `-ViFiCaptureShieldSelfTest` aynen geçerlidir.

---

## Firebase

| Konu | Değer |
|---|---|
| **Proje** | `vifi-831a8` (Blaze planı; Storage bucket `vifi-831a8.appspot.com`) |
| **Canlı iOS uygulaması** | Console'daki takma adı *"ViFi - Üniversite Sınav Arşivi"* → `com.BuyukerYazilim.ViFi2` (asıl uygulama). **Bu takma ad iOS doğrulama SMS'inde görünür** ("… için doğrulama kodunuz"); Android'deki ad Google Play kaydından gelir, ikisi aynı tutulur. 14 Kasım 2026'ya kadar adı *"Vifi iOS Push Notification"* idi |
| **Diğer kayıtlar** | *"ViFiIOS"* → `com.BuyukerYazilim.ViFi` (eski kayıt, dokunma); Android `com.salticusteam.vifi` (henüz giriş/App Check yok, şu an kullanılmıyor) |
| **Arşiv (Firestore)** | isimli `vifi` DB: `catalogNodes/<id>` (university\|faculty\|department\|course, `parentId` zinciri, `status:published`) + `exams/<id>` (`courseId`, `kind`, `files:[{storagePath,order}]`). Şema+kurallar: `FIRESTORE-MIGRATION.md`, `firebase/firestore.rules`. **Rollback (RTDB, duruyor):** `Universitiess/<üniv>/<fak>/<böl>/<ders>/<sınav>/<JPG\|PDF>/<pushId>/downloadURL` |
| **Kullanıcı profili** | `users/<uid>/profile/{name, surname, university, universityId, universityIsCustom, faculty, facultyId, facultyIsCustom, department, departmentId, departmentIsCustom, gender(`female`\|`male`), phoneNumber, updatedAt}`. Sahibi (+90) okur/yazar, admin tüm profilleri okur. Giriş sonrası `ProfileStore` + `RootView` kapısı zorunlu kılar; `FirebaseProfileService` yazar. `updatedAt` sunucu zaman damgası. **Kanonik id'ler** (`*Id`, slug) bildirim segmentleri içindir (sunucu `users`'ı `profile/universityId` ile sorgular, fakülte/bölüm/cinsiyeti bellekte süzer); listeden seçilince id kanonik, serbest yazılınca `*IsCustom=true` + best-effort slug (`Slug`). `users` düğümü `profile/universityId\|facultyId\|departmentId\|gender` üzerinde `.indexOn`'lu |
| **Ekran koruması** | `config/captureProtection/ios = {enabled: Bool, coverMode: "fallback"\|"always"}` — `CaptureShieldRemoteSwitch` + `FirebaseCaptureShieldConfigReader` okur; eksik/bozuk değer = `{true, fallback}`. Değer `UserDefaults`'a yansır, **sonraki açılışta** uygulanır. `config` altında olduğu için kural değişikliği gerekmez; Console'a yazım yalnızca sahibin onayıyla |
| **Güncelleme politikası** | `config/appUpdate/ios/{minimumVersion, latestVersion, storeURL, message}` — `RemoteAppUpdateChecker` okur. `minimumVersion`'ın altı kapatılamaz zorunlu ekran, `latestVersion`'dan eski kapatılabilir öneri. Herkese okunur (App Check korumalı), yazma yalnızca `admin`. `storeURL` App Store adresidir; `AppStoreLink.productURL` yedeğidir |
| **Storage** | `imagess/<uuid>.jpg`, `pdfs/<uuid>.pdf`; gönderim dosyaları `pending/<uid>/<submissionId>/<dosya>` (yalnız `image/jpeg`\|`application/pdf`, ≤15 MiB, üzerine yazma yok, sahip-kapsamlı yol). **NOT:** client metadata/contentDisposition/contentEncoding kuralda **kısıtlanmaz** — gerçek Apple/Android Storage SDK yüklemede kendi metadata'sını ekler (örn. `firebaseStorageDownloadTokens`; JS/Admin SDK ve emulator eklemez), bu alanları zorlamak her mobil yüklemeyi 403 yapıyordu; güvenli çünkü onay Function'ı baytları taze server-metadata ile yeniden yükler. (Canlıda uçtan uca doğrulandı 2026-10-12.) Bildirim görselleri `notificationImages/<bildirimId>.jpg`: yalnız admin **create** (update/delete yok, admin dahil), `image/jpeg`, 0 < boyut ≤ 1 MiB, ad `^[A-Za-z0-9_-]{1,128}\.jpg$`, okuma +90/admin — yayınlandı 30 Ekim 2026 |
| **Erişim** | Arşivi (Firestore `catalogNodes`/`exams` + Storage `imagess/`, `pdfs/`) ve genel duyuruları (`announcements`) yalnızca +90 numarayla giriş yapanlar ve admin okur; Storage'da yalnızca tek dosya okunur, listeleme yok. Arşive yazma yalnızca `admin: true` custom claim'i olanlarda (RTDB `Universitiess` rollback'te kalan eski kopyadır) |
| **Gönderimler** | Firestore `submissions/<id>` (düz, `vifi` DB) — tam 10 anahtar `{ownerId, university, faculty, department, lesson, exam, kind(JPG\|PDF), status:'pending', createdAt, files:[{storagePath,order}]}`: denormalize **görünen-ad metni** (1..120), courseId/year yok → yıl `exam`'e katlanır (`"<yıl> <ad>"`); `files` 1..50, `createdAt`=serverTimestamp. Sahibi (+90) oluşturur, kendi kayıtlarını okur (`ownerId==uid` filtreli — bileşik index var), bekleyeni siler; admin okur/moderasyon (Admin SDK, kuralları atlar). Dosyalar Storage `pending/<uid>/<id>/<dosya>`. İstemci: `FirebaseExamSubmissionService` + Home "Sınav Ekle" (sheet). **Form:** üniv/fakülte/bölüm = bundled `UniversityCatalog` (login ile aynı, `CatalogPickerView(allowsCustom:false)`, **profilden ön-dolu**, salt-listeden); ders = `LessonPickerView` (seçili bölümün arşiv dersleri, ada göre `ArchiveNameMatch` eşleşmesi + "Farklı ders ekle" serbest-metin); sınav adı = sabit liste (`ExamNameCatalog`: VİZE/FİNAL/BÜTÜNLEME/MAZERET/KISA SINAV/YAZ OKULU/ARA SINAV). 5 metin alanı submission'a görünen-adla yazılır. **4.2.0'da onay iki aşamalıdır (bkz. *Temel Kurallar › Yapılandırılmış sınavlar*):** 1. onayda `FirebaseModerationService.approve` yalnız coin + Storage `pending→imagess/pdfs` kopyası + `publishPlan`/`conversionProvider` yazar (arşive yayınlamaz); yayın 2. onayda `publishExamConversion` Function'ında olur, yani aşağıdaki "Cloud Function YOK" 4.1.0 davranışıdır ve 4.1.0 admin istemcisinde sürer. **4.1.0 davranışı (serverless, Cloud Function YOK):** admin (`admin:true` claim) Hesap›Moderasyon'da bekleyenleri inceler, onayda `FirebaseModerationService` tek atomik WriteBatch ile sınavı arşive yayınlar (eksik `catalogNodes`+`exams` oluşturur, Storage `pending→imagess/pdfs` taşır) **ve** gönderene yenilik kademesine göre coin verir (`wallets` balance `FieldValue.increment` + `ledger/<submissionId>`). Kademe `SubmissionTierResolver` (6 kademe: yeni üniv>fakülte>bölüm>ders>sınav>mükerrer) × `config/rewards/ios/tiers` (RTDB, Console'dan ayarlanır). İdempotent (status==pending + ledger-exists guard). (NOT: eski RTDB `pendingExams` + Cloud Function `#7` tasarımı kullanılmadı.) |
| **Yapılandırılmış sınavlar (Firestore, 4.2.0 — HENÜZ CANLIDA DEĞİL)** | `questions/<examId>-<nnn>` yayınlanmış soru (`canReadArchive()` okur, yazma yok; id kalıcı), `questionPools/<subjectId>__<examType>__<tr\|u-<üniv>\|c-<ders>>` (+`__pN`; ids ≤15 bin/parça; ileride "Sınava gir" için), `subjects/<subjectId>` `{name, aliases[]}` (ülke geneli ders kimliği; `catalogNodes.subjectId`), `examConversions/<jobId>` iş (yalnız admin okur, yazma yok) + `…/questions/<nnn>` taslak (admin yalnız içerik alanlarını günceller), `aiUsage/<YYYY-MM>` aylık harcama (admin okur, yazma yok). İndeksler: `questions (examId, order)`, `examConversions (status, createdAt desc)`. `exams/<id>` ek alanları: `format: 'structured'`, `questionCount`, `structuredAt`, `conversionJobId`. Şema ve limitler: `functions/conversions/schema.js` (+ yerel `STRUCTURED-EXAMS.md`) |
| **Soru şekilleri (Storage, 4.2.0 — HENÜZ CANLIDA DEĞİL)** | `questionFigures/<jobId>/<nnn>-<k>[-r<rev>].jpg` (JPEG, en çok ~1200 px; yeniden üretilen soru `-r<rev>` sürümlü yol alır). Tek dosya okuma: +90 kullanıcı ve admin; yazma kimseye açık değil (yalnız Admin SDK) |
| **Yapay zekâ (Vertex AI, 4.2.0)** | Claude Opus 5.5 (`@anthropic-ai/vertex-sdk`) ve Gemini Pro (`@google/genai`, `vertexai: true`); bölge `global` (K18, gizlilik politikasına üçüncü taraf işleyici notu Faz 3'te); kimlik Functions servis hesabı (ADC), API anahtarı yok. Model kimliği/fiyat/ayar `providers/config.js` (`VERIFY` değerleri ilk canlı çağrıdan önce doğrulanır). Canlı önkoşul: `vifi-831a8`'de Vertex AI API + Model Garden'da Claude etkin, Cloud Tasks kuyruğu, Google Cloud bütçe uyarısı — hepsi sahibin onayıyla |
| **SMS Defense** | Amaç: Google'ın küresel dolandırıcılık süzgecinin bazı Türk operatör hatlarına SMS'i engellemesi ("Error code: 39"); Firebase desteğine göre tek çözüm reCAPTCHA SMS Defense. **Durum (31 Ekim 2026):** iOS SDK 4.1.0 (11) kodunda (yeniden gönderilen 4.1.0'a dahil; `project.yml`: `RecaptchaEnterprise` ≥ 18.9.1 + `OTHER_LDFLAGS -ObjC`; uygulama kodu değişmedi, Firebase Auth SDK'yı çalışma zamanında `RCARecaptcha` sınıfıyla bulur ve SDK sürümü ≥ 18.7.0 olmalı; `-ObjC` olmadan statik kütüphaneden ayıklanır ve Firebase boş belirteç yollar). **Console (31 Ekim 2026, kullanıcı onayıyla) — hazır ama SMS Defense KAPALI (`phoneEnforcementState: OFF`):** proje Identity Platform'a yükseltildi (geri alınamaz), reCAPTCHA Enterprise API açık, reCAPTCHA › Ayarlar › SMS defense açık, Identity Platform servis ajanı + `roles/identitytoolkit.serviceAgent` verildi, `recaptchaConfig` = AUDIT'te `useSmsTollFraudProtection: true` + `tollFraudManagedRules [{startScore 0.8, BLOCK}]` (kural kayıtlı duruyor); anahtarlar (WEB/IOS/ANDROID) Identity Platform tarafından otomatik üretilir (elle oluşturulan anahtar SDK'larla çalışmaz). ⚠️ **Servis ajanı olmadan AUDIT açılırsa anahtar üretilmez ve istemci `recaptchaConfig` uç noktası 500 döner → Firebase ≥ 11.6 istemcilerinde telefonla giriş tamamen durur** (31 Ekim'de ~22 dk kesinti yaşandı). ⚠️ **AUDIT de SDK'sız iOS sürümlerini kilitler** (belgenin aksine geri dönüş yok): Firebase iOS ≥ 11.6 AUDIT/ENFORCE'ta reCAPTCHA belirteci ister, SDK bağlı değilse `recaptchaSDKNotLinked` fırlatır ve yalnız `invalidAppCredential`'da yeniden dener → "Cihaz doğrulanamadı" (31 Ekim'de gerçek cihazda 4.0.0 ile doğrulandı). **Doğru sıra:** SDK'lı 4.1.0 (11) yayın → `minimumVersion` 4.1.0 (4.1.0 (10) hiç yayınlanmadığı için yeterli; `RemoteAppUpdateChecker` build numarasına bakmaz) (Android de SDK'lı sürüm + kendi zorunlu güncellemesi) → AUDIT → metrik → ENFORCE. Her değişiklikten sonra istemci uç noktasını (`v2/recaptchaConfig?clientType=…`) kontrol et; 200 değilse hemen `OFF` + `useSmsTollFraudProtection: false`'a geri al (yalnız `OFF` reddedilir). **ENFORCE yalnızca SDK'sız sürümler kalmayınca** (`config/appUpdate/ios.minimumVersion` yükseltildikten sonra; SDK'sız istemci belirteç yollamaz, engellenir). AUDIT'te başarısız değerlendirme engellenmez. Android (ayrı repo): Auth ≥ 23.1.0 + `com.google.android.recaptcha:recaptcha` ≥ 18.5.1. Console test numaraları ve `-ViFiPhoneAuthTesting` (uygulama doğrulamasını kapatır) reCAPTCHA'yı çalıştırmaz; gerçek doğrulama = gerçek cihaz + Console SMS Defense metrikleri |
| **App Check** | Storage, Realtime Database ve Authentication için zorunlu (enforced); **Firestore enforce yeni sürüm yayınlandıktan sonra açılacak** (şu an monitoring — bkz. `FIRESTORE-MIGRATION.md`). Yeni simülatör/cihaz → debug token Console'a eklenmeli |
| **İndirme token'ları** | Tümü iptal edildi; uygulamanın kendi indirmeleri yeni token üretmez. Yedek yalnızca yerelde (`firebase/backups/`) |
| **Bilinen sınır** | Okuma yetkisi olan bir kullanıcı `getMetadata`/`getDownloadURL` ile tek bir dosyaya kalıcı genel bağlantı üretebilir; kurallarla kapatılamaz |

### Bildirim sistemi

> **Yayın durumu (30 Ekim 2026): backend canlıda, yeni istemci henüz App Store'da değil.** Yapılanlar (kullanıcı onayıyla):
> Firestore kuralları + indeksleri ve Storage kuralları yayınlandı; 13 Function'ın tamamı canlıda (3 Firestore tetikleyicisi
> ilk denemede Eventarc yetki dağıtımı gecikmesiyle düştü, birkaç dakika sonra yeniden yayınlandı); Cloud Scheduler + Eventarc
> API'leri açıldı; compute servis hesabına kendi üzerinde *Service Account Token Creator* verildi (IAM Credentials API açıktı);
> Apple App Group iki App ID'de etkin; Google Cloud anahtarı hazır, yerel `Secrets.xcconfig` dolu. 4.0.0 istemcisi `all`
> topic'i + `announcements` ile çalışmaya devam eder. Canlı `announcements` boştu (createdAt'siz eski kayıt yok). Gerçek cihaz
> testi geçti (izin akışı, görselli push, rozet, dokunuşla bildirim sayfası, Konuma Git, admin harita seçicisi); gizlilik
> manifestleri güncellendi, App Store Connect gizlilik etiketi yayınlandı; 4.1.0 (10) App Store incelemesine gönderildi (30 Ekim 2026); 8 Kasım 2026'da
> geri çekildi ve ekran koruması + reCAPTCHA SDK ile **4.1.0 (11)** olarak yeniden incelemeye gönderildi (onaylanınca otomatik, herkese hemen). **Yayın sonrası:** `config/appUpdate/ios.latestVersion` → 4.1.0 (onayla) ve Firestore App Check enforce. Aşağıdaki liste tarihsel kayıt olarak duruyor:
>
> 1. **Yeni istemciden önce** (gerçek cihaz/TestFlight testi backend'e bağlı; 4.0.0 `devices`/`settings` kaydı yazmadığı ve
>    `all` topic + `announcements` yolu korunduğu için geriye uyumlu — 4.0.0 kodunda doğrulandı 30 Ekim 2026):
>    `firestore.rules` + `firestore.indexes.json` (yeni `notifications`
>    kuralları, `devices`/`settings/*` şekil kuralları, `notifications (status, scheduledAt)` indeksi, `devices.token`
>    collection-group alan istisnası) ve `storage.rules` (`notificationImages/`).
> 2. Function'lar (aşağıdaki tablo). Önkoşullar: Functions çalışma servis hesabına kendi üzerinde *Service Account Token
>    Creator* rolü + IAM Service Account Credentials API (push görselinin imzalı URL'i için; yoksa push görselsiz gider);
>    Cloud Scheduler işi (`dispatchScheduledNotifications`); `listUsers` için Auth admin yetkisi; 1. nesil auth
>    fonksiyonu (`onAccountDeleted`) için nodejs22 + servis hesabı izinleri; Firestore tetikleyicileri **isimli `vifi`
>    DB'yi (eur3)** dinler ve projenin ilk Firestore tetikleyicileridir → Eventarc tetikleyici konumu/servis ajanı
>    doğrulanmalı.
> 3. Apple Developer: App Group `group.com.BuyukerYazilim.ViFi2` oluşturulup `com.BuyukerYazilim.ViFi2` ve
>    `com.BuyukerYazilim.ViFi2.NotificationService` App ID'lerinde etkinleştirilmeli, profiller yenilenmeli.
> 4. Google Cloud — ✅ yapıldı (29 Ekim 2026): *Maps SDK for iOS* + *Places API (New)* açık, uygulama kimliğine ve bu iki
>    API'ye kısıtlı anahtar, Places günlük kotaları 300, proje bütçe uyarıları mevcut. Kalan: anahtarı yerelde
>    `Config/Secrets.xcconfig`'e koymak; sürüm (Archive) derlemesi anahtarla alınmalı.
> 5. Gerçek cihaz testi (provisional → tam izin, görselli push, rozet) ve App Store gizlilik etiketi güncellemesi.
> 6. Canlıda `createdAt`'siz, elle yazılmış eski `announcements` dokümanı varsa (sıralamada görünmezdi) onayla alan eklenir ya da silinir.

**Veri modeli** (Firestore `vifi` DB, aksi belirtilmedikçe):

| Yol | Yazan → okuyan | İçerik |
|---|---|---|
| `notifications/<id>` | Function → admin | Ana kayıt + geçmiş. `<id>` = istemcinin ürettiği küçük harf UUID (idempotency). Alanlar: `kind` (`general`\|`promo`\|`system`), `title` ≤80, `body` ≤500, `image{storagePath}`, `action`, `audience`, `audienceLabel`, `delivery` (`broadcast`\|`fanout`), `status` (`scheduled`\|`sending`\|`sent`\|`failed`\|`canceled`), `isTest`, `scheduledAt`, `deferredByQuietHours`, `expiresAt`, `source` (`admin`\|`automatic`), `trigger` (`submissionApproved`\|`submissionRejected`\|`newExam`\|`newSubmission`\|`conversionReady`\|`conversionFailed`\|`conversionBudgetExceeded`), `createdBy` (uid\|`system`), `createdAt`/`sentAt`, `stats{recipients,pushTargets,pushSent,pushFailed,opened,actionTapped}`, `error`; zamanlayıcı: `sendingAt`, `deliveryAttempts`, `canceledAt`, `canceledBy`. Kural: okuma admin, yazma yok |
| `notifications/<id>/events/<uid>_<opened\|actionTapped>` | Function | İstatistik tekilleştirme; istemci erişemez |
| `announcements/<id>` | Function → +90/admin | Genel (broadcast) duyurunun herkese açık kopyası; istemci son 50'yi okur |
| `users/<uid>/inbox/<id>` | Function → sahibi | Kişiye teslim kopyası; istemci son 100'ü okur. Kural: sunucu yazar, sahibi okur (kuralda eskiden kalma `read` bayrağı güncellemesi duruyor, uygulama kullanmıyor) |
| `users/<uid>/devices/<kurulumId>` | sahibi (+90) | `{token, platform: ios\|android, appVersion ≤32, updatedAt == request.time}`, başka alan yok; id `^[A-Za-z0-9_-]{1,128}$` (iOS: kurulum başı UUID, `UserDefaults`'ta). Sahibi okur/siler |
| `users/<uid>/settings/notifications` | sahibi | `{marketing, source: prompt\|settings, version 1…99, updatedAt == request.time}` — kampanya onayının ne zaman/nereden verildiği; silinemez |
| `users/<uid>/settings/inbox` | sahibi | `{readAt == request.time}`; okunmamış = `createdAt > readAt` |
| `notificationThrottle/<uni>__<fak>__<böl>` | Function | `{lastSentAt, notificationId}` — "yeni sınav" bölüm günlük sınırı; istemci erişemez |

`InboxItem` (teslim kopyası) = `{kind, title, body, image?{storagePath}, action?, createdAt (sunucu damgası, ZORUNLU — `order(by: "createdAt")` yoksa dokümanı atlar), expiresAt?}`.
**Aksiyon** (tek): `location` (`latitude`/`longitude`/`name` ≤120/`address`?/`placeId`?; "Konuma Git"), `exam` (admin yalnız `examId` verir; sunucu `exams/<id>`'den `path` [5 id], `names`, `examKind` doldurur, yayında değilse reddeder; "Sınava Git"), `paywall` ("Premium'a Göz At", aboneye gösterilmez), `addExam` ("Sınav Ekle"), `url` (yalnız `https`, ≤500; "Bağlantıyı Aç").
**Kitle:** `all` · `segment {universityId, facultyId?, departmentId? (fakülte gerektirir), gender?}` (admin istemcisi yalnız bu ikisini gönderebilir) · yalnız sunucu içi: `user {uid}`, `admins`. Admin seçicilerinde yalnızca kayıtlı kullanıcısı olan üniv./fakülte/bölüm, kişi sayılarıyla görünür.
**Teslim biçimi:** `broadcast` = (`general`\|`system`) + `all` → `announcements/<id>` + FCM topic `all` (token kaydetmeyen 4.0.0 istemcisine de ulaşır); `fanout` = geri kalan her şey (segment, **tüm `promo`**, kişisel, `admins`, test) → alıcı başına `users/<uid>/inbox/<id>` + kayıtlı token'lar (500'lük paketler; ölü token'ın cihaz dokümanı silinir). Push yalnızca teslim kopyası yazılan kullanıcıya gider.

**Function'lar** (`firebase/functions/`, europe-west1; v2, aksi belirtilmedikçe):

> 4.2.0'ın 9 yeni Function'ı (8 callable + `processExamConversion`) tablonun sonundadır, `onSubmissionModerated` satırı da 4.2.0'da değişti; **henüz canlıda değil** (yukarıdaki "13 Function canlıda" 4.1.0'ın kümesidir).

| Function | Tür | Ne yapar |
|---|---|---|
| `getNotificationAudience` | callable, admin | Seçicilerin ağacı: üniv. › fakülte › bölüm, kişi + cinsiyet sayıları (yalnız ad + sayı, PII yok) |
| `previewNotification` | callable, admin | `{kind, audience}` → `{recipients, pushTargets}` (kampanyada onay süzgeci uygulanmış) |
| `sendNotification` | callable, admin (300 sn) | Doğrular, `notifications/<id>`'yi yazar, ileri tarih/sessiz saatte `scheduled`, değilse hemen teslim eder; aynı `<id>` ikinci kez → mevcut sonuç (idempotent) |
| `cancelNotification` | callable, admin | Yalnız `scheduled` olanı iptal eder (transaction); diğerleri `failed-precondition` |
| `dispatchScheduledNotifications` | `onSchedule` (5 dk, Europe/Istanbul, 540 sn) | Vakti gelen `scheduled`'ı teslim eder (sessiz saate denk gelirse yeniden erteler, süresi dolanı `canceled/expired` yapar); 15 dk'dan uzun `sending`'de takılanı bir kez yeniden dener |
| `trackNotificationEvent` | callable, +90 | `opened` / `actionTapped` sayacı, kullanıcı başı tek; yalnız teslim kopyası olan alıcı sayılır |
| `onDeviceWritten` | Firestore `onDocumentWritten` `users/{uid}/devices/{id}` (`vifi`) | Aynı token başka hesapta kayıtlıysa eski cihaz dokümanını siler |
| `onSubmissionModerated` | Firestore `onDocumentUpdated` `submissions/{id}` (`vifi`) | `pending→approved`: sahibine "Sınavın onaylandı" (+coin, ledger'dan); **4.2.0:** onay `publishPlan` taşıyorsa (1. onay) ayrıca dönüştürme işi `sub-<id>` oluşturulup `processExamConversion` kuyruğuna verilir (sağlayıcı = admin'in seçimi; yoksa iş `queued` bekler), bölüm bildirimi 2. onaya (`publishExamConversion`) taşınır, mükerrerde (`mode: replace`) bölüm bildirimi yoktur; 4.1.0 onayı (`publishedExamId`, plan yok) hâlâ doğrudan bölümüne "yeni sınav" yollar ve sağlayıcısız `exam-<id>` işi bırakır. Yeni sınav yayınlandıysa bölümüne "yeni sınav" (`system`, onay süzgecine tabi değil; yükleyen hariç; bölüm başına İstanbul gününde en fazla 1, `notificationThrottle`). `pending→rejected`: sahibine sebepli bildirim |
| `onSubmissionCreated` | Firestore `onDocumentCreated` `submissions/{id}` (`vifi`) | Tüm admin'lere "Yeni sınav gönderimi" (`admins`: Auth `listUsers` + `admin` claim, örnek-içi 5 dk önbellek); **gönderen başına kayan 1 saatte en çok 3** (`notificationThrottle/submissions__<ownerId>`, kötüye kullanım koruması; gönderimler moderasyon listesine yine düşer) |
| `onExamDeleted` | Firestore `onDocumentDeleted` `exams/{examId}` (`vifi`) | Yapılandırılmış sınavın `questions/<id>-*`, `questionPools` kayıtları, `questionFigures/` dosyaları ve dönüşüm işini siler (`deleteStructuredExamData`); düz sınavda no-op, idempotent |
| `onAccountDeleted` | **v1** `auth.user().onDelete` | Hesap silme temizliği (aşağıda); v2'de Auth silme tetikleyicisi olmadığı için 1. nesil, hata olursa yeniden denenir |
| `requestExamConversion` | callable, admin | `{examId, provider}` → eski sınav için iş `exam-<id>` ("Yeni yapıya geçir"); etkin/yayınlanmış iş olduğu gibi döner |
| `requestBulkConversion` | callable, admin (300 sn) | `{courseId\|departmentId, provider, dryRun}` → `{examCount, estimatedCostUsd, jobIds}`; yalnız `dryRun: false` iş başlatır; en çok 200 sınav |
| `regenerateExamConversion` | callable, admin | `{jobId, provider}`: tümünü yeniden üret / başarısız işi yeniden başlat / sağlayıcı bekleyen işi başlat (K14); eski taslaklar silinir |
| `regenerateDraftQuestion` | callable, admin | `{jobId, order, provider}`: incelemedeki (`ready`) taslağın tek sorusunu yeniden üretir (K8) |
| `publishExamConversion` | callable, admin (300 sn) | `{jobId, subjectId?, newSubjectName?}`: **2. onay**; tek transaction'da taslakları `questions/<examId>-<nnn>`'e yayınlar, `exams`'i `format: structured` yapar (gönderimde katalog düğümleri + sınav de), havuzları + ders kimliğini günceller; bölüm bildirimi; idempotent |
| `discardExamConversion` | callable, admin | `{jobId}`: "Sınavı iptal et" (`discarded`); `sub-` işinde 1. onayın kopyaladığı dosyaları siler (K20) |
| `updatePublishedQuestion` | callable, admin | `{questionId, text?, speech?, choices?, answer?, solution?}`: yayındaki soruyu düzenler, anında yayında, id değişmez (K15) |
| `regeneratePublishedQuestion` | callable, admin | `{questionId, provider}`: yayındaki tek soruyu yeniden üretip aynı id altında yayına alır (K15) |
| `processExamConversion` | `onTaskDispatched` (Cloud Tasks, 1800 sn, 2 GiB, 3 deneme, en çok 3 eşzamanlı) | Yapay zekâ hattı: işi sahiplenir (aylık sınır + kira) → dosyaları indirir → seçilen sağlayıcıya (Vertex AI) verir → çıktıyı doğrular → şekilleri kırpar (`sharp`; PDF için `pdfjs-dist` + `@napi-rs/canvas`) → taslakları yazar → `ready` + `conversionReady`; hata/sınır: `failed` + `conversionFailed` ya da `queued` bekler + `conversionBudgetExceeded`; ayrıca tek soru yeniden üretme (`order` + `target`) |

Otomatik bildirimler `source: 'automatic'`, `createdBy: 'system'` ve deterministik id'lerle (`auto-approved-<gönderimId>`, `auto-rejected-…`, `auto-newexam-…`, `auto-submission-…`) `create()` edilir; olay tekrar gelse bile iki kez gitmez. Tetikleyiciler `exams` yazımına değil **gönderim moderasyonuna** bağlıdır (migrasyon script'i yüzlerce bildirim atmasın). Moderasyon kararı hâlâ istemcide verilir (bkz. *Gönderimler*); Function'lar yalnızca sonucuna tepki verir. Dönüştürme bildirimleri aynı biçimde deterministiktir: `auto-convready-<jobId>` (iş başına bir), `auto-convfailed-<jobId>-<deneme>`, `auto-convbudget-<YYYY-MM>` (ayda bir); uzun iş kimliği SHA-256 özetine çevrilir. Üçü de `admins` kitlesidir, anında gider, onay süzgeci ve sessiz saatler uygulanmaz.

**Kampanya onayı (Apple 4.5.4).** `promo` yalnızca `settings/notifications.marketing == true` olanlara gider; sunucu `fanout` öncesi süzer, onay vermeyen kampanyayı ne push ne sayfa olarak görür. Onay ayrı, varsayılan kapalı, atlanmaz ve Hesap › Bildirim Ayarları'ndan her an kapatılır; karşılığında ödül yoktur. İzin akışı: giriş sonrası ilk açılışta sessiz **provisional** izin (soru yok) → tanıtım turundan sonra 1/2 "Hiçbir şeyi kaçırma" (tam izin) → 2/2 "Öğrenci fırsatları" (kampanya onayı; yalnız tam izin varsa). Ret sonrası en erken 30 gün sonra **bir kez** bağlamsal tekrar (izin: ilk sınav gönderiminden sonra; onay: bildirim sayfası açılınca); sonrası yalnız Hesap'tan. Zaten tam izni olup onay kaydı olmayan kullanıcıya 2/2 bir kez sorulur.
**Sessiz saatler.** 22:00–09:00 (Europe/Istanbul) arası `promo` ve otomatik "yeni sınav" 09:00'a ertelenir (`scheduled` + `deferredByQuietHours`); admin'in seçtiği zaman sessiz saate denk gelirse de 09:00'a kayar (geçerlilik süresi bundan önce bitiyorsa reddedilir). Kişisel sistem bildirimleri, admin'e giden bildirimler ve test gönderimi anında gider.
**Push payload** (platform-bağımsız FCM): `notification{title, body, image?}`, `data{notificationId, kind}`, `apns` `mutable-content` **her** push'ta (extension her push'ta çalışsın), Android `channelId = kind`. Görsel için sunucu gönderim anında 7 günlük V4 imzalı URL üretir, yalnızca payload'a koyar.
**Hesap silme temizliği (`onAccountDeleted`; her adım idempotent, biri düşerse hata fırlatılır ve tetikleyici yeniden dener).** Silinir: Firestore `users/<uid>` ve tüm alt koleksiyonları (kilitler, inbox, cihazlar, ayarlar), `wallets/<uid>` + `ledger`, `subscriptions/<uid>`, onay bekleyen gönderimler + Storage `pending/<uid>/`, RTDB profil `users/<uid>`, eski RTDB `pendingExams/<uid>`, bildirim istatistiği işaretleri `notifications/<id>/events/<uid>_<event>` (koleksiyon grubu sorgusu, `events.uid` alan istisnası `firestore.indexes.json`'da; sayaçlar anonim kalır — 31 Ekim 2026 kararı, Android K3). **Kalır:** arşive eklenmiş sınavlar ve dosyaları; `purchasedTransactions` kaydı (tekrar kullanımı önlemek için, ama `uid` alanı kaldırılıp `accountDeletedAt` yazılır); incelenmiş (onaylı/reddedilmiş) gönderim kayıtları; rastgele uid referansları (gönderim `ownerId`, bildirim `audience.uid`) bilerek olduğu gibi bırakıldı.
**Rozet.** Uygulama arka plana geçerken ikon rozeti = okunmamış sayısı, açılınca 0; sayaç App Group `group.com.BuyukerYazilim.ViFi2` deposunda tutulur, `ViFiNotificationService` her push'ta `kayıtlı + 1` yapar ve görseli ekler (süre biterse görselsiz ama rozetli gösterir).

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

**Son güncelleme:** 13 Kasım 2026 (4.2.0 yapılandırılmış sınavlar: kod hazır, canlıya yayınlanmadı)
**Proje:** ViFi iOS (`com.BuyukerYazilim.ViFi2`)
