import AVFoundation
import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// A reference must be what was actually spoken. Rewrite error rate is deliberately
/// separate: a fluent LFM rewrite must not conceal recognition errors in a quiet clip.
enum SpeechLabMetrics {
    static func words(_ text: String) -> [String] {
        text.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
    }

    static func wordErrorRate(reference: String, hypothesis: String) -> Double? {
        let expected = words(reference), actual = words(hypothesis)
        guard !expected.isEmpty else { return nil }
        var previous = Array(0...actual.count)
        for (i, word) in expected.enumerated() {
            var row = [i + 1]
            for (j, candidate) in actual.enumerated() {
                row.append(min(row[j] + 1, previous[j + 1] + 1,
                               previous[j] + (word == candidate ? 0 : 1)))
            }
            previous = row
        }
        return Double(previous.last ?? expected.count) / Double(expected.count)
    }
}

struct SpeechLabSignal: Codable, Equatable {
    let seconds: Double
    let rmsDBFS: Double
    let peakDBFS: Double
    let gainDB: Double
    let clippedSamples: Int
}

enum SpeechLabAudio {
    static let maxSeconds = 30.0

    /// Decode at most 30 seconds, downmix and resample to mono PCM16 at 16 kHz.
    /// Fixed digital gain is an experiment, not denoising or silent-speech sensing.
    static func prepare(source: URL, destination: URL, gainDB: Double) throws -> SpeechLabSignal {
        let file = try AVAudioFile(forReading: source)
        let format = file.processingFormat
        guard file.length > 0, format.sampleRate > 0,
            Double(file.length) / format.sampleRate <= maxSeconds,
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(file.length))
        else { throw failure("Choose a recording between 0 and 30 seconds.") }
        try file.read(into: buffer)
        guard let channels = buffer.floatChannelData, buffer.frameLength > 0 else {
            throw failure("This audio format could not be decoded.")
        }
        let count = Int(buffer.frameLength), channelCount = Int(format.channelCount)
        let mono = (0..<count).map { index in
            (0..<channelCount).reduce(0.0) { $0 + Double(channels[$1][index]) }
                / Double(channelCount)
        }
        let outCount = max(1, Int(Double(count) * 16_000 / format.sampleRate))
        let samples = (0..<outCount).map { index -> Double in
            let position = Double(index) * format.sampleRate / 16_000
            let lower = min(Int(position), count - 1), upper = min(lower + 1, count - 1)
            return mono[lower] + (mono[upper] - mono[lower]) * (position - Double(lower))
        }
        guard samples.allSatisfy({ $0.isFinite }) else {
            throw failure("The audio contains invalid sample values.")
        }
        let rms = sqrt(samples.reduce(0) { $0 + $1 * $1 } / Double(samples.count))
        let peak = samples.map(abs).max() ?? 0
        let gain = pow(10, min(24, max(0, gainDB)) / 20)
        let amplified = samples.map { $0 * gain }
        let pcm: [Int16] = amplified.map { Int16((min(1, max(-1, $0)) * 32767).rounded()) }
        try wav(pcm).write(to: destination, options: .atomic)
        return SpeechLabSignal(
            seconds: Double(samples.count) / 16_000,
            rmsDBFS: 20 * log10(max(rms, 1e-9)), peakDBFS: 20 * log10(max(peak, 1e-9)),
            gainDB: min(24, max(0, gainDB)), clippedSamples: amplified.filter { abs($0) > 1 }.count)
    }

    static func wav(_ samples: [Int16]) -> Data {
        var data = Data()
        func text(_ value: String) { data.append(contentsOf: value.utf8) }
        func u16(_ value: UInt16) {
            var value = value.littleEndian
            withUnsafeBytes(of: &value) { data.append(contentsOf: $0) }
        }
        func u32(_ value: UInt32) {
            var value = value.littleEndian
            withUnsafeBytes(of: &value) { data.append(contentsOf: $0) }
        }
        text("RIFF"); u32(UInt32(36 + samples.count * 2)); text("WAVEfmt ")
        u32(16); u16(1); u16(1); u32(16_000); u32(32_000); u16(2); u16(16)
        text("data"); u32(UInt32(samples.count * 2))
        for sample in samples { u16(UInt16(bitPattern: sample)) }
        return data
    }

    private static func failure(_ message: String) -> NSError {
        NSError(domain: "SpeechLab", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}

struct SpeechLabTrial: Codable, Identifiable {
    let id: String
    let date: Date
    let condition: String
    let reference: String
    let signal: SpeechLabSignal
    var heard = ""
    var wrote = ""
    var asrMS = 0.0
    var refinerMS = 0.0
    var batchWallMS = 0.0

    var rawWER: Double? { SpeechLabMetrics.wordErrorRate(reference: reference, hypothesis: heard) }
    var rewriteWER: Double? { SpeechLabMetrics.wordErrorRate(reference: reference, hypothesis: wrote) }
}

struct SpeechLabExport: Encodable {
    let schemaVersion = 1
    let timing = "batch processing, excluding recording and OS text insertion"
    let silentSpeechSupported = false
    let trials: [Entry]

    struct Entry: Encodable {
        let trial: SpeechLabTrial
        let rawWordErrorRate: Double?
        let rewriteWordDifferenceRate: Double?
    }

    init(trials: [SpeechLabTrial]) {
        self.trials = trials.map {
            Entry(trial: $0, rawWordErrorRate: $0.rawWER, rewriteWordDifferenceRate: $0.rewriteWER)
        }
    }
}

@MainActor
final class SpeechLabController: ObservableObject {
    @Published var reference = "Please move the meeting to Thursday and send me the updated agenda."
    @Published var condition = "Normal speech"
    @Published var gainDB = 0.0
    @Published private(set) var isRecording = false
    @Published private(set) var isProcessing = false
    @Published private(set) var status = "Ready for a short microphone experiment."
    @Published private(set) var seconds = 0.0
    @Published private(set) var levelDBFS = -90.0
    @Published private(set) var trials: [SpeechLabTrial] = []
    @Published private(set) var current: SpeechLabTrial?
    var onCommand: (([String: Any]) -> Void)?
    var canBegin: (() -> Bool)?
    var isBusy: Bool { isRecording || isProcessing || permissionPending }
    private var permissionPending = false
    private var recorder: AVAudioRecorder?
    private var timer: Timer?
    private var timeout: Task<Void, Never>?
    private var captureURL: URL?
    private var preparedURL: URL?
    private var started: Date?
    private var requestID: String?
    private var selectedCondition = ""
    private var selectedReference = ""
    private var selectedGain = 0.0

    nonisolated static func owns(_ event: [String: Any]) -> Bool {
        (event["id"] as? String)?.hasPrefix("speech-lab-") == true
    }

    func toggleRecording() {
        if isRecording { finishRecording(); return }
        guard !isBusy, canBegin?() == true else {
            status = "Wait until the models and normal dictation are idle."
            return
        }
        // No capture or permission prompt occurs until the user presses Record.
        if AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined {
            permissionPending = true
            status = "Waiting for microphone permission…"
            AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
                Task { @MainActor in
                    guard let self else { return }
                    self.permissionPending = false
                    if granted { self.toggleRecording() }
                    else { self.status = "Allow Phonon microphone access in System Settings." }
                }
            }
            return
        }
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else {
            status = "Allow Phonon microphone access in System Settings."
            return
        }
        do {
            snapshotOptions()
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("phonon-lab-\(UUID().uuidString).wav")
            captureURL = url
            let recorder = try AVAudioRecorder(url: url, settings: [
                AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 16_000,
                AVNumberOfChannelsKey: 1, AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false,
            ])
            recorder.isMeteringEnabled = true
            guard recorder.prepareToRecord(), recorder.record(forDuration: SpeechLabAudio.maxSeconds) else {
                throw NSError(domain: "SpeechLab", code: 2,
                              userInfo: [NSLocalizedDescriptionKey: "The microphone could not start."])
            }
            self.recorder = recorder
            isRecording = true
            seconds = 0
            current = nil
            status = "Recording the system-selected microphone. Press Stop when finished."
            timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.tick() }
            }
        } catch { fail(error.localizedDescription) }
    }

    private func tick() {
        guard let recorder, isRecording else { return }
        recorder.updateMeters()
        levelDBFS = Double(recorder.averagePower(forChannel: 0))
        seconds = recorder.currentTime
        if !recorder.isRecording { finishRecording() }
    }

    private func snapshotOptions() {
        selectedReference = reference
        selectedCondition = condition
        selectedGain = gainDB
    }

    private func finishRecording() {
        guard isRecording, let captureURL else { return }
        recorder?.stop()
        recorder = nil
        timer?.invalidate(); timer = nil
        isRecording = false
        processAudio(captureURL)
    }

    func useSample() {
        guard !isBusy, canBegin?() == true,
              let resources = Bundle.main.resourceURL else { return }
        snapshotOptions()
        selectedCondition = "Bundled sample (normal speech)"
        selectedReference = "Hello Fluid Voice."
        processAudio(resources.appendingPathComponent("assets/startup.wav"))
    }

    func importAudio() {
        guard !isBusy, canBegin?() == true else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.wav, .aiff, .mpeg4Audio]
        panel.allowsMultipleSelection = false
        panel.message = "Choose a recording up to 30 seconds. It stays on this Mac."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        testAudio(url)
    }

    /// Shared by file import and the offline integration test. No microphone access.
    func testAudio(_ url: URL) {
        guard !isBusy, canBegin?() == true else { return }
        snapshotOptions()
        processAudio(url)
    }

    private func processAudio(_ url: URL) {
        do {
            let prepared = FileManager.default.temporaryDirectory
                .appendingPathComponent("phonon-lab-prepared-\(UUID().uuidString).wav")
            preparedURL = prepared
            let signal = try SpeechLabAudio.prepare(source: url, destination: prepared, gainDB: selectedGain)
            guard signal.rmsDBFS > -90 else {
                fail("The recording contains digital silence. A microphone cannot decode silent mouthing.")
                return
            }
            let id = "speech-lab-\(UUID().uuidString)"
            requestID = id
            current = SpeechLabTrial(id: id, date: Date(), condition: selectedCondition,
                                     reference: selectedReference, signal: signal)
            isProcessing = true
            started = Date()
            status = "Transcribing on this Mac…"
            onCommand?(["cmd": "lab_transcribe", "id": id, "path": prepared.path])
            timeout = Task { [weak self] in
                try? await Task.sleep(for: .seconds(45))
                guard !Task.isCancelled else { return }
                self?.fail("The local model did not finish. Check model status, then retry.")
            }
        } catch { fail(error.localizedDescription) }
    }

    func handle(_ event: [String: Any]) {
        guard let requestID, event["id"] as? String == requestID else { return }
        if event["type"] as? String == "error" {
            fail(event["msg"] as? String ?? "Local model failed.")
            return
        }
        guard event["type"] as? String == "result", var trial = current else { return }
        if event["kind"] as? String == "asr", event["partial"] as? Bool != true {
            trial.heard = event["text"] as? String ?? ""
            trial.asrMS = (event["seconds"] as? Double ?? 0) * 1_000
            current = trial
            guard !trial.heard.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                trial.batchWallMS = Date().timeIntervalSince(started ?? Date()) * 1_000
                complete(trial)
                return
            }
            status = "Rewriting locally with LFM3…"
            // No screen or text-box context, macro expansion, clipboard or paste operation.
            onCommand?(["cmd": "polish", "id": requestID, "text": trial.heard, "local_history": false])
        } else if event["kind"] as? String == "polish" {
            trial.wrote = event["text"] as? String ?? ""
            trial.refinerMS = event["latency_ms"] as? Double ?? 0
            trial.batchWallMS = Date().timeIntervalSince(started ?? Date()) * 1_000
            complete(trial)
        }
    }

    private func complete(_ trial: SpeechLabTrial) {
        current = trial
        trials.insert(trial, at: 0)
        if trials.count > 30 { trials.removeLast(trials.count - 30) }
        status = trial.heard.isEmpty ? "No words recognized. Try a closer microphone or normal voice."
            : "Complete. Review both versions before copying any text."
        cleanup()
    }

    func engineUnavailable() {
        if isBusy { fail("The local engine restarted. Stop and retry when model status is Ready.") }
    }

    func clear() { current = nil; trials = []; status = "Results cleared." }

    func shutdown() { cleanup() }

    private func fail(_ message: String) { status = message; cleanup() }

    private func cleanup() {
        timeout?.cancel(); timeout = nil
        timer?.invalidate(); timer = nil
        recorder?.stop(); recorder = nil
        isRecording = false; isProcessing = false; requestID = nil
        for url in [captureURL, preparedURL].compactMap({ $0 }) {
            try? FileManager.default.removeItem(at: url)
        }
        captureURL = nil; preparedURL = nil
    }

    func exportResults() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "phonon-speech-lab.json"
        panel.message = "Export text, references and measurements. Audio is not included."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            try encoder.encode(SpeechLabExport(trials: trials)).write(to: url, options: .atomic)
            status = "Exported results to \(url.lastPathComponent)."
        } catch { status = error.localizedDescription }
    }
}

