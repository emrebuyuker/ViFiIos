import SwiftUI

// Small shared pieces of the admin conversion screens: the provider picker (K9: Claude or Gemini at every AI
// action, never a default), the monthly spend gauge and the job status text.

extension View {
    /// Asks which AI provider to use ("Claude ile ilerle" / "Gemini ile ilerle") before an action that runs a
    /// model, then calls `perform` with the choice. There is no default and no "remember my choice".
    func aiProviderDialog(
        _ title: LocalizedStringKey,
        isPresented: Binding<Bool>,
        perform: @escaping (AIProvider) -> Void
    ) -> some View {
        confirmationDialog(title, isPresented: isPresented, titleVisibility: .visible) {
            ForEach(AIProvider.allCases, id: \.self) { provider in
                Button("\(provider.displayName) ile ilerle") { perform(provider) }
                    .accessibilityIdentifier("ai.provider.\(provider.rawValue)")
            }
            Button("Vazgeç", role: .cancel) {}
        }
    }
}

/// Two side-by-side buttons for picking a provider inline (nothing is selected at first).
struct AIProviderChoice: View {
    @Binding var selection: AIProvider?

    var body: some View {
        HStack(spacing: 10) {
            ForEach(AIProvider.allCases, id: \.self) { provider in
                Button {
                    selection = provider
                } label: {
                    HStack {
                        Image(systemName: selection == provider ? "checkmark.circle.fill" : "circle")
                        Text(provider.displayName)
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .tint(selection == provider ? .accentColor : .secondary)
                .accessibilityAddTraits(selection == provider ? .isSelected : [])
                .accessibilityIdentifier("bulk.provider.\(provider.rawValue)")
            }
        }
    }
}

/// This month's AI spend against the $50 cap.
struct AIUsageGauge: View {
    let usage: AIMonthlyUsage?

    var body: some View {
        if let usage {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Bu ayın yapay zekâ harcaması")
                    Spacer()
                    Text("\(usage.costUsd.usd) / \(AIMonthlyUsage.capUsd.usd)")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                .font(.subheadline)
                ProgressView(value: usage.fraction)
                    .tint(usage.fraction >= 0.9 ? .red : .accentColor)
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("ai.usage")
        }
    }
}

extension Double {
    /// `$0.42` — the cost as US dollars.
    var usd: String {
        formatted(.currency(code: "USD").precision(.fractionLength(2)))
    }
}

extension ExamConversion {
    /// The exam's place and name for a list row, e.g. "2023 VİZE".
    var examTitle: String {
        placementNames.last ?? id
    }

    /// "Üniversite › Fakülte › Bölüm › Ders", without the exam itself.
    var placementPath: String {
        placementNames.dropLast().joined(separator: " › ")
    }

    /// "Claude · $0.42", "Gemini", or empty when nothing is known yet.
    var providerAndCost: String {
        [provider?.displayName, usage?.costUsd.usd].compactMap { $0 }.joined(separator: " · ")
    }
}
