import Foundation
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
}