struct SpeechLabView: View {
    @ObservedObject var store: NativeAppStore
    @ObservedObject var lab: SpeechLabController

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("Speech Lab").font(.system(size: 28, weight: .semibold))
                Text("Quiet speech, measured locally").font(.system(size: 17, weight: .medium))
                Text("Compare normal speech and whispers using your microphone. True silent mouthing needs additional sensing hardware; this experiment cannot hear unspoken words.")
                    .foregroundStyle(EmberTheme.soft)
                VStack(alignment: .leading, spacing: 12) {
                    Text("Read this exact sentence").font(.headline)
                    TextField("Reference transcript", text: $lab.reference, axis: .vertical)
                        .textFieldStyle(.roundedBorder).lineLimit(2...3)
                        .disabled(lab.isBusy)
                    HStack {
                        Picker("Condition", selection: $lab.condition) {
                            Text("Normal speech").tag("Normal speech")
                            Text("Whisper").tag("Whisper")
                        }
                        Picker("Digital gain", selection: $lab.gainDB) {
                            Text("Off").tag(0.0)
                            Text("+12 dB").tag(12.0)
                            Text("+24 dB").tag(24.0)
                        }
                    }
                    .disabled(lab.isBusy)
                    HStack(spacing: 12) {
                        Button(lab.isRecording ? "Stop & test" : "Record") { lab.toggleRecording() }
                            .buttonStyle(.borderedProminent)
                            .disabled((!store.engineReady || lab.isProcessing) && !lab.isRecording)
                        Button("Import audio…") { lab.importAudio() }
                            .disabled(!store.engineReady || lab.isBusy)
                        Button("Test sample") { lab.useSample() }
                            .disabled(!store.engineReady || lab.isBusy)
                        Spacer()
                        if lab.isRecording {
                            Text(String(format: "%.1f / 30 s · %.0f dBFS", lab.seconds, lab.levelDBFS))
                                .monospacedDigit().foregroundStyle(EmberTheme.ember2)
                        }
                    }
                    Text(lab.status).font(.callout).foregroundStyle(EmberTheme.soft)
                    Text("System-selected microphone · 30-second limit · Preview only. Gain amplifies noise too.")
                        .font(.caption).foregroundStyle(EmberTheme.muted)
                }
                .padding(16).background(EmberTheme.side, in: RoundedRectangle(cornerRadius: 12))

