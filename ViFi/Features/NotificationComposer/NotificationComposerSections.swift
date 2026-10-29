import SwiftUI

// The composer form, split into small sections so each stays readable. They all edit the same view model.

// MARK: - Kind

/// Duyuru / Kampanya, with the one thing an admin must know about campaigns. While the action is Konum the control
/// is locked on Kampanya (a place is always advertising) and says why; the admin's own choice returns afterwards.
struct NotificationComposerKindSection: View {
    @Bindable var viewModel: NotificationComposerViewModel

    var body: some View {
        Section {
            Picker("Tür", selection: $viewModel.kindSelection) {
                ForEach(NotificationComposerViewModel.selectableKinds, id: \.self) { kind in
                    Text(kind.adminLabel).tag(kind)
                }
            }
            .pickerStyle(.segmented)
            .disabled(viewModel.isWorking || viewModel.isKindLocked)
            .accessibilityIdentifier("notificationComposer.kind")
        } footer: {
            if viewModel.isKindLocked {
                Label("Tür Kampanya'ya kilitli: konumlu bildirimler her zaman kampanya olarak gider.", systemImage: "lock.fill")
                    .accessibilityIdentifier("notificationComposer.kind.lockNote")
            } else {
                Text("Kampanyalar yalnızca kampanya bildirimlerini açmış kullanıcılara gider.")
            }
        }
    }
}

// MARK: - Content

/// Title and message, each with a live counter against its limit.
struct NotificationComposerContentSection: View {
    @Bindable var viewModel: NotificationComposerViewModel

    var body: some View {
        Section("İçerik") {
            VStack(alignment: .leading, spacing: 4) {
                TextField("Başlık", text: $viewModel.title)
                    .submitLabel(.next)
                    .accessibilityIdentifier("notificationComposer.title")
                CharacterCounter(
                    count: viewModel.titleLength,
                    limit: NotificationDraft.titleLimit,
                    identifier: "notificationComposer.titleCounter"
                )
            }
            VStack(alignment: .leading, spacing: 4) {
                TextField("Mesaj", text: $viewModel.body, axis: .vertical)
                    .lineLimit(3...8)
                    .accessibilityIdentifier("notificationComposer.body")
                CharacterCounter(
                    count: viewModel.bodyLength,
                    limit: NotificationDraft.bodyLimit,
                    identifier: "notificationComposer.bodyCounter"
                )
            }
        }
        .disabled(viewModel.isWorking)
    }
}

/// "12/80", red once over the limit.
private struct CharacterCounter: View {
    let count: Int
    let limit: Int
    let identifier: String

    var body: some View {
        Text("\(count)/\(limit)")
            .font(.caption.monospacedDigit())
            .foregroundStyle(count > limit ? Color.red : Color.secondary)
            .frame(maxWidth: .infinity, alignment: .trailing)
            .accessibilityLabel("\(count) / \(limit) karakter")
            .accessibilityIdentifier(identifier)
    }
}

// MARK: - Audience

/// Everyone, or a segment picked through cascading university → faculty → department lists that show only what
/// registered users actually have, plus a gender filter and the live reach estimate.
struct NotificationComposerAudienceSection: View {
    @Bindable var viewModel: NotificationComposerViewModel

    var body: some View {
        Section {
            Picker("Kitle", selection: $viewModel.audienceMode) {
                Text("Hepsi").tag(NotificationComposerViewModel.AudienceMode.everyone)
                Text("Belirli kitle").tag(NotificationComposerViewModel.AudienceMode.segment)
            }
            .pickerStyle(.segmented)
            .accessibilityIdentifier("notificationComposer.audience")

            facetsStatus
            if viewModel.audienceMode == .segment, case .loaded = viewModel.facets {
                segmentPickers
            }
            estimateRow
        } header: {
            Text("Hedef kitle")
        } footer: {
            footer
        }
        .disabled(viewModel.isWorking)
        .animation(.smooth, value: viewModel.audienceMode)
        .animation(.smooth, value: viewModel.universityId)
    }

