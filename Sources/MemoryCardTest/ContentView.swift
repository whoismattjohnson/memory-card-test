import SwiftUI

struct ContentView: View {
    @StateObject private var model = TesterModel()

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            header
            volumePicker
            modePicker
            actionRow
            if model.isRunning { progressSection }
            if let r = model.result { ResultCard(result: r) }
            Spacer(minLength: 0)
            footer
        }
        .padding(24)
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "sdcard")
                .font(.system(size: 34))
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 2) {
                Text("Memory Card Test").font(.title.bold())
                Text("Test your memory card speed and capacity, while detecting fakes.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: Volume picker

    private var volumePicker: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Card / volume").font(.headline)
                Spacer()
                Toggle("Show all volumes", isOn: $model.includeAllVolumes)
                    .toggleStyle(.checkbox)
                    .onChange(of: model.includeAllVolumes) { _ in model.rescan() }
                Button {
                    model.rescan()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .help("Rescan connected volumes")
            }

            if model.volumes.isEmpty {
                Text("No removable cards found. Insert a card, or enable “Show all volumes”.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.08)))
            } else {
                Picker("", selection: $model.selectedVolumeID) {
                    ForEach(model.volumes) { v in
                        Text("\(v.displayName) — \(v.totalString) (\(v.freeString) free)")
                            .tag(Optional(v.id))
                    }
                }
                .labelsHidden()
                .disabled(model.isRunning)

                if let v = model.selectedVolume, v.isInternal {
                    Label("This looks like an internal disk. Double-check before testing.",
                          systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
        }
    }

    // MARK: Mode

    private var modePicker: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Test type").font(.headline)
            Picker("", selection: $model.mode) {
                Text("Quick speed test").tag(CardTester.Mode.quick)
                Text("Full capacity test").tag(CardTester.Mode.full)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .disabled(model.isRunning)

            Text(modeDescription)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var modeDescription: String {
        switch model.mode {
        case .quick:
            return "Writes and verifies up to ~512 MB. Good for a quick read/write speed benchmark plus a basic integrity check."
        case .full:
            return "Fills essentially all free space, then reads every byte back. Slow (can take hours on a big card) but the most reliable way to confirm real capacity and catch fakes."
        }
    }

    // MARK: Actions

    private var actionRow: some View {
        HStack {
            if model.isRunning {
                Button(role: .cancel) { model.cancel() } label: {
                    Label("Stop", systemImage: "stop.fill").frame(maxWidth: .infinity)
                }
                .controlSize(.large)
                .keyboardShortcut(".", modifiers: .command)
            } else {
                Button { model.start() } label: {
                    Label("Start test", systemImage: "play.fill").frame(maxWidth: .infinity)
                }
                .controlSize(.large)
                .buttonStyle(.borderedProminent)
                .disabled(model.selectedVolume == nil)
            }
        }
    }

    // MARK: Progress

    private var progressSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            ProgressView(value: model.fractionComplete)
            HStack {
                Text(model.phaseText).font(.callout.weight(.medium))
                Spacer()
                if model.currentMBps > 0 {
                    Text(String(format: "%.0f MB/s", model.currentMBps))
                        .font(.callout.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            if model.totalBytes > 0 {
                Text("\(byteStr(model.processedBytes)) of \(byteStr(model.totalBytes))")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.secondary.opacity(0.08)))
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Test data is written to a temporary folder on the card and deleted automatically when the test finishes or is stopped. Keep the card connected until it completes.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 0) {
                Text("Created by Matt Johnson, ")
                Link(destination: URL(string: "https://whoismatt.com")!) {
                    Text("whoismatt.com")
                        .italic()
                        .underline()
                }
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .center)
        }
    }

    private func byteStr(_ n: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: n, countStyle: .file)
    }
}

// MARK: - Result card

struct ResultCard: View {
    let result: CardTester.Result

    private var accent: Color {
        if !result.succeeded { return .secondary }
        return result.isGenuine ? .green : .red
    }

    private var verdict: String {
        if !result.succeeded { return "Test did not complete" }
        return result.isGenuine ? "Card looks genuine" : "Warning: possible fake or failing card"
    }

    private var verdictIcon: String {
        if !result.succeeded { return "info.circle.fill" }
        return result.isGenuine ? "checkmark.seal.fill" : "exclamationmark.triangle.fill"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: verdictIcon).font(.title2).foregroundStyle(accent)
                Text(verdict).font(.title3.bold()).foregroundStyle(accent)
            }

            if result.succeeded {
                HStack(spacing: 24) {
                    stat("Write speed", String(format: "%.0f MB/s", result.writeMBps))
                    stat("Read speed", String(format: "%.0f MB/s", result.readMBps))
                    stat("Verified", byteStr(result.bytesWritten))
                }
            }

            Text(result.message)
                .font(.callout)
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12).fill(accent.opacity(0.10)))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(accent.opacity(0.35), lineWidth: 1))
    }

    private func stat(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.title3.monospacedDigit().weight(.semibold))
        }
    }

    private func byteStr(_ n: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: n, countStyle: .file)
    }
}