                if let trial = lab.current {
                    VStack(alignment: .leading, spacing: 10) {
                        output("PARAKEET HEARD", text: trial.heard)
                        output("LFM3 WROTE", text: trial.wrote)
                        if !lab.isProcessing {
                            HStack(spacing: 24) {
                                metric("Raw word error", value: percent(trial.rawWER))
                                metric("Rewrite difference", value: percent(trial.rewriteWER))
                                metric("Batch processing", value: String(format: "%.0f ms", trial.batchWallMS))
                            }
                            Text(String(format: "Input %.0f dBFS RMS · %.0f dBFS peak · %d clipped samples · ASR %.0f ms · LFM3 %.0f ms", trial.signal.rmsDBFS, trial.signal.peakDBFS, trial.signal.clippedSamples, trial.asrMS, trial.refinerMS))
                                .font(.caption).foregroundStyle(EmberTheme.muted)
                            Text("Word error uses the reference above, ignoring case and punctuation. Rewriting can intentionally change words. Batch time excludes recording and is not streaming key-release latency.")
                                .font(.caption).foregroundStyle(EmberTheme.soft)
                            Text("Scored against: \(trial.reference)")
                                .font(.caption).foregroundStyle(EmberTheme.muted)
                        }
                    }
                }
                HStack {
                    Text("\(lab.trials.count) trials this session").foregroundStyle(EmberTheme.soft)
                    Spacer()
                    if let research = Bundle.main.url(
                        forResource: "subvocal-research", withExtension: "md", subdirectory: "docs") {
                        Button("Research & protocol") { NSWorkspace.shared.open(research) }
                    }
                    Button("Clear") { lab.clear() }.disabled(lab.isBusy)
                    Button("Export results…") { lab.exportResults() }
                        .disabled(lab.trials.isEmpty || lab.isBusy)
                }
                ForEach(lab.trials.prefix(5)) { trial in
                    HStack {
                        Text(trial.condition).frame(maxWidth: .infinity, alignment: .leading)
                        Text(String(format: "+%.0f dB", trial.signal.gainDB))
                        Text("Raw errors \(percent(trial.rawWER))").frame(width: 115, alignment: .trailing)
                        Text(String(format: "%.0f ms", trial.batchWallMS)).frame(width: 70, alignment: .trailing)
                    }
                    .font(.caption).foregroundStyle(EmberTheme.soft)
                }
                Text("Recordings are temporary and deleted after each test. Text results stay in memory until you export them or quit. Nothing is pasted into other apps.")
                    .font(.caption).foregroundStyle(EmberTheme.muted)
            }
            .padding(30)
        }
    }

    private func output(_ title: String, text: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.caption.weight(.semibold)).foregroundStyle(EmberTheme.ember2)
            Text(text.isEmpty ? "—" : text).textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(12).background(EmberTheme.side, in: RoundedRectangle(cornerRadius: 8))
    }

    private func metric(_ title: String, value: String) -> some View {
        VStack(alignment: .leading) {
            Text(value).font(.system(size: 19, weight: .semibold)).monospacedDigit()
            Text(title).font(.caption).foregroundStyle(EmberTheme.soft)
        }
    }

    private func percent(_ value: Double?) -> String {
        value.map { String(format: "%.0f%%", $0 * 100) } ?? "No reference"
    }
}