    @ViewBuilder
    private var facetsStatus: some View {
        switch viewModel.facets {
        case .loading:
            HStack(spacing: 8) {
                ProgressView()
                Text("Kitle bilgisi yükleniyor…")
                    .foregroundStyle(.secondary)
            }
        case let .failed(message):
            VStack(alignment: .leading, spacing: 8) {
                Label(message, systemImage: "exclamationmark.circle.fill")
                    .foregroundStyle(.red)
                Button("Tekrar dene") { Task { await viewModel.reloadFacets() } }
                    .accessibilityIdentifier("notificationComposer.audienceRetry")
            }
        case .loaded:
            EmptyView()
        }
    }

    @ViewBuilder
    private var segmentPickers: some View {
        Picker("Üniversite", selection: Binding(get: { viewModel.universityId }, set: { viewModel.selectUniversity($0) })) {
            Text("Seç").tag(String?.none)
            nodeOptions(viewModel.universities)
        }
        .accessibilityIdentifier("notificationComposer.university")

        Picker("Fakülte", selection: Binding(get: { viewModel.facultyId }, set: { viewModel.selectFaculty($0) })) {
            Text("Tüm fakülteler").tag(String?.none)
            nodeOptions(viewModel.faculties)
        }
        .disabled(viewModel.universityId == nil)
        .accessibilityIdentifier("notificationComposer.faculty")

        Picker("Bölüm", selection: Binding(get: { viewModel.departmentId }, set: { viewModel.selectDepartment($0) })) {
            Text("Tüm bölümler").tag(String?.none)
            nodeOptions(viewModel.departments)
        }
        .disabled(viewModel.facultyId == nil)
        .accessibilityIdentifier("notificationComposer.department")

        Picker("Cinsiyet", selection: $viewModel.gender) {
            Text("Hepsi").tag(Gender?.none)
            ForEach(Gender.allCases) { gender in
                Text(gender.label).tag(Gender?.some(gender))
            }
        }
        .pickerStyle(.segmented)
        .accessibilityIdentifier("notificationComposer.gender")
    }

    /// One option per node, with how many users it reaches.
    @ViewBuilder
    private func nodeOptions(_ nodes: [AudienceNode]) -> some View {
        ForEach(nodes) { node in
            Text("\(node.name) · \(node.counts.total) kişi").tag(String?.some(node.id))
        }
    }

    @ViewBuilder
    private var estimateRow: some View {
        if let estimate = viewModel.estimatedRecipients {
            LabeledContent("Tahmini kitle") {
                Text("≈ \(estimate) kişi")
                    .font(.body.monospacedDigit())
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("notificationComposer.estimate")
        }
    }

    @ViewBuilder
    private var footer: some View {
        if viewModel.audienceMode == .segment, viewModel.universityId == nil, case .loaded = viewModel.facets {
            Text("Önce bir üniversite seç. Listelerde yalnızca kayıtlı kullanıcısı olanlar görünür.")
        } else if viewModel.draft.effectiveKind == .promo {
            Text("Kampanyada yalnızca bildirim onayı verenler alır; kesin sayıyı göndermeden önce göreceksin.")
        }
    }
}

// MARK: - Action

/// The button on the notification's card: nothing, Premium, Sınav Ekle, an https link, an exam from the archive
/// or a place on the map.
struct NotificationComposerActionSection: View {
    @Bindable var viewModel: NotificationComposerViewModel

    var body: some View {
        Section {
            Picker("Buton", selection: $viewModel.actionChoice) {
                Text("Yok").tag(NotificationComposerViewModel.ActionChoice.noAction)
                Text("Premium").tag(NotificationComposerViewModel.ActionChoice.paywall)
                Text("Sınav Ekle").tag(NotificationComposerViewModel.ActionChoice.addExam)
                Text("Bağlantı").tag(NotificationComposerViewModel.ActionChoice.url)
                Text("Sınav").tag(NotificationComposerViewModel.ActionChoice.exam)
                Text("Konum").tag(NotificationComposerViewModel.ActionChoice.location)
            }
            .accessibilityIdentifier("notificationComposer.action")

            if viewModel.actionChoice == .url {
                TextField("https://", text: $viewModel.urlText)
                    .keyboardType(.URL)
                    .textContentType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .accessibilityIdentifier("notificationComposer.url")
            }
            if viewModel.actionChoice == .exam {
                NotificationComposerExamRow(viewModel: viewModel)
            }

            if viewModel.actionChoice == .location {
                NotificationComposerLocationRows(viewModel: viewModel)
            }
        } header: {
            Text("Eylem")
        } footer: {
            Text("Karta dokunulduğunda ya da butona basıldığında açılır. Bağlantı https ile başlamalı.")
        }
        .disabled(viewModel.isWorking)
        .animation(.smooth, value: viewModel.actionChoice)
    }
}

// MARK: - Timing

/// An optional later delivery time and an optional validity period.
struct NotificationComposerTimingSection: View {
    @Bindable var viewModel: NotificationComposerViewModel

