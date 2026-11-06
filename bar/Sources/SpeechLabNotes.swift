import AVFoundation
import AppKit
import SwiftUI

struct SpeechLabNoteRecord: Codable {
    let trial: SpeechLabTrial
    let originalFile: String
    let asrFile: String
}

struct SpeechLabSavedNote: Identifiable {
    let record: SpeechLabNoteRecord
    let directory: URL
    var id: String { record.trial.id }
}

enum SpeechLabNoteFiles {
    static func save(trial: SpeechLabTrial, original: Data, asr: Data,
                     originalExtension: String, root: URL) throws {
        guard trial.id.hasPrefix("speech-lab-"),
              trial.id.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" }) else {
            throw CocoaError(.fileWriteInvalidFileName)
        }
        let ext = ["caf", "wav", "aiff", "aif", "m4a"].contains(originalExtension)
            ? originalExtension : "audio"
        let directory = root.appendingPathComponent(trial.id, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let record = SpeechLabNoteRecord(trial: trial, originalFile: "original.\(ext)", asrFile: "asr.wav")
        for (file, data) in [(record.originalFile, original), (record.asrFile, asr)] {
            let url = directory.appendingPathComponent(file)
            if !FileManager.default.fileExists(atPath: url.path) { try data.write(to: url, options: .atomic) }
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(record).write(to: directory.appendingPathComponent("note.json"), options: .atomic)
    }

    static func load(from root: URL) -> [SpeechLabSavedNote] {
        let directories = (try? FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
        return directories.compactMap { directory -> SpeechLabSavedNote? in
            guard let data = try? Data(contentsOf: directory.appendingPathComponent("note.json")),
                  let record = try? JSONDecoder().decode(SpeechLabNoteRecord.self, from: data),
                  record.trial.id == directory.lastPathComponent,
                  !record.originalFile.contains("/"), !record.asrFile.contains("/"),
                  FileManager.default.fileExists(atPath: directory.appendingPathComponent(record.originalFile).path)
            else { return nil }
            return SpeechLabSavedNote(record: record, directory: directory)
        }.sorted { $0.record.trial.date > $1.record.trial.date }
    }
}

enum VoiceNote: Identifiable {
    case lab(SpeechLabSavedNote)
    case dictation(NativeHistoryItem)

    var id: String {
        switch self {
        case .lab(let note): return "lab:\(note.id)"
        case .dictation(let item): return "dictation:\(item.id)"
        }
    }
    var date: Date {
        switch self { case .lab(let n): return n.record.trial.date; case .dictation(let i): return i.date }
    }
    var raw: String {
        switch self { case .lab(let n): return n.record.trial.heard; case .dictation(let i): return i.metadata.rawTranscript }
    }
    var wrote: String {
        switch self { case .lab(let n): return n.record.trial.wrote; case .dictation(let i): return i.metadata.finalTranscript }
    }
    var title: String {
        let text = wrote.isEmpty ? raw : wrote
        return text.isEmpty ? "Speech Lab recording" : String(text.prefix(90))
    }
    var source: String {
        switch self { case .lab(let n): return "Speech Lab · \(n.record.trial.condition)"; case .dictation: return "Dictation" }
    }
    var audioURL: URL {
        switch self {
        case .lab(let n): return n.directory.appendingPathComponent(n.record.originalFile)
        case .dictation(let i): return i.directoryURL.appendingPathComponent(i.metadata.audioFile)
        }
    }
    var asrURL: URL? {
        switch self { case .lab(let n): return n.directory.appendingPathComponent(n.record.asrFile); case .dictation: return nil }
    }
}

@MainActor
final class VoiceNotePlayer: ObservableObject {
    @Published private(set) var playing = false
    @Published private(set) var error: String?
    private var player: AVAudioPlayer?
    private var monitor: Task<Void, Never>?

    func toggle(_ url: URL) {
        if player?.url == url, playing { stop(); return }
        stop()
        do {
            let player = try AVAudioPlayer(contentsOf: url)
            guard player.prepareToPlay(), player.play() else { throw CocoaError(.fileReadCorruptFile) }
            self.player = player
            playing = true
            error = nil
            monitor = Task { [weak self] in
                while !Task.isCancelled, self?.player?.isPlaying == true {
                    try? await Task.sleep(for: .milliseconds(100))
                }
                if !Task.isCancelled { self?.playing = false }
            }
        } catch { self.error = error.localizedDescription }
    }

    func stop() { monitor?.cancel(); monitor = nil; player?.stop(); player = nil; playing = false }
}

struct VoiceNoteDetail: View {
    let note: VoiceNote
    let onDelete: () -> Void
    @StateObject private var player = VoiceNotePlayer()
    @State private var confirmDelete = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text(note.title).font(.system(size: 21, weight: .semibold))
                Text("\(note.source) · \(note.date.formatted(date: .abbreviated, time: .shortened))")
                    .font(.callout).foregroundStyle(EmberTheme.soft)
                HStack {
                    Button("Play original", systemImage: "play.fill") { player.toggle(note.audioURL) }
                    if let asr = note.asrURL {
                        Button("Play ASR input") { player.toggle(asr) }
                    }
                    if player.playing { Button("Stop") { player.stop() } }
                }
                if let error = player.error { Text(error).foregroundStyle(EmberTheme.warm) }
                textBlock("PARAKEET HEARD", note.raw)
                textBlock("\(AppBrand.name.uppercased()) WROTE", note.wrote)
                if case .lab(let saved) = note {
                    let trial = saved.record.trial
                    Text(String(format: "%@ · source %.1f kHz · gain +%.0f dB · %d clipped samples",
                                trial.microphone ?? "Imported audio", trial.signal.sourceSampleRate / 1000,
                                trial.signal.gainDB, trial.signal.clippedSamples))
                        .font(.caption).foregroundStyle(EmberTheme.soft)
                    if let failure = trial.failure { Text(failure).foregroundStyle(EmberTheme.warm) }
                    textBlock("REFERENCE", trial.reference)
                }
                HStack {
                    Button("Show files in Finder") { NSWorkspace.shared.activateFileViewerSelecting([note.audioURL]) }
                    Spacer()
                    Button("Move to Trash", role: .destructive) { confirmDelete = true }
                }
                Text("Saved on this Mac. Original audio and the exact ASR input are separate so capture and recognition can be checked independently.")
                    .font(.caption).foregroundStyle(EmberTheme.muted)
            }
            .padding(24)
        }
        .buttonStyle(PillButtonStyle())
        .confirmationDialog("Move this recording and its transcripts to Trash?", isPresented: $confirmDelete) {
            Button("Move to Trash", role: .destructive) { player.stop(); onDelete() }
        }
        .onDisappear { player.stop() }
    }

    private func textBlock(_ title: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.caption.weight(.semibold)).foregroundStyle(EmberTheme.ember2)
            Text(text.isEmpty ? "No transcript yet." : text).textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(12).background(EmberTheme.side, in: RoundedRectangle(cornerRadius: 10))
    }
}
