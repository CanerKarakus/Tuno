import AVFoundation
import SwiftUI

/// Ayarlar › Yüz Tanıma. Model inmemişse yalnızca indirme; inmişse yüzler ve özellikler.
struct FaceIDSettingsView: View {
    @State private var passwordSheet = false
    @State private var confirmRemove = false
    @State private var renaming: EnrolledFace?
    @State private var newName = ""
    @State private var deleting: EnrolledFace?
    @State private var historyFace: EnrolledFace?
    @State private var camera = FaceCamera.authorization

    private var faceID: FaceID { FaceID.shared }
    private var models: FaceModels { FaceModels.shared }

    var body: some View {
        Form {
            Section { PageHeader(page: .faceID, beta: true) }
            if camera == .denied || camera == .restricted { cameraSection }
            if !models.isReady {
                downloadSection
            } else if !faceID.engineReady {
                Section {
                    HStack(spacing: 10) {
                        ProgressView().controlSize(.small)
                        Text(L("Yüz tanıma hazırlanıyor…")).foregroundStyle(.secondary)
                    }
                }
            } else {
                facesSection
                featuresSection
                Section {
                    LabeledContent(L("Yüz tanıma")) {
                        Button(L("Kaldır…"), role: .destructive) { confirmRemove = true }
                    }
                } footer: {
                    privacyFooter
                }
            }
            PageFooter()
        }
        .formStyle(.grouped)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            camera = FaceCamera.authorization
        }
        .task {
            // Model inmiş ama kamera izni sorulmamışsa (ör. izinler sıfırlandı) sayfa açılınca sorulur.
            guard models.isReady, camera == .notDetermined else { return }
            _ = await FaceCamera.requestAccess()
            camera = FaceCamera.authorization
            faceID.guardian.refresh()
        }
        .sheet(isPresented: $passwordSheet) { PasswordSheet { passwordSheet = false } }
        .sheet(item: $historyFace) { face in
            HistorySheet(face: faceID.store.faces.first { $0.id == face.id } ?? face) { historyFace = nil }
        }
        .alert(L("Yeniden Adlandır"), isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField(L("Ad"), text: $newName)
            Button(L("Kaydet")) { if let renaming { faceID.store.rename(renaming.id, to: newName) } }
            Button(L("Vazgeç"), role: .cancel) {}
        }
        .confirmationDialog(String(format: L("“%@” silinsin mi?"), deleting?.name ?? ""),
                            isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })) {
            Button(L("Sil"), role: .destructive) {
                if let deleting { faceID.store.remove(deleting.id) }
                if faceID.store.faces.isEmpty { faceID.guardian.refresh() }
            }
        }
        .confirmationDialog(L("Yüz tanıma kaldırılsın mı?"), isPresented: $confirmRemove) {
            Button(L("Kaldır"), role: .destructive) { faceID.removeEverything() }
        } message: {
            Text(L("Model, kayıtlı yüzler ve kaydedilen Mac şifresi silinir. Gizli öğeler yeniden görünür olur."))
        }
    }

    // MARK: - İndirme

    private var downloadSection: some View {
        Section {
            HStack(spacing: 14) {
                ZStack {
                    if models.isBusy {
                        DownloadRing(progress: models.progress, installing: models.state == .installing) { models.cancel() }
                    } else {
                        Image(systemName: "faceid").font(.system(size: 30, weight: .light)).foregroundStyle(.green)
                    }
                }
                .frame(width: 44, height: 44)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.headline)
                    Text(detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                if !models.isBusy {
                    Button(isFailed ? L("Tekrar Dene") : String(format: L("İndir (%@)"), FaceModels.sizeText)) { startDownload() }
                        .buttonStyle(.borderedProminent)
                        .disabled(camera == .denied || camera == .restricted)
                }
            }
            .padding(.vertical, 4)
            .animation(.smooth(duration: 0.3), value: models.isBusy)
        } footer: {
            privacyFooter
        }
    }

    private var isFailed: Bool { if case .failed = models.state { true } else { false } }

    private var title: String {
        switch models.state {
        case .downloading: L("İndiriliyor…")
        case .installing: L("Kuruluyor…")
        case .failed: L("İndirilemedi")
        default: L("Yüz tanımayı indir")
        }
    }

    private var detail: String {
        switch models.state {
        case .downloading(let value):
            let done = ByteCountFormatter.string(fromByteCount: Int64(Double(FaceModels.packageBytes) * value), countStyle: .file)
            return String(format: L("%@ / %@"), done, FaceModels.sizeText)
        case .failed(let message): return message
        case .installing: return L("Neredeyse bitti.")
        default: return L("Yüzünle Mac'in kilidini aç, gizli öğeleri sakla. Yüzün Mac'inden hiçbir zaman çıkmaz.")
        }
    }

    private func startDownload() {
        Task {
            guard await FaceCamera.requestAccess() else { camera = FaceCamera.authorization; return }
            camera = FaceCamera.authorization
            faceID.autoEnroll = true
            models.download()
        }
    }

    private var cameraSection: some View {
        Section {
            HStack {
                Label(L("Kamera izni kapalı. Yüz tanıma kamera olmadan çalışmaz."), systemImage: "video.slash.fill")
                    .foregroundStyle(.orange)
                Spacer()
                Button(L("Sistem Ayarları'nı Aç")) {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Camera")!)
                }
            }
        }
    }

    private var privacyFooter: some View {
        HStack(spacing: 4) {
            Text(L("Yüzün yalnızca bu Mac'te işlenir ve şifreli saklanır; bize ya da başka bir yere gönderilmez."))
            Link(L("Gizlilik"), destination: Site.url("/privacy/#face"))
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    // MARK: - Yüzler

    private var facesSection: some View {
        Section(L("Yüzler")) {
            ForEach(faceID.store.faces) { face in
                HStack(spacing: 10) {
                    Image(systemName: "person.crop.circle.fill")
                        .font(.system(size: 26))
                        .foregroundStyle(.green.gradient)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(face.name)
                        Text(String(format: L("Eklendi: %@"), face.created.formatted(date: .abbreviated, time: .omitted)))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Menu {
                        Button(L("Benzerlik Geçmişi…")) { historyFace = face }
                        Button(L("Yeniden Adlandır…")) { newName = face.name; renaming = face }
                        Button(L("Sil…"), role: .destructive) { deleting = face }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                }
            }
            Button {
                faceID.startEnrollment()
            } label: {
                Label(faceID.store.faces.isEmpty ? L("Yüzünü Tara…") : L("Yüz Ekle…"), systemImage: "plus.viewfinder")
            }
            .disabled(faceID.enrollment != nil || camera != .authorized && camera != .notDetermined)
            .searchAnchor("Yüz Ekle…")
        }
    }

    // MARK: - Özellikler

    private var featuresSection: some View {
        @Bindable var presence = faceID.presence
        @Bindable var guardian = faceID.guardian
        let ready = !faceID.store.faces.isEmpty
        return Section {
            Toggle(isOn: Binding(get: { faceID.unlock.isActive }, set: { on in
                if on, !faceID.unlock.hasPassword || faceID.unlock.passwordInvalid {
                    passwordSheet = true
                } else {
                    faceID.unlock.isEnabled = on
                }
            })) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(L("Mac'in kilidini yüzle aç"))
                    Text(L("Kilit ekranında çentikten tarar; Touch ID de çalışmaya devam eder."))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .searchAnchor("Mac'in kilidini yüzle aç")
            if faceID.unlock.passwordInvalid {
                HStack {
                    Label(L("Kaydedilen şifre kilidi açmadı. Mac şifren değişmiş olabilir."), systemImage: "exclamationmark.triangle.fill")
                        .font(.caption).foregroundStyle(.orange)
                    Spacer()
                    Button(L("Şifreyi Gir…")) { passwordSheet = true }
                }
            }
            Toggle(isOn: $presence.isEnabled) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) { Text(L("Uzaklaşınca kilitle")); BetaBadge() }
                    Text(L("Klavye ve fare 30 saniye kullanılmazsa kamera bakar; kimse yoksa müzik durur ve ekran kilitlenir. Uyanık Tut açıkken bakılmaz."))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .searchAnchor("Uzaklaşınca kilitle")
            Toggle(isOn: $guardian.isEnabled) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) { Text(L("Başkası bakarsa gizle")); BetaBadge() }
                    Text(L("Arkanda tanınmayan biri belirince bildirimler ve pano gizlenir. Açıkken kamera sürekli açıktır."))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .searchAnchor("Başkası bakarsa gizle")
        } footer: {
            Text(L("Gizli öğeler: pano geçmişinde ya da dosya rafında bir öğeye sağ tıklayıp Gizle'yi seçin. Yalnızca yüzün tanınınca görünür."))
                .font(.caption).foregroundStyle(.secondary)
        }
        .disabled(!ready)
    }
}