    var body: some View {
        Section {
            Toggle("İleri tarihte gönder", isOn: Binding(
                get: { viewModel.scheduledAt != nil },
                set: { viewModel.setScheduling($0) }
            ))
            .accessibilityIdentifier("notificationComposer.scheduleToggle")
            if let scheduledAt = viewModel.scheduledAt {
                DatePicker(
                    "Gönderim zamanı",
                    selection: Binding(get: { viewModel.scheduledAt ?? scheduledAt }, set: { viewModel.scheduledAt = $0 }),
                    in: Date.now...,
                    displayedComponents: [.date, .hourAndMinute]
                )
                .accessibilityIdentifier("notificationComposer.scheduledAt")
            }

            Toggle("Geçerlilik süresi", isOn: Binding(
                get: { viewModel.expiresAt != nil },
                set: { viewModel.setExpiry($0) }
            ))
            .accessibilityIdentifier("notificationComposer.expiryToggle")
            if let expiresAt = viewModel.expiresAt {
                DatePicker(
                    "Bitiş zamanı",
                    selection: Binding(get: { viewModel.expiresAt ?? expiresAt }, set: { viewModel.expiresAt = $0 }),
                    in: (viewModel.scheduledAt ?? .now)...,
                    displayedComponents: [.date, .hourAndMinute]
                )
                .accessibilityIdentifier("notificationComposer.expiresAt")
            }
        } header: {
            Text("Zamanlama")
        } footer: {
            Text("Süresi dolan bildirim, kullanıcıların bildirim sayfasından kalkar.")
        }
        .disabled(viewModel.isWorking)
        .animation(.smooth, value: viewModel.scheduledAt != nil)
        .animation(.smooth, value: viewModel.expiresAt != nil)
    }
}

// MARK: - Feedback and send

/// What the admin needs to know right now: what blocks sending, what failed, what went through.
struct NotificationComposerFeedbackSection: View {
    let viewModel: NotificationComposerViewModel

    var body: some View {
        if viewModel.visibleIssue != nil || viewModel.errorMessage != nil || viewModel.successMessage != nil {
            Section {
                if let message = viewModel.errorMessage {
                    Label(message, systemImage: "exclamationmark.circle.fill")
                        .foregroundStyle(.red)
                        .accessibilityIdentifier("notificationComposer.error")
                }
                if let message = viewModel.successMessage {
                    Label(message, systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .accessibilityIdentifier("notificationComposer.success")
                }
                if let issue = viewModel.visibleIssue {
                    Label(issue.message, systemImage: "info.circle")
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("notificationComposer.issue")
                }
            }
        }
    }
}

/// "Gönder" (previews the reach first) and "Bana test gönder" (to the admin's own device only).
struct NotificationComposerSendSection: View {
    let viewModel: NotificationComposerViewModel

    var body: some View {
        Section {
            Button {
                Task { await viewModel.requestSend() }
            } label: {
                HStack(spacing: 8) {
                    if viewModel.isWorking {
                        ProgressView()
                    }
                    // Black on the brand orange: white text would fall below 3:1 contrast.
                    Text("Gönder")
                        .fontWeight(.semibold)
                        .foregroundStyle(.black)
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(!viewModel.canSend)
            .listRowBackground(Color.clear)
            .accessibilityIdentifier("notificationComposer.send")

            Button("Bana test gönder", systemImage: "iphone.gen3.radiowaves.left.and.right") {
                Task { await viewModel.sendTest() }
            }
            .disabled(!viewModel.canSendTest)
            .accessibilityIdentifier("notificationComposer.testSend")
        } footer: {
            Text("Test yalnızca senin cihazına gider; kitleye ulaşmaz.")
        }
    }
}
