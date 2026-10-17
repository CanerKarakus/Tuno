# Tuno

macOS'ta Windows'un aksine yerleşik olarak bulunmayan ses denetimlerini getiren yerel (SwiftUI + Core Audio) bir uygulama.

## Neden?

Mac kullanıcılarının en sık şikâyet ettiği ses eksikleri:

| Eksik | Windows | macOS | Tuno |
|---|---|---|---|
| Uygulama başına ses düzeyi (mikser) | ✅ | ❌ | ✅ |
| Uygulamayı sessize alma | ✅ | ❌ | ✅ |
| Uygulamaya özel çıkış aygıtı | ✅ | ❌ | ✅ |
| %100 üzeri ses yükseltme | kısmen | ❌ | ✅ (%200'e kadar) |
| Hızlı aygıt değiştirme, denge, örnekleme hızı | ✅ | dağınık | ✅ |
| HDMI/DisplayPort ekranlarda ses denetimi | ✅ | ❌ | ✅ (yazılımsal + ses tuşları) |
| Sistem geneli ekolayzer | ✅ (sürücüyle) | ❌ | ✅ (10 bant, aygıt profilleri) |
| Öndeki uygulamanın sesi için kısayol | ❌ | ❌ | ✅ |
| Mikrofon seviye testi | ✅ | ✅ | ✅ |
| Trackpad ve fare için ayrı kaydırma yönü | ✅ | ❌ | ✅ (önizlemeli) |
| Trackpad ve fare için ayrı geri/ileri yönü | – | ❌ | ✅ (önizlemeli) |
| Tekerlekli farede yumuşak kaydırma | ✅ | ❌ | ✅ |
| Fare hızlandırmasını kapatma | ✅ | ❌ | ✅ |
| Fare yan/orta tuş atama (Safari'de geri/ileri dahil) | ✅ | ❌ | ✅ |
| Trackpad'de orta tık | ✅ | ❌ | ✅ (üç parmak dokunuşu) |
| Ses aygıtı öncelik kuralları | kısmen | ❌ | ✅ |
| Harici monitör parlaklığı | ✅ | ❌ | ✅ (DDC/CI + yazılımsal) |
| Pencereler arası Alt-Tab | ✅ | ❌ | ✅ (⌥⇥) |
| Görev çubuğu/Dock pencere önizlemesi | ✅ | ❌ | ✅ |
| Pano geçmişi | ✅ (Win+V) | ❌ | ✅ (⌘⇧V) |

## Nasıl çalışır?

Sürücü kurmadan, macOS 14.2 ile gelen **Core Audio Process Tap** API'si kullanılır:

```
uygulama süreçleri ─▶ uygulama tap'i ─┐
                                      ├─▶ TapDSP: kazanç × yazılım sesi × ön kazanç → 10 bant EQ → limiter ─▶ aygıt
geri kalan tüm ses ─▶ aygıt tap'i ────┘   (Tuno'nun kendi süreci ve uygulama tap'leri hariç tutulur)
```

Yalnızca gerekince tap kurulur: ayarı değiştirilen uygulamalar için uygulama tap'i; EQ açıkken ya da
yazılımsal ses kullanılırken "geri kalan" aygıt tap'i. Kurulan tap'ler değişikliklerde yıkılmaz, yerinde güncellenir.
İlk kullanımda macOS **Ses Kaydı** izni ister (ses kaydedilmez, hiçbir yere gönderilmez).

## Derleme

```sh
./scripts/build-app.sh          # build/Tuno.app (release)
open build/Tuno.app
```

Gereksinimler: macOS 15+, Xcode 16+ (Swift 6). Kod Xcode'da `Package.swift` açılarak da düzenlenebilir;
ancak tap izni için uygulamanın `build-app.sh` ile paketlenmiş hâli çalıştırılmalıdır (Info.plist gerekir).

> Betik Keychain'deki "Apple Development" sertifikasıyla imzalar; böylece Ses Kaydı ve Erişilebilirlik izinleri derlemeler arasında korunur. Sertifika yoksa ad-hoc imzalar.

## Yapı

```
Sources/Tuno/
  App/        TunoApp (pencere + menü çubuğu), ContentView (kenar çubuğu)
  CoreAudio/  AudioObject yardımcıları, AudioDevice, AudioProcess, AudioTap, AudioDSP (biquad EQ + limiter)
  Model/      DeviceStore + DeviceRules, Mixer (ses motoru), Equalizer, ShortcutCenter, InputMeter,
              PointerController (kaydırma, tuşlar, hızlandırma), MultitouchMonitor, DisplayController (DDC),
              WindowCatalog + WindowSwitcher + DockPreviews, ClipboardHistory
  Support/    KeyboardLayout, SyntheticEvent, Glass
  Views/      Mikser, Çıkış/Giriş, Ekolayzer, Kısayollar, Genel, Hakkında, Menü çubuğu, VolumeHUD
```

## Yol haritası

- [x] Faz 1: Uygulama mikseri, ses yükseltme, uygulama başına çıkış, aygıt sayfaları, menü çubuğu
- [x] Faz 2: HDMI/DisplayPort için yazılımsal ses, sistem geneli 10 bant ekolayzer + hazır ayarlar
- [x] Faz 3: Klavye kısayolları + HUD, ses tuşları (yazılımsal ses), aygıt EQ profilleri, mikrofon testi
- [x] Fare/Trackpad: aygıta göre ayrı kaydırma ve sayfa geçişi yönü (Sistem Ayarları önizleme videolarıyla)
- [ ] Fare (devam): yumuşak kaydırma, hızlandırmayı kapatma, yan/orta tuş atamaları
- [ ] Sonra: özelleştirilebilir kısayollar, uygulama ayarlarının aygıta göre profillenmesi, Sparkle ile güncelleme, notarizasyon

## Lisans

Tuno açık kaynaktır: [PolyForm Noncommercial 1.0.0](LICENSE). Kodu indirip inceleyebilir, değiştirebilir ve kişisel ya da ticari olmayan amaçlarla kullanabilirsiniz. Ticari amaçla yayınlamak, satmak ya da ücretli bir ürüne katmak lisansa aykırıdır.

Tuno is open source under the [PolyForm Noncommercial License 1.0.0](LICENSE): you may download, study, modify and use it for any noncommercial purpose. Publishing it commercially, selling it or bundling it into a paid product is not permitted.

Telif © 2026 Caner Karakuş - Geido Studio ([geidostudio.com](https://geidostudio.com)). Resmî sürümler [gettuno.info](https://gettuno.info) adresinden dağıtılır ve Apple tarafından imzalı ve onaylıdır (Developer ID: 72XQ32HJ4C).

Copyright © 2026 Caner Karakuş - Geido Studio. Official builds are distributed from gettuno.info and are signed & notarized by Apple (Developer ID: 72XQ32HJ4C).