/// App Store'daki gibi indirme halkası: gri iz, ilerleyen yay, ortada durdurma karesi.
struct DownloadRing: View {
    let progress: Double
    var installing = false
    var lineWidth: CGFloat = 3
    var onCancel: (() -> Void)?
    @State private var spin = false

    var body: some View {
        ZStack {
            Circle().stroke(Color.secondary.opacity(0.25), lineWidth: lineWidth)
            if installing {
                Circle()
                    .trim(from: 0, to: 0.28)
                    .stroke(Color.accentColor, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                    .rotationEffect(.degrees(spin ? 360 : 0))
                    .animation(.linear(duration: 0.9).repeatForever(autoreverses: false), value: spin)
                    .onAppear { spin = true }
            } else {
                Circle()
                    .trim(from: 0, to: max(progress, 0.02))
                    .stroke(Color.accentColor, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(.linear(duration: 0.25), value: progress)
                if let onCancel {
                    Button(action: onCancel) {
                        RoundedRectangle(cornerRadius: 2, style: .continuous)
                            .fill(Color.accentColor)
                            .frame(width: 9, height: 9)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .help(L("İndirmeyi durdur"))
                }
            }
        }
        .padding(lineWidth / 2)
    }
}

/// Kenar çubuğundaki satır: model inerken yanıp söner ve küçük bir halka gösterir.
struct FaceIDSidebarLabel: View {
    var body: some View {
        let models = FaceModels.shared
        Label {
            HStack {
                Text(Page.faceID.title)
                if models.isBusy {
                    Spacer()
                    DownloadRing(progress: models.progress, installing: models.state == .installing, lineWidth: 2)
                        .frame(width: 14, height: 14)
                }
            }
        } icon: {
            Image(systemName: "faceid")
                .foregroundStyle(models.isBusy ? AnyShapeStyle(.green) : AnyShapeStyle(.primary))
                .symbolEffect(.pulse, options: .repeating, isActive: models.isBusy)
        }
    }
}

/// Mac şifresini sorar, doğrular ve Anahtar Zinciri'ne kaydeder.
private struct PasswordSheet: View {
    let done: () -> Void
    @State private var password = ""
    @State private var wrong = false
    @State private var checking = false

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "lock.shield.fill").font(.system(size: 40)).foregroundStyle(.green.gradient)
            Text(L("Mac şifreni gir")).font(.title3.weight(.semibold))
            Text(L("Yüzün tanınınca Tuno bu şifreyi kilit ekranına senin yerine yazar. Şifre yalnızca bu Mac'in Anahtar Zinciri'nde saklanır."))
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            SecureField(L("Şifre"), text: $password)
                .textFieldStyle(.roundedBorder)
                .frame(width: 260)
                .onSubmit(save)
            if wrong {
                Text(L("Şifre yanlış.")).font(.caption).foregroundStyle(.red)
            }
            HStack {
                Button(L("Vazgeç"), role: .cancel, action: done).keyboardShortcut(.cancelAction)
                Button(L("Kaydet"), action: save)
                    .keyboardShortcut(.defaultAction)
                    .disabled(password.isEmpty || checking)
            }
        }
        .padding(28)
        .frame(width: 400)
    }

