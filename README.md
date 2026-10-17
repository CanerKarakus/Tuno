<p align="center">
  <a href="https://gettuno.info"><img src="https://gettuno.info/og.png" alt="Tuno for macOS" width="720"></a>
</p>

<h1 align="center">Tuno</h1>

<p align="center">
  The missing controls for your Mac.<br>
  <a href="https://gettuno.info">gettuno.info</a>
</p>

---

Tuno is a native menu bar app that brings the controls macOS leaves out, in one quiet place. Built with SwiftUI and Core Audio. No drivers, no kernel extensions.

## Features

- **Sound** — Volume for every app, a separate output for any app, volume control for HDMI and DisplayPort displays, a system-wide equalizer with device profiles.
- **Devices** — Priority rules that pick the right speakers and microphone when you plug things in. A quick microphone level test.
- **Mouse & Trackpad** — Separate scroll directions, smooth scrolling for wheel mice, pointer acceleration off, side buttons for back and forward, middle click on the trackpad.
- **Displays** — Brightness for external monitors, from the menu bar or the keyboard.
- **Windows** — A window switcher with live previews, window previews in the Dock, and snapping to halves, thirds and quarters.
- **Everyday** — Clipboard history, Finder shortcuts, battery health and keep awake.

## Requirements

macOS 15 or later on a Mac with Apple silicon.

## Download

Get the latest version at [gettuno.info](https://gettuno.info). Official builds are signed and notarized by Apple (Developer ID: 72XQ32HJ4C) and update themselves.

## Build from source

You'll need Xcode 16 or later.

```sh
git clone https://github.com/CanerKarakus/Tuno.git
cd Tuno
./scripts/build-app.sh
open build/Tuno.app
```

The script packages the app with its Info.plist and entitlements, which macOS needs before it grants audio and accessibility permissions. You can also open `Package.swift` in Xcode to edit the code.

## Privacy

Tuno asks for a permission only when a feature needs it. Audio is processed in real time and never recorded, and nothing you copy or hear leaves your Mac.

## License

Tuno is open source under the [PolyForm Noncommercial License 1.0.0](LICENSE). You may download, study, change and use it for any noncommercial purpose. Selling it, publishing it commercially or including it in a paid product is not permitted.

Copyright © 2026 Caner Karakuş – [Geido Studio](https://geidostudio.com)

---

<details>
<summary><b>Türkçe</b></summary>

<br>

Tuno, macOS'ta eksik olan kontrolleri tek bir menü çubuğu uygulamasında toplar: uygulama başına ses, HDMI ve DisplayPort ekranlarda ses, sistem geneli ekolayzer, ayrı kaydırma yönleri, harici ekran parlaklığı, pencere geçişi ve pano geçmişi.

**İndir:** [gettuno.info](https://gettuno.info). Resmî sürümler Apple tarafından imzalı ve onaylıdır (Developer ID: 72XQ32HJ4C).

**Derle:** Xcode 16 ya da üstüyle `./scripts/build-app.sh`, ardından `open build/Tuno.app`.

**Lisans:** Açık kaynak, [PolyForm Noncommercial 1.0.0](LICENSE). İndirip inceleyebilir, değiştirebilir ve ticari olmayan her amaçla kullanabilirsiniz. Satmak, ticari olarak yayınlamak ya da ücretli bir ürüne katmak lisansa aykırıdır.

</details>
