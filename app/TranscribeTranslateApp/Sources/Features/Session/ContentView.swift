import SwiftUI

struct ContentView: View {
    @ObservedObject var viewModel: SessionViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            controls
            transcriptTable
            footer
        }
        .padding(20)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Realtime Transcript + Translation")
                .font(.title2.weight(.bold))
            Text("Model dir: \(viewModel.modelDirectory)")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text("Status: \(viewModel.statusMessage)")
                .font(.subheadline)
        }
    }

    private var controls: some View {
        HStack(spacing: 12) {
            Button("Download Models") {
                viewModel.prepareModels()
            }

            Button("Check Models") {
                viewModel.checkModels()
            }

            Button("Start Session") {
                viewModel.startSession()
            }

            Button("Stop") {
                viewModel.stopSession()
            }

            Button("Export .md") {
                viewModel.exportTranscript()
            }

            Button("Clear") {
                viewModel.resetRecords()
            }

            Spacer()

            TextField("Target lang (e.g. vie_Latn)", text: $viewModel.targetLanguage)
                .frame(width: 200)
        }
    }

    private var transcriptTable: some View {
        GroupBox("Transcript") {
            HStack(alignment: .top, spacing: 14) {
                transcriptColumn(
                    title: "English (source)",
                    accent: .primary,
                    liveDraftText: viewModel.livePartialText,
                    liveDraftWindow: viewModel.livePartialWindowLabel
                ) { record in
                    record.sourceText
                }

                transcriptColumn(
                    title: "Translated (\(viewModel.targetLanguage))",
                    accent: .blue,
                    liveDraftText: nil,
                    liveDraftWindow: nil
                ) { record in
                    record.translatedText
                }
            }
            .frame(maxWidth: .infinity, minHeight: 340, alignment: .topLeading)
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 4) {
            ProgressView(value: viewModel.downloadProgress)
                .progressViewStyle(.linear)
            Text(viewModel.downloadProgressLabel)
                .font(.caption)
                .foregroundStyle(.secondary)
            if let exported = viewModel.exportedFilePath {
                Text("Exported to: \(exported)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func format(_ seconds: Double) -> String {
        let total = max(Int(seconds), 0)
        return String(format: "%02d:%02d", total / 60, total % 60)
    }

    @ViewBuilder
    private func transcriptColumn(
        title: String,
        accent: Color,
        liveDraftText: String?,
        liveDraftWindow: String?,
        textProvider: @escaping (TranscriptRecord) -> String
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.headline)
                .foregroundStyle(accent)

            if let liveDraftText, !liveDraftText.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    Text(liveDraftWindow.map { "\($0) live draft" } ?? "Live draft")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(liveDraftText)
                        .font(.body)
                        .italic()
                        .foregroundStyle(.orange)
                }
                .padding(8)
                .background(Color.orange.opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }

            if viewModel.records.isEmpty {
                Text("No segments yet")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 250, alignment: .topLeading)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        ForEach(viewModel.records) { record in
                            VStack(alignment: .leading, spacing: 3) {
                                Text("[\(format(record.startSeconds)) - \(format(record.endSeconds))]")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Text(textProvider(record))
                                    .font(.body)
                                    .foregroundStyle(accent)
                                    .textSelection(.enabled)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, 2)
                        }
                    }
                }
                .frame(maxWidth: .infinity, minHeight: 250, alignment: .topLeading)
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }
}
