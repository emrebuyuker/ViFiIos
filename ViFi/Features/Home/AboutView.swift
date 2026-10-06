import SwiftUI

/// App information: logo, version, what ViFi offers and where its data comes from.
struct AboutView: View {
    var bundle: Bundle = .main

    @Environment(\.dismiss) private var dismiss
    @ScaledMetric(relativeTo: .largeTitle) private var logoSize: CGFloat = 84

    var body: some View {
        NavigationStack {
            List {
                identitySection

                Section {
                    Text("""
                        ViFi, üniversitelerin geçmiş sınavlarını tek bir arşivde toplar. \
                        Üniversiteni, fakülteni, bölümünü ve dersini seç; sınavları görsel ya da PDF olarak incele ve paylaş.
                        """)
                    .fixedSize(horizontal: false, vertical: true)
                }

                Section("Öne Çıkanlar") {
                    Label("Görsel ve PDF sınavlar tek yerde", systemImage: "doc.richtext")
                    Label("Yakınlaştırarak ayrıntılı inceleme", systemImage: "plus.magnifyingglass")
                    Label("Son görüntülenen sınavlara hızlı erişim", systemImage: "clock.arrow.circlepath")
                    Label("Sınavları kolayca paylaşma", systemImage: "square.and.arrow.up")
                }

                Section("Veri Kaynağı") {
                    Label {
                        Text("""
                            Sınav belgeleri ViFi'nin çevrim içi arşivinden yüklenir; görüntülemek için internet bağlantısı gerekir. \
                            Açtığın sınavlar daha hızlı açılması için cihazında önbelleğe alınır.
                            """)
                        .fixedSize(horizontal: false, vertical: true)
                    } icon: {
                        Image(systemName: "icloud")
                    }
                }
            }
            .accessibilityIdentifier("about.sheet")
            .navigationTitle("Hakkında")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Bitti") {
                        dismiss()
                    }
                    .accessibilityIdentifier("about.done")
                }
            }
        }
    }

    private var identitySection: some View {
        Section {
            VStack(spacing: 10) {
                Image("Logo")
                    .resizable()
                    .scaledToFit()
                    .frame(width: min(logoSize, 120), height: min(logoSize, 120))
                    .clipShape(.rect(cornerRadius: min(logoSize, 120) * 0.225, style: .continuous))
                    .shadow(color: .black.opacity(0.12), radius: 10, y: 4)
                    .accessibilityHidden(true)
                    .padding(.bottom, 4)

                Text(verbatim: "ViFi")
                    .font(.largeTitle.bold())

                Text("Sınav Arşivi")
                    .font(.headline)
                    .foregroundStyle(.secondary)

                Text("Sürüm \(bundle.marketingVersion) (\(bundle.buildNumber))")
                    .font(.footnote.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(Color(.tertiarySystemFill), in: .capsule)
                    .accessibilityIdentifier("about.version")
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .accessibilityElement(children: .combine)
            .listRowBackground(Color.clear)
        }
    }
}

private extension Bundle {
    /// `CFBundleShortVersionString`, e.g. "3.0.0".
    var marketingVersion: String {
        object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "–"
    }

    /// `CFBundleVersion`, e.g. "6".
    var buildNumber: String {
        object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "–"
    }
}

#if DEBUG
#Preview("Hakkında") {
    AboutView()
        .environment(AppEnvironment.mock())
        .environment(Router())
}
#endif
