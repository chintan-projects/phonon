import AVFoundation
import AppKit
import AudioToolbox
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
    let sourceSampleRate: Double
    let sourceChannels: Int
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
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(min(file.length, 16_384)))
        else { throw failure("Choose a recording between 0 and 30 seconds.") }
        let channelCount = Int(format.channelCount)
        guard channelCount > 0 else { throw failure("This recording has no audio channels.") }
        var mono: [Double] = []
        // A single AVAudioFile.read may return short while decoder output is
        // still buffered (notably CAF). Drain it rather than truncating the take.
        while file.framePosition < file.length {
            buffer.frameLength = 0
            let requested = AVAudioFrameCount(min(Int64(buffer.frameCapacity), file.length - file.framePosition))
            try file.read(into: buffer, frameCount: requested)
            let count = Int(buffer.frameLength)
            if count == 0 { throw failure("The recording ended before its declared audio frames.") }
            guard let channels = buffer.floatChannelData else {
                throw failure("This audio format could not be decoded.")
            }
            mono.append(contentsOf: (0..<count).map { index in
                (0..<channelCount).reduce(0.0) { $0 + Double(channels[$1][index]) }
                    / Double(channelCount)
            })
            guard Double(mono.count) / format.sampleRate <= maxSeconds + 0.1 else {
                throw failure("Choose a recording up to 30 seconds.")
            }
        }
        guard !mono.isEmpty, mono.allSatisfy({ $0.isFinite }) else {
            throw failure("The audio contains invalid sample values.")
        }
        // A linear/drop-sample conversion aliases high-frequency energy into
        // speech frequencies. Use the system's band-limited sample-rate converter.
        let samples = try resample(mono.map(Float.init), from: format.sampleRate).map(Double.init)
        let rms = sqrt(samples.reduce(0) { $0 + $1 * $1 } / Double(samples.count))
        let peak = samples.map(abs).max() ?? 0
        let gain = pow(10, min(24, max(0, gainDB)) / 20)
        let amplified = samples.map { $0 * gain }
        let pcm: [Int16] = amplified.map { Int16((min(1, max(-1, $0)) * 32767).rounded()) }
        try wav(pcm).write(to: destination, options: .atomic)
        return SpeechLabSignal(
            seconds: Double(samples.count) / 16_000,
            rmsDBFS: 20 * log10(max(rms, 1e-9)), peakDBFS: 20 * log10(max(peak, 1e-9)),
            gainDB: min(24, max(0, gainDB)), clippedSamples: amplified.filter { abs($0) > 1 }.count,
            sourceSampleRate: format.sampleRate, sourceChannels: channelCount)
    }

    static func writeNative(_ samples: [Float], sampleRate: Double, to url: URL) throws {
        guard !samples.isEmpty, sampleRate > 0,
              Double(samples.count) / sampleRate <= maxSeconds + 0.1,
              samples.allSatisfy({ $0.isFinite }),
              let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count))
        else { throw failure("The microphone did not produce a usable recording.") }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer {
            buffer.floatChannelData![0].update(from: $0.baseAddress!, count: samples.count)
        }
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        try file.write(from: buffer)
    }

    private static func resample(_ samples: [Float], from rate: Double) throws -> [Float] {
        if abs(rate - 16_000) < 0.5 { return samples }
        guard let inputFormat = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1),
              let outputFormat = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1),
              let input = AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: AVAudioFrameCount(samples.count)),
              let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: 4096),
              let converter = AVAudioConverter(from: inputFormat, to: outputFormat)
        else { throw failure("The recording's sample rate could not be converted.") }
        converter.sampleRateConverterQuality = Int(kAudioConverterQuality_Max)
        converter.sampleRateConverterAlgorithm = AVSampleRateConverterAlgorithm_Mastering
        converter.primeMethod = .normal
        var inputOffset = 0
        var result: [Float] = []
        while true {
            // The converter respects the buffer's current frame length on
            // subsequent calls; clear it before filling and before draining EOS.
            output.frameLength = 0
            var error: NSError?
            let status = converter.convert(to: output, error: &error) { requested, inputStatus in
                let count = min(Int(requested), samples.count - inputOffset)
                guard count > 0 else { inputStatus.pointee = .endOfStream; return nil }
                samples.withUnsafeBufferPointer {
                    input.floatChannelData![0].update(from: $0.baseAddress!.advanced(by: inputOffset), count: count)
                }
                input.frameLength = AVAudioFrameCount(count)
                inputOffset += count
                inputStatus.pointee = .haveData
                return input
            }
            if let error { throw error }
            if status == .error { throw failure("Audio sample-rate conversion failed.") }
            result.append(contentsOf: UnsafeBufferPointer(
                start: output.floatChannelData![0], count: Int(output.frameLength)))
            if status == .endOfStream { break }
            if output.frameLength == 0 { throw failure("Audio conversion produced no samples.") }
        }
        return result
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
    var microphone: String?
    var failure: String?

    var rawWER: Double? { SpeechLabMetrics.wordErrorRate(reference: reference, hypothesis: heard) }
    var rewriteWER: Double? { SpeechLabMetrics.wordErrorRate(reference: reference, hypothesis: wrote) }
}