    private func save() {
        guard !password.isEmpty else { return }
        checking = true
        let unlock = FaceID.shared.unlock
        if unlock.setPassword(password) {
            unlock.isEnabled = true
            password = ""
            done()
        } else {
            wrong = true
            password = ""
        }
        checking = false
    }
}

/// Küçük "Beta" etiketi.
struct BetaBadge: View {
    var body: some View {
        Text("BETA")
            .font(.system(size: 9, weight: .heavy))
            .tracking(0.5)
            .padding(.horizontal, 6)
            .padding(.vertical, 2.5)
            .foregroundStyle(.orange)
            .background(Capsule().fill(Color.orange.opacity(0.16)))
    }
}

/// Bir yüzün son tanıma denemeleri: ne zaman, sonuç, benzerlik ve canlılık.
private struct HistorySheet: View {
    let face: EnrolledFace
    let done: () -> Void

    private var attempts: [FaceAttempt] { (face.history ?? []).reversed() }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(face.name).font(.title3.weight(.semibold))
                    Text(L("Benzerlik geçmişi")).font(.subheadline).foregroundStyle(.secondary)
                }
                Spacer()
                if let average = average {
                    VStack(alignment: .trailing, spacing: 2) {
                        Text("%\(Int((average * 100).rounded()))").font(.title2.weight(.semibold).monospacedDigit())
                        Text(L("Ortalama benzerlik")).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            if attempts.isEmpty {
                Text(L("Henüz deneme yok. Kilit ekranında ya da gizli öğeleri açarken yapılan taramalar burada görünür."))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 120)
                    .multilineTextAlignment(.center)
            } else {
                Table(attempts) {
                    TableColumn(L("Zaman")) { attempt in
                        Text(attempt.date.formatted(date: .abbreviated, time: .shortened))
                    }
                    .width(min: 140)
                    TableColumn(L("Sonuç")) { attempt in
                        Label(title(attempt.outcome), systemImage: symbol(attempt.outcome))
                            .foregroundStyle(attempt.outcome == .failed ? Color.red : Color.green)
                    }
                    .width(min: 120)
                    TableColumn(L("Benzerlik")) { attempt in
                        Text("%\(Int((attempt.score * 100).rounded()))").monospacedDigit()
                    }
                    .width(70)
                    TableColumn(L("Canlılık")) { attempt in
                        Text("%\(Int((attempt.liveness * 100).rounded()))").monospacedDigit()
                    }
                    .width(70)
                }
                .frame(minHeight: 260)
            }
            Text(String(format: L("Kilit açmak için en az %%%d benzerlik ve %%%d canlılık gerekir."),
                        Int(FaceID.unlockThreshold * 100), Int(FaceID.livenessThreshold * 100)))
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button(L("Tamam"), action: done).keyboardShortcut(.defaultAction)
            }
        }
        .padding(22)
        .frame(width: 560)
    }

    private var average: Float? {
        let scores = attempts.filter { $0.outcome != .failed }.map(\.score)
        return scores.isEmpty ? nil : scores.reduce(0, +) / Float(scores.count)
    }

    private func title(_ outcome: FaceAttempt.Outcome) -> String {
        switch outcome {
        case .unlocked: L("Kilit açıldı")
        case .verified: L("Gizli öğeler açıldı")
        case .failed: L("Tanınmadı")
        }
    }

    private func symbol(_ outcome: FaceAttempt.Outcome) -> String {
        switch outcome {
        case .unlocked: "lock.open.fill"
        case .verified: "eye.fill"
        case .failed: "xmark.circle.fill"
        }
    }
}
