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
        GroupBox("Segments") {
            if viewModel.records.isEmpty {
                Text("No segments yet")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                    .padding()
            } else {
                List(viewModel.records) { record in
                    VStack(alignment: .leading, spacing: 4) {
                        Text("[\(format(record.startSeconds)) - \(format(record.endSeconds))] \(record.segmentID)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(record.sourceText)
                            .font(.body)
                        Text(record.translatedText)
                            .font(.body)
                            .foregroundStyle(.blue)
                    }
                    .padding(.vertical, 4)
                }
            }
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 4) {
            ProgressView(value: viewModel.downloadProgress)
                .progressViewStyle(.linear)
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
}