struct SpeechLabCaptureFormat {
    let microphone: String
    let sampleRate: Double
}

struct SpeechLabCaptureMeter {
    let seconds: Double
    let rmsDBFS: Double
    let sampleRate: Double
}

struct SpeechLabCapture {
    let samples: [Float]
    let sampleRate: Double
}

private struct SpeechLabPreferences: Codable {
    let condition: String
    let gainDB: Double
    let saveToNotes: Bool
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
    @Published var condition = "Normal speech" { didSet { savePreferences() } }
    @Published var gainDB = 0.0 { didSet { savePreferences() } }
    @Published var saveToNotes = true { didSet { savePreferences() } }
    @Published private(set) var isRecording = false
    @Published private(set) var isProcessing = false
    @Published private(set) var status = "Ready for a short microphone experiment."
    @Published private(set) var seconds = 0.0
    @Published private(set) var levelDBFS = -90.0
    @Published private(set) var trials: [SpeechLabTrial] = []
    @Published private(set) var current: SpeechLabTrial?
    @Published private(set) var hasOriginalAudio = false
    @Published private(set) var hasASRAudio = false
    @Published private(set) var isPlaying = false
    @Published private(set) var savedStatus = ""
    @Published private(set) var captureDescription = "Uses the same microphone as normal dictation."
    var onCommand: (([String: Any]) -> Void)?
    var canBegin: (() -> Bool)?
    var onStartCapture: (() throws -> SpeechLabCaptureFormat)?
    var onCaptureMeter: (() -> SpeechLabCaptureMeter)?
    var onStopCapture: (() -> SpeechLabCapture)?
    var onSaveNote: ((SpeechLabTrial, Data, Data, String) throws -> Void)?
    var isBusy: Bool { isRecording || isProcessing || permissionPending }
    private var permissionPending = false
    private var captureActive = false
    private var captureFormat: SpeechLabCaptureFormat?
    private var captureStarted: Date?
    private var originalAudio: Data?
    private var asrAudio: Data?
    private var originalExtension = "caf"
    private var player: AVAudioPlayer?
    private var playbackTask: Task<Void, Never>?
    private var selectedSaveToNotes = true
    private var preferencesURL: URL?
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

    func configurePreferences(at url: URL) {
        if let data = try? Data(contentsOf: url),
           let saved = try? JSONDecoder().decode(SpeechLabPreferences.self, from: data) {
            condition = saved.condition == "Whisper" ? "Whisper" : "Normal speech"
            gainDB = [0.0, 12.0, 24.0].contains(saved.gainDB) ? saved.gainDB : 0
            saveToNotes = saved.saveToNotes
        }
        preferencesURL = url
    }

