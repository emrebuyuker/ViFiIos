# firebase/

ViFi Firebase projesinin güvenlik kuralları, kural testleri ve bakım betikleri. Uygulama koduyla ilgisi yoktur;
ayrıntılı açıklama için kök [README.md](../README.md) içindeki *Firebase Güvenlik Kuralları* bölümüne bakın.

| Dosya | Amaç |
|---|---|
| `database.rules.json` | Realtime Database kuralları |
| `storage.rules` | Cloud Storage kuralları |
| `firebase.json`, `.firebaserc` | Emülatör portları ve varsayılan proje (`vifi-831a8`) |
| `scripts/revoke-download-tokens.mjs` | Storage indirme belirteçlerini yedekler, iptal eder, geri yükler |
| `scripts/convert-legacy-exams.mjs` | Eski sınavları tek seferlik yeni yapıya geçirme işlerini başlatır (4.2.0, K12c) |
| `firestore.rules`, `firestore.indexes.json` | Cloud Firestore (`vifi` DB) kuralları ve bileşik indeksleri |
| `functions/` | Cloud Functions (europe-west1): `unlockExam`, `recordLoginDiagnostic`, `purchaseExamUnlock`, bildirimler (`notifications/`), hesap silme temizliği ve 4.2.0 yapılandırılmış sınav hattı (`conversions/`, aşağıda) |
| `tests/` | Kural testleri (emülatör), Function handler testleri (bildirim + dönüştürme), satın alma doğrulama testleri ve betik testleri |

## Gereksinimler

- Node.js 22 veya üzeri, Firebase CLI (`npm i -g firebase-tools`), Java 21.
- Bu klasörde ve `functions/` içinde birer kez `npm install` çalıştırın.

## Testler

```bash
cd firebase
JAVA_HOME=/opt/homebrew/opt/openjdk@21 npm test      # auth + database + storage emülatörleri, proje: demo-vifi
npm run test:script                                  # yalnızca betik testleri (emülatör gerekmez)
```

Testler yalnızca yerel emülatöre ve bellek içi bir Storage sahtesine bağlanır; gerçek projeye dokunmaz. Yapay zekâ hattı testleri
(`conversionPipeline`, `conversionAdmin`) **sahte model sağlayıcısı**, sahte PDF çizici ve sahte bucket ile çalışır: Vertex AI'ya çıkmaz, para harcamaz.

## Yayınlama

> [!WARNING]
> Kurallar yayınlandığı anda eski uygulama sürümleri çalışmaz. Önce giriş ve App Check içeren yeni sürüm hazır olmalıdır.

```bash
cd firebase
firebase deploy --only database,storage --project vifi-831a8 --account <sahip hesabı>
```

## Yapılandırılmış sınavlar (4.2.0)

> [!WARNING]
> **Aşağıdakilerin hiçbiri canlıda değil.** Yeni Firestore/Storage kuralları, indeksler, 8 callable, `processExamConversion` kuyruğu ve Vertex AI
> etkinleştirmesi yalnızca proje sahibinin açık onayıyla, 4.1.0 canlıya çıktıktan sonra yayınlanır. Sözleşmenin yetkili kaynağı
> `functions/conversions/schema.js`'tir; iOS modelleri onu aynalar.

Eski bir sınavın ya da onaylanan bir gönderimin dosyaları yapay zekâyla sorulara çevrilir; admin inceleyip yayınlar. Ürün tarafı: kök
[README.md](../README.md) › *Soru soru sınavlar*.

