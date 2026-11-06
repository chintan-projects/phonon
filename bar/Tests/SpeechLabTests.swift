import Foundation
import AVFoundation
import XCTest

@testable import PhononBar

@MainActor
final class SpeechLabTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func audio(value: Int16 = 1000, seconds: Double = 1) throws -> URL {
        let url = directory.appendingPathComponent("input.wav")
        try SpeechLabAudio.wav([Int16](repeating: value, count: Int(16_000 * seconds))).write(to: url)
        return url
    }

    func testWordErrorsIncludeInsertionsAndIgnoreCaseAndPunctuation() throws {
        XCTAssertEqual(SpeechLabMetrics.wordErrorRate(reference: "Hello, world!", hypothesis: "hello WORLD"), 0)
        XCTAssertEqual(SpeechLabMetrics.wordErrorRate(reference: "move to thursday", hypothesis: "move to tuesday"), 1.0 / 3)
        XCTAssertEqual(SpeechLabMetrics.wordErrorRate(reference: "one", hypothesis: "one two three"), 2)
        XCTAssertEqual(SpeechLabMetrics.wordErrorRate(reference: "one two", hypothesis: ""), 1)
        XCTAssertNil(SpeechLabMetrics.wordErrorRate(reference: " ", hypothesis: "hello"))
    }

    func testGainReportsClippingWithoutWrappingPCM() throws {
        let url = try audio(value: 16000)
        let output = directory.appendingPathComponent("gained.wav")
        let signal = try SpeechLabAudio.prepare(source: url, destination: output, gainDB: 12)
        XCTAssertEqual(signal.seconds, 1, accuracy: 0.001)
        XCTAssertEqual(signal.clippedSamples, 16_000)
        XCTAssertEqual(signal.rmsDBFS, -6.23, accuracy: 0.1)
        let bytes = try Data(contentsOf: output)
        XCTAssertEqual(bytes.count, 44 + 32_000)
        XCTAssertEqual(Array(bytes[44...45]), [255, 127])
    }

    func testRejectsLongAudio() throws {
        let input = try audio(seconds: 30.1)
        XCTAssertThrowsError(try SpeechLabAudio.prepare(
            source: input, destination: directory.appendingPathComponent("out.wav"), gainDB: 0))
    }

    func testSilenceNeverReachesASROrRewrite() throws {
        let lab = SpeechLabController()
        lab.canBegin = { true }
        var commands = 0
        lab.onCommand = { _ in commands += 1 }
        lab.testAudio(try audio(value: 0))
        XCTAssertEqual(commands, 0)
        XCTAssertTrue(lab.status.contains("digital silence"))
        XCTAssertFalse(lab.isBusy)
    }

    func testPreviewRoutesRawAndRewriteSeparatelyAndDeletesTemporaryAudio() throws {
        let lab = SpeechLabController()
        lab.canBegin = { true }
        lab.reference = "move to thursday"
        var commands: [[String: Any]] = []
        lab.onCommand = { commands.append($0) }
        let source = try audio()
        lab.testAudio(source)
        let request = try XCTUnwrap(commands.first)
        let id = try XCTUnwrap(request["id"] as? String)
        let path = try XCTUnwrap(request["path"] as? String)
        XCTAssertEqual(request["cmd"] as? String, "lab_transcribe")
        XCTAssertTrue(FileManager.default.fileExists(atPath: path))
        lab.handle(["type": "result", "kind": "asr", "id": "other", "text": "ignored"])
        XCTAssertEqual(commands.count, 1)
        lab.handle(["type": "result", "kind": "asr", "id": id,
                    "text": "move to tuesday", "seconds": 0.01])
        XCTAssertEqual(commands.last?["cmd"] as? String, "polish")
        XCTAssertEqual(commands.last?["local_history"] as? Bool, false)
        lab.handle(["type": "result", "kind": "polish", "id": id,
                    "text": "Move to Thursday.", "latency_ms": 20.0])
        let trial = try XCTUnwrap(lab.trials.first)
        XCTAssertEqual(trial.rawWER, 1.0 / 3)
        XCTAssertEqual(trial.rewriteWER, 0)
        XCTAssertFalse(lab.isBusy)
        XCTAssertFalse(FileManager.default.fileExists(atPath: path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
        // A duplicate or late event cannot become another trial or an insertion.
        lab.handle(["type": "result", "kind": "polish", "id": id, "text": "late"])
        XCTAssertEqual(lab.trials.count, 1)
        let report = try JSONSerialization.jsonObject(with: JSONEncoder().encode(
            SpeechLabExport(trials: lab.trials))) as? [String: Any]
        XCTAssertEqual(report?["silentSpeechSupported"] as? Bool, false)
        XCTAssertNotNil((report?["trials"] as? [[String: Any]])?.first?["rawWordErrorRate"])
    }

    func testEngineLossReleasesTheLabAndTemporaryFiles() throws {
        let lab = SpeechLabController()
        lab.canBegin = { true }
        var command: [String: Any] = [:]
        lab.onCommand = { command = $0 }
        lab.testAudio(try audio())
        let path = try XCTUnwrap(command["path"] as? String)
        lab.engineUnavailable()
        XCTAssertFalse(lab.isBusy)
        XCTAssertFalse(FileManager.default.fileExists(atPath: path))
        XCTAssertTrue(lab.trials.isEmpty)
    }

    func testHighQualityConversionRejectsAliasingAndPreservesSpeechBandAndDuration() throws {
        let rate = 48_000.0
        for frequency in [1_000.0, 12_000.0] {
            let samples = (0..<48_000).map { Float(0.4 * sin(2 * .pi * frequency * Double($0) / rate)) }
            let source = directory.appendingPathComponent("native.caf")
            let destination = directory.appendingPathComponent("converted.wav")
            try SpeechLabAudio.writeNative(samples, sampleRate: rate, to: source)
            let signal = try SpeechLabAudio.prepare(source: source, destination: destination, gainDB: 0)
            XCTAssertEqual(signal.sourceSampleRate, 48_000)
            XCTAssertEqual(signal.seconds, 1, accuracy: 1.0 / 16_000)
            let file = try AVAudioFile(forReading: destination)
            let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)))
            try file.read(into: buffer)
            let values = Array(UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength)))
            let middle = values.dropFirst(500).dropLast(500)
            let rms = sqrt(middle.reduce(0.0) { $0 + Double($1 * $1) } / Double(middle.count))
            if frequency == 1_000 { XCTAssertEqual(rms, 0.4 / sqrt(2), accuracy: 0.005) }
            else { XCTAssertLessThan(rms, 0.002, "12 kHz must not alias to a false 4 kHz tone") }
        }
    }

    func testSavedNotesSurviveReloadAndUpdateWithoutDuplicatingAudio() throws {
        let support = directory.appendingPathComponent("support")
        let store = NativeAppStore(supportDirectory: support)
        let lab = store.speechLab
        lab.canBegin = { true }
        lab.saveToNotes = true
        lab.condition = "Whisper"
        lab.gainDB = 12
        var requests: [[String: Any]] = []
        lab.onCommand = { requests.append($0) }
        lab.testAudio(try audio())
        XCTAssertEqual(store.speechLabNotes.count, 1, "audio is saved before recognition completes")
        let id = try XCTUnwrap(requests.first?["id"] as? String)
        lab.handle(["type": "result", "kind": "asr", "id": id, "text": "heard words", "seconds": 0.1])
        lab.handle(["type": "result", "kind": "polish", "id": id, "text": "Heard words.", "latency_ms": 10.0])
        let reloaded = NativeAppStore(supportDirectory: support)
        XCTAssertEqual(reloaded.speechLabNotes.count, 1)
        XCTAssertEqual(reloaded.voiceNotes.first?.raw, "heard words")
        XCTAssertEqual(reloaded.voiceNotes.first?.wrote, "Heard words.")
        let note = try XCTUnwrap(reloaded.voiceNotes.first)
        XCTAssertTrue(FileManager.default.fileExists(atPath: note.audioURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: try XCTUnwrap(note.asrURL).path))
        XCTAssertEqual(reloaded.speechLab.condition, "Whisper")
        XCTAssertEqual(reloaded.speechLab.gainDB, 12)
        XCTAssertTrue(reloaded.speechLab.saveToNotes)
        XCTAssertTrue(reloaded.history.isEmpty, "experiments stay separate from dictation metrics")
        XCTAssertTrue(lab.hasOriginalAudio)
        XCTAssertTrue(lab.hasASRAudio)
    }

    func testSavingOffLeavesNoNotesAndFailedRecognitionKeepsSavedAudio() throws {
        let support = directory.appendingPathComponent("support")
        let store = NativeAppStore(supportDirectory: support)
        let lab = store.speechLab
        lab.canBegin = { true }
        var request: [String: Any] = [:]
        lab.onCommand = { request = $0 }
        lab.saveToNotes = false
        lab.testAudio(try audio())
        lab.engineUnavailable()
        XCTAssertTrue(store.speechLabNotes.isEmpty)
        lab.saveToNotes = true
        lab.testAudio(try audio())
        let id = try XCTUnwrap(request["id"] as? String)
        lab.handle(["type": "error", "id": id, "msg": "decoder failed"])
        XCTAssertEqual(store.speechLabNotes.count, 1)
        XCTAssertEqual(store.speechLabNotes.first?.record.trial.failure, "decoder failed")
        lab.clear()
        XCTAssertFalse(lab.hasOriginalAudio)
        XCTAssertEqual(store.speechLabNotes.count, 1, "Clear view is not Delete Notes")
    }
}