    private func savePreferences() {
        guard let preferencesURL else { return }
        do {
            try FileManager.default.createDirectory(at: preferencesURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(SpeechLabPreferences(condition: condition, gainDB: gainDB, saveToNotes: saveToNotes))
            try data.write(to: preferencesURL, options: .atomic)
        } catch { savedStatus = "Could not save Speech Lab settings: \(error.localizedDescription)" }
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
                    else { self.status = "Allow \(AppBrand.name) microphone access in System Settings." }
                }
            }
            return
        }
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else {
            status = "Allow \(AppBrand.name) microphone access in System Settings."
            return
        }
        do {
            snapshotOptions()
            resetPlayback()
            guard let onStartCapture else {
                throw NSError(domain: "SpeechLab", code: 2,
                              userInfo: [NSLocalizedDescriptionKey: "The microphone is not connected to Speech Lab."])
            }
            let format = try onStartCapture()
            captureActive = true
            captureFormat = format
            captureStarted = Date()
            captureDescription = String(format: "%@ · %.1f kHz capture → 16 kHz ASR", format.microphone, format.sampleRate / 1_000)
            isRecording = true
            seconds = 0
            current = nil
            status = "Recording \(format.microphone). Press Stop when finished."
            timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.tick() }
            }
        } catch { fail(error.localizedDescription) }
    }

    private func tick() {
        guard isRecording else { return }
        if let meter = onCaptureMeter?() {
            levelDBFS = meter.rmsDBFS
            seconds = meter.seconds
            if let captureFormat, abs(meter.sampleRate - captureFormat.sampleRate) > 0.5 {
                fail("The microphone format changed during recording. Please record again.")
                return
            }
        }
        if Date().timeIntervalSince(captureStarted ?? Date()) >= SpeechLabAudio.maxSeconds {
            finishRecording()
        }
    }

    private func snapshotOptions() {
        selectedReference = reference
        selectedCondition = condition
        selectedGain = gainDB
        selectedSaveToNotes = saveToNotes
        savedStatus = ""
    }

    func finishRecording() {
        guard isRecording, let captured = onStopCapture?() else { return }
        captureActive = false
        timer?.invalidate(); timer = nil
        isRecording = false
        do {
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("murmur-lab-\(UUID().uuidString).caf")
            captureURL = url
            let limited = Array(captured.samples.prefix(Int(captured.sampleRate * SpeechLabAudio.maxSeconds)))
            try SpeechLabAudio.writeNative(limited, sampleRate: captured.sampleRate, to: url)
            processAudio(url)
        } catch { fail(error.localizedDescription) }
    }

    func useSample() {
        guard !isBusy, canBegin?() == true,
              let resources = Bundle.main.resourceURL else { return }
        snapshotOptions()
        selectedCondition = "Bundled sample (normal speech)"
        selectedSaveToNotes = false
        captureFormat = nil
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
        captureFormat = nil
        processAudio(url)
    }

    private func processAudio(_ url: URL) {
        current = nil
        do {
            resetPlayback()
            originalAudio = try Data(contentsOf: url)
            originalExtension = url.pathExtension.lowercased()
            hasOriginalAudio = true
            let prepared = FileManager.default.temporaryDirectory
                .appendingPathComponent("phonon-lab-prepared-\(UUID().uuidString).wav")
            preparedURL = prepared
            let signal = try SpeechLabAudio.prepare(source: url, destination: prepared, gainDB: selectedGain)
            asrAudio = try Data(contentsOf: prepared)
            hasASRAudio = true
            let id = "speech-lab-\(UUID().uuidString)"
            requestID = id
            current = SpeechLabTrial(id: id, date: Date(), condition: selectedCondition,
                                     reference: selectedReference, signal: signal)
            current?.microphone = captureFormat?.microphone
            persistNote()
            guard signal.rmsDBFS > -90 else {
                fail("The recording contains digital silence. Check the selected microphone.")
                return
            }
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
            persistNote()
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
        persistNote()
        trials.insert(trial, at: 0)
        if trials.count > 30 { trials.removeLast(trials.count - 30) }
        status = trial.heard.isEmpty ? "No words recognized. Try a closer microphone or normal voice."
            : "Complete. Review both versions before copying any text. \(savedStatus)"
        cleanup()
    }

    func engineUnavailable() {
        if isBusy { fail("The local engine restarted. Stop and retry when model status is Ready.") }
    }

    func clear() { current = nil; trials = []; resetPlayback(); status = "View cleared. Saved Notes are kept." }

    func shutdown() { cleanup(); resetPlayback() }

    private func fail(_ message: String) {
        current?.failure = message
        persistNote()
        status = message
        cleanup()
    }

    private func cleanup() {
        timeout?.cancel(); timeout = nil
        timer?.invalidate(); timer = nil
        if captureActive { _ = onStopCapture?(); captureActive = false }
        isRecording = false; isProcessing = false; requestID = nil
        for url in [captureURL, preparedURL].compactMap({ $0 }) {
            try? FileManager.default.removeItem(at: url)
        }
        captureURL = nil; preparedURL = nil
    }

    private func persistNote() {
        guard selectedSaveToNotes, let current, let originalAudio, let asrAudio, let onSaveNote else { return }
        do {
            try onSaveNote(current, originalAudio, asrAudio, originalExtension)
            savedStatus = "Saved in Notes."
        } catch { savedStatus = "Could not save to Notes: \(error.localizedDescription)" }
    }

    private func resetPlayback() {
        stopPlayback()
        originalAudio = nil; asrAudio = nil
        hasOriginalAudio = false; hasASRAudio = false
    }

    func stopPlayback() {
        playbackTask?.cancel(); playbackTask = nil
        player?.stop(); player = nil; isPlaying = false
    }

    func playAudio(original: Bool) {
        stopPlayback()
        guard let data = original ? originalAudio : asrAudio else { return }
        do {
            let player = try AVAudioPlayer(data: data)
            guard player.prepareToPlay(), player.play() else { return }
            self.player = player
            isPlaying = true
            playbackTask = Task { [weak self] in
                while !Task.isCancelled, self?.player?.isPlaying == true {
                    try? await Task.sleep(for: .milliseconds(100))
                }
                if !Task.isCancelled { self?.isPlaying = false }
            }
        } catch { status = "Could not play this recording: \(error.localizedDescription)" }
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
    var onSettingsChanged: () -> Void = {}

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("Speech Lab").font(.system(size: 28, weight: .semibold))
                Text("Quiet speech, measured locally").font(.system(size: 17, weight: .medium))
                Text("Compare normal speech and whispers using your microphone. True silent mouthing needs additional sensing hardware; this experiment cannot hear unspoken words.")
                    .foregroundStyle(EmberTheme.soft)
                VStack(alignment: .leading, spacing: 12) {
                    Picker("Microphone", selection: Binding(
                        get: { store.settings.microphonePriority.first ?? "" },
                        set: { name in
                            store.updateSettings { $0.microphonePriority = name.isEmpty ? [] : [name] }
                            onSettingsChanged()
                        })) {
                        Text("Automatic (same as dictation)").tag("")
                        ForEach(store.availableMicrophones, id: \.self) { Text($0).tag($0) }
                    }.disabled(lab.isBusy)
                    Text("Reference sentence (read it exactly, or clear for free dictation)").font(.headline)
                    TextField("Reference transcript", text: $lab.reference, axis: .vertical)
                        .textFieldStyle(.roundedBorder).lineLimit(2...3)
                        .disabled(lab.isBusy)
                    HStack {
                        Picker("Condition", selection: $lab.condition) {
                            Text("Normal speech").tag("Normal speech")
                            Text("Whisper").tag("Whisper")
                        }
                        .help("Labels the trial. Both conditions use the same Parakeet ASR model.")
                        Picker("Digital gain", selection: $lab.gainDB) {
                            Text("Off").tag(0.0)
                            Text("+12 dB").tag(12.0)
                            Text("+24 dB").tag(24.0)
                        }
                    }
                    .disabled(lab.isBusy)
                    Text("Both conditions use Parakeet. Gain changes the audio sent to recognition.")
                        .font(.caption).foregroundStyle(EmberTheme.muted)
                    Toggle("Save recordings and transcripts in Notes", isOn: $lab.saveToNotes)
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
                    Text(lab.captureDescription + " · 30-second limit. Gain amplifies noise too.")
                        .font(.caption).foregroundStyle(EmberTheme.muted)
                    if lab.hasOriginalAudio {
                        HStack {
                            Button("Play original") { lab.playAudio(original: true) }
                            if lab.hasASRAudio { Button("Play ASR input") { lab.playAudio(original: false) } }
                            if lab.isPlaying { Button("Stop playback") { lab.stopPlayback() } }
                            Spacer()
                            Button("Open Notes") { store.pageRequest = .notes }
                        }.disabled(lab.isBusy)
                    }
                    if !lab.savedStatus.isEmpty {
                        Text(lab.savedStatus).font(.caption).foregroundStyle(EmberTheme.soft)
                    }
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
                    Button("Clear view") { lab.clear() }.disabled(lab.isBusy)
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
                Text(lab.saveToNotes
                     ? "Recordings and transcripts are saved on this Mac in Notes until you delete them. Nothing is pasted into other apps."
                     : "Saving is off. Latest audio stays in memory for playback; temporary files are deleted after testing. Nothing is pasted into other apps.")
                    .font(.caption).foregroundStyle(EmberTheme.muted)
            }
            .padding(30)
        }
        .buttonStyle(PillButtonStyle())
        .onAppear { store.refreshAvailableMicrophones() }
        .onDisappear { lab.stopPlayback() }
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