| Function | Tür | Ne yapar |
|---|---|---|
| `requestExamConversion` | callable, admin | Eski sınav için iş `exam-<id>` açar (`{examId, provider}`) |
| `requestBulkConversion` | callable, admin | Ders/bölüm için toplu iş (`dryRun` tahmin döner; en çok 200 sınav) |
| `regenerateExamConversion` | callable, admin | Tümünü yeniden üret / başarısız işi yeniden başlat / sağlayıcı bekleyen işi başlat |
| `regenerateDraftQuestion` | callable, admin | İncelemedeki taslağın tek sorusunu yeniden üretir |
| `publishExamConversion` | callable, admin | 2. onay: taslağı `questions`'a yayınlar (tek transaction), havuz + ders kimliği günceller |
| `discardExamConversion` | callable, admin | "Sınavı iptal et"; gönderim işinde 1. onayın kopyaladığı dosyaları siler |
| `updatePublishedQuestion` | callable, admin | Yayındaki soruyu düzenler (anında yayında, id değişmez) |
| `regeneratePublishedQuestion` | callable, admin | Yayındaki tek soruyu yeniden üretip aynı id altında yayına alır |
| `processExamConversion` | `onTaskDispatched` (Cloud Tasks; 1800 sn, 2 GiB, 3 deneme, en çok 3 eşzamanlı) | Yapay zekâ hattı: dosyalar → Vertex AI (Claude ya da Gemini) → doğrulama → şekil kırpma → taslaklar → `ready` |
| `onSubmissionModerated` (değişti) | Firestore tetikleyicisi | 1. onay (`publishPlan`) → iş `sub-<id>` + kuyruk; bölüm bildirimi 2. onaya taşındı; 4.1.0 onayı → sağlayıcısız `exam-<id>` işi |

- **Model seçimi:** her yapay zekâ işleminde `provider: 'claude' | 'gemini'` zorunludur, sunucuda varsayılan yoktur. Model kimliği, bölge (`global`), fiyat ve
  üretim ayarı yalnızca `functions/conversions/providers/config.js`'tedir; `VERIFY` işaretli değerler ilk canlı çağrıdan önce Vertex Model Garden ve fiyat
  sayfasından doğrulanır. Kimlik Functions servis hesabıdır (ADC); API anahtarı yoktur.
- **Önkoşullar (canlı, sahibin onayıyla):** `vifi-831a8`'de Vertex AI API açık, Model Garden'da Claude Opus 5.5 etkin (Anthropic koşulları), Gemini Pro erişimi,
  Functions servis hesabına Vertex AI kullanıcı rolü, Cloud Tasks kuyruğu (`processExamConversion` yayınıyla oluşur), Google Cloud bütçe uyarısı. Yeni npm
  bağımlılıkları: `@anthropic-ai/vertex-sdk`, `@google/genai`, `sharp`, `pdfjs-dist`, `@napi-rs/canvas` (`npm --prefix functions ci`).
- **Aylık sınır:** `aiUsage/<YYYY-MM>` (Europe/Istanbul ayı) aylık 50 $'ı aşarsa yeni işler `queued` bekler, ay başında devam eder; ayda bir
  `conversionBudgetExceeded` bildirimi gider. `budget: 'oneTime'` işler (betik) sayaca girmez, `oneTime` altında ayrı toplanır.
- **Bildirimler:** `conversionReady`, `conversionFailed`, `conversionBudgetExceeded` (admin kitlesi, anında). Deterministik id'ler: `auto-convready-<iş>`,
  `auto-convfailed-<iş>-<deneme>`, `auto-convbudget-<YYYY-MM>`.
- **Şekiller:** `questionFigures/<iş>/<nnn>-<k>[-r<rev>].jpg`; bir soru yeniden üretilince sürümlü yola (`-r<rev>`) yazılır ve eski dosya silinir.
- **Sınav silme temizliği:** `onExamDeleted` (Firestore `exams/{id}` silinince) `deleteStructuredExamData` ile soruları, havuz kayıtlarını, `questionFigures/` dosyalarını ve işi siler; düz sınavda no-op, idempotent.

```bash
cd firebase
JAVA_HOME=/opt/homebrew/opt/openjdk@21 npm test          # conversionSchema / conversionPipeline / conversionAdmin / convertLegacyExams dahil
# Yayın (YALNIZCA sahip onayıyla; 4.1.0 canlıya çıktıktan sonra):
firebase deploy --only firestore,storage,functions --project vifi-831a8 --account <sahip hesabı>
```

## Parayla sınav açma (`purchaseExamUnlock`)

Tek sınavın parayla açılmasını iki mağaza için de sunucuda doğrular, ardından aynı Firestore transaction'ında
`purchasedTransactions/<işlem>` (bir satın alma yalnız bir sınavı bir kez açar) ve `users/<uid>/unlocks/<sınav>`
(`source: 'purchase'`) yazar. Aynı kullanıcı + sınav + satın alma ile tekrar çağrı idempotenttir.

