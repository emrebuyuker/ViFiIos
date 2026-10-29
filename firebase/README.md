# firebase/

ViFi Firebase projesinin güvenlik kuralları, kural testleri ve bakım betikleri. Uygulama koduyla ilgisi yoktur;
ayrıntılı açıklama için kök [README.md](../README.md) içindeki *Firebase Güvenlik Kuralları* bölümüne bakın.

| Dosya | Amaç |
|---|---|
| `database.rules.json` | Realtime Database kuralları |
| `storage.rules` | Cloud Storage kuralları |
| `firebase.json`, `.firebaserc` | Emülatör portları ve varsayılan proje (`vifi-831a8`) |
| `scripts/revoke-download-tokens.mjs` | Storage indirme belirteçlerini yedekler, iptal eder, geri yükler |
| `functions/` | Cloud Functions (europe-west1): `unlockExam`, `recordLoginDiagnostic`, `purchaseExamUnlock` |
| `tests/` | Kural testleri (emülatör), satın alma doğrulama testleri ve betik testleri |

## Gereksinimler

- Node.js 22 veya üzeri, Firebase CLI (`npm i -g firebase-tools`), Java 21.
- Bu klasörde ve `functions/` içinde birer kez `npm install` çalıştırın.

## Testler

```bash
cd firebase
JAVA_HOME=/opt/homebrew/opt/openjdk@21 npm test      # auth + database + storage emülatörleri, proje: demo-vifi
npm run test:script                                  # yalnızca betik testleri (emülatör gerekmez)
```

Testler yalnızca yerel emülatöre ve bellek içi bir Storage sahtesine bağlanır; gerçek projeye dokunmaz.

## Yayınlama

> [!WARNING]
> Kurallar yayınlandığı anda eski uygulama sürümleri çalışmaz. Önce giriş ve App Check içeren yeni sürüm hazır olmalıdır.

```bash
cd firebase
firebase deploy --only database,storage --project vifi-831a8 --account <sahip hesabı>
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
