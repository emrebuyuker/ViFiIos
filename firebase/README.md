# firebase/

ViFi Firebase projesinin güvenlik kuralları, kural testleri ve bakım betikleri. Uygulama koduyla ilgisi yoktur;
ayrıntılı açıklama için kök [README.md](../README.md) içindeki *Firebase Güvenlik Kuralları* bölümüne bakın.

| Dosya | Amaç |
|---|---|
| `database.rules.json` | Realtime Database kuralları |
| `storage.rules` | Cloud Storage kuralları |
| `firebase.json`, `.firebaserc` | Emülatör portları ve varsayılan proje (`vifi-831a8`) |
| `scripts/revoke-download-tokens.mjs` | Storage indirme belirteçlerini yedekler, iptal eder, geri yükler |
| `tests/` | Kural testleri (emülatör) ve betik testleri |

## Gereksinimler

- Node.js 22 veya üzeri, Firebase CLI (`npm i -g firebase-tools`), Java 21.
- Bu klasörde bir kez `npm install` çalıştırın.

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