| Platform | İstek | Doğrulama (`functions/`) | Tekrar kullanım anahtarı |
|---|---|---|---|
| iOS (`platform` yok) | `examId`, `signedTransaction` (StoreKit 2 JWS) | `appStore.js` — Apple imzası, paket, ürün | Apple `transactionId` |
| Android (`platform: 'android'`) | `examId`, `purchaseToken`, `productId` | `googlePlay.js` — Play Developer API `purchases.products.get`: ödendi, ürün `exam_unlock`, `obfuscatedExternalProfileId` = `examId`'nin SHA-256 özeti (sınav kimlikleri Play'in 64 karakter sınırından uzun) | `orderId` (yoksa `play-token-<jeton SHA-256>`); kayıtlara `store: 'google_play'` eklenir |

Sunucu satın almayı tüketmez; Android istemcisi kayıt başarılı olunca tüketir. Android hata kodları: geçersiz satın alma
`failed-precondition`, Google Play'e ulaşılamıyor `unavailable`, API erişimi yok `internal`.

**Android dalı için önkoşul:** `vifi-831a8`'de *Google Play Android Developer API* etkin olmalı ve Functions çalışma
servis hesabı Play Console → Kullanıcılar ve izinler'de ViFi uygulaması için finansal verileri görüntüleme izniyle davetli
olmalı. İzin yayılması saatler sürebilir; o sürede çağrılar `internal` döner.

> [!WARNING]
> Function yayını ortak backend'i değiştirir; yalnız proje sahibinin açık onayıyla yapılır. Yayından sonra iOS sandbox
> satın almasının hâlâ çalıştığını kontrol edin.

```bash
cd firebase
firebase deploy --only functions:purchaseExamUnlock --project vifi-831a8 --account <sahip hesabı>
```

## Güncelleme politikası (`config/appUpdate/ios`)

Uygulamanın zorunlu/opsiyonel güncelleme kapısı bu düğümden okur (`RemoteAppUpdateChecker`). Kurulu sürüm
`minimumVersion`'ın altındaysa kapatılamayan zorunlu ekran, `latestVersion`'dan eskiyse kapatılabilir öneri çıkar.
Düğüm herkese okunur (üretimde App Check zorunlu), yazma yalnızca `admin: true` claim'i olan hesaptadır.

