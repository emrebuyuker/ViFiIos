import SwiftUI

/// The exam's title on the second approval (owner decision K28): the original title for reference and the list title
/// it is published with — year (4 digits or none) + one of the exam-name list's names + an optional sequence number.
/// Pre-filled from the server's suggestion; without one the admin has to pick a name before "Yayınla" is enabled.
struct ConversionTitleSection: View {
    @Bindable var viewModel: ConversionReviewViewModel

    var body: some View {
        Section {
            if let original = viewModel.job.originalTitle ?? viewModel.job.placementNames.last {
                LabeledContent("Orijinal ad", value: original)
                    .accessibilityIdentifier("conversion.review.title.original")
            }
            Picker("Ad", selection: $viewModel.titleEntryId) {
                Text("Seç").tag(String?.none)
                ForEach(ExamNameCatalog.entries, id: \.id) { entry in
                    Text(entry.name).tag(Optional(entry.id))
                }
            }
            .accessibilityIdentifier("conversion.review.title.name")
            TextField("Yıl (ör. 2019, boş bırakılabilir)", text: $viewModel.titleYear)
                .keyboardType(.numberPad)
                .accessibilityIdentifier("conversion.review.title.year")
            TextField("Sıra no (1–99, boş bırakılabilir)", text: $viewModel.titleNumber)
                .keyboardType(.numberPad)
                .accessibilityIdentifier("conversion.review.title.number")
            Text(viewModel.examTitle ?? viewModel.titleProblem ?? "")
                .font(.headline)
                .foregroundStyle(viewModel.examTitle == nil ? AnyShapeStyle(.orange) : AnyShapeStyle(.primary))
                .accessibilityLabel(viewModel.examTitle ?? viewModel.titleProblem ?? "")
                .accessibilityIdentifier("conversion.review.title")
        } header: {
            Text("Sınav adı")
        } footer: {
            Text("Yeni yapıya geçen sınavın adı listedeki adlardan biri olur: yıl + ad + sıra no.")
        }
    }
}