Değerleri Console'dan (Realtime Database) veya admin bir oturumla yazın — alan kurallarına uyması gerekir
(`minimumVersion`/`latestVersion`: `N.N.N.N`'e kadar sayısal; `storeURL`: `https://` ile başlar, ≤500; `message`: ≤300):

```json
{
  "config": {
    "appUpdate": {
      "ios": {
        "minimumVersion": "3.0.0",
        "latestVersion": "3.0.0",
        "storeURL": "https://apps.apple.com/tr/app/vifi/id6670324094",
        "message": "Daha iyi bir deneyim için uygulamayı güncelle."
      }
    }
  }
}
```

> Zorunlu güncellemeyi yalnızca kullanıcılara sunulmuş (App Store'da yayınlanmış) bir sürümü `minimumVersion` yaparak
> tetikleyin; aksi halde kullanıcılar indiremeyecekleri bir sürüm için kilitlenir.

Android aynı şemayı kendi düğümünden okur (`config/appUpdate/android`, alan adları birebir aynı — `storeURL` dahil;
Android sürümleri iOS ile aynı seridedir, ör. `3.1.0`):

```json
{
  "config": {
    "appUpdate": {
      "android": {
        "minimumVersion": "3.1.0",
        "latestVersion": "3.1.0",
        "storeURL": "https://play.google.com/store/apps/details?id=com.salticusteam.vifi",
        "message": "Daha iyi bir deneyim için uygulamayı güncelle."
      }
    }
  }
}
```

> Android'de de `minimumVersion` yalnızca Google Play'de yayınlanmış bir sürüm olmalıdır.

## Belirteç iptali

```bash
gcloud auth application-default login        # proje sahibi olarak
node scripts/revoke-download-tokens.mjs backup  --out backups/tokens-<tarih>.json
node scripts/revoke-download-tokens.mjs revoke  --backup backups/tokens-<tarih>.json            # deneme (değişiklik yok)
node scripts/revoke-download-tokens.mjs revoke  --backup backups/tokens-<tarih>.json --apply
node scripts/revoke-download-tokens.mjs restore --from   backups/tokens-<tarih>.json --apply    # geri al
```

- `revoke` ve `restore`, `--apply` olmadan yalnızca sayıları raporlar.
- Yedek eksik ya da geçersizse veya iptal edilecek bir nesneyi kapsamıyorsa `revoke --apply` reddeder (çıkış kodu 2).
- Her iptalden önce yeni bir yedek alın; okumalar belirteçleri yeniden üretebilir.
- `backups/` git tarafından yok sayılır; yedek yalnızca sahibi tarafından okunabilir (0600) yazılır.
- Gerçek bucket için `STORAGE_EMULATOR_HOST` ayarlamayın. Betiğin ilk satırı hedefi yazar
  (`PRODUCTION Cloud Storage` veya `emulator <host>`).
- Emülatör belirteç iptalini doğru yansıtmaz; iptal/geri yükleme döngüsü `tests/fake-gcs-server.mjs` ile test edilir.

## Eski sınavların tek seferlik geçişi (4.2.0, K12c / K24)

```bash
cd firebase
node scripts/convert-legacy-exams.mjs --provider claude --course <ders-id>                 # yerel emülatörde deneme
gcloud auth application-default login        # proje sahibi olarak
node scripts/convert-legacy-exams.mjs --provider gemini --project vifi-831a8 --confirm-project vifi-831a8 [--limit 10]          # canlı deneme (yalnız okur)
node scripts/convert-legacy-exams.mjs --provider gemini --project vifi-831a8 --confirm-project vifi-831a8 --apply [--limit 10]  # YALNIZCA sahip onayıyla
```

- `--provider` zorunludur (varsayılan yok). Kapsam: `--course <id>` ya da `--department <id>`; ikisi de yoksa tüm arşiv.
- Varsayılan deneme (`--dry-run`): sınav sayısı, tahmini sayfa ve tahmini maliyet yazılır, hiçbir şey yazılmaz.
- `--apply` işleri `budget: 'oneTime'` ile açar (aylık 50 $ sınırına girmez, `aiUsage/<ay>.oneTime` altında toplanır) ve
  `processExamConversion` kuyruğuna verir; taslaklar yine admin incelemesinden tek tek geçer, betik hiçbir şey yayınlamaz.
- Yerel emülatör dışındaki her çalıştırma `--project` ve aynı değerle `--confirm-project` ister; yoksa reddeder (çıkış kodu 2).
- Tekrar çalıştırmak güvenlidir: yeni yapıdaki, işi kuyrukta/işlenmekte/incelemede olan, işi başarısız/iptal/yayınlanmış
  sınavlar atlanır; yalnızca işi olmayan ya da sağlayıcı bekleyen (4.1.0 onayından kalan) / kuyruğa verilememiş sınavlar başlatılır.
- Önce `npm --prefix functions ci` çalıştırın (betik, Admin SDK'yı ve iş yardımcılarını `functions/` içinden kullanır).
- Emulator'de (`FIRESTORE_EMULATOR_HOST`) işler yalnızca açılır ve `queued` kalır; `CLOUD_TASKS_EMULATOR_HOST` verilmedikçe kuyruğa gönderilmez. Canlıda işler,
  `gcloud auth application-default login` ile proje sahibinin kimliğiyle `processExamConversion` kuyruğuna verilir; kuyruk, Function yayınlanmadan yoktur.
- Çıkış kodları: 0 başarılı, 1 en az bir sınav başlatılamadı, 2 kullanım hatası ya da reddedildi. Testi: `tests/convertLegacyExams.test.mjs`.
- Betik yalnızca iş açar; hiçbir şey yayınlamaz. Maliyet tahmini kabadır (`ESTIMATED_COST_PER_PAGE_USD`, sayfa başına); gerçek harcama işlerin `usage`'ında ve
  `aiUsage/<ay>.oneTime` altında görünür.
