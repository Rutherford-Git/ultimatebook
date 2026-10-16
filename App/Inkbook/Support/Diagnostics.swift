import Foundation
import MetricKit
import QuartzCore
import UIKit
import os
import InkbookCore

/// Startup wiring for error capture: the persistent log, crash markers from fatal signals and
/// uncaught exceptions, and MetricKit crash/hang reports (delivered on a later launch).
enum AppDiagnostics {
    static var folder: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Diagnostics", isDirectory: true)
    }

    static var log: DiagnosticsLog { .shared }
    private static let metrics = MetricsSubscriber()

    static func start() {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        log.attach(folder.appendingPathComponent("log.jsonl"))
        CrashMarker.checkPreviousRun()
        CrashMarker.install(at: folder.appendingPathComponent("crash.marker"))
        MXMetricManager.shared.add(metrics)
        let info = Bundle.main.infoDictionary
        let version = "\(info?["CFBundleShortVersionString"] as? String ?? "?") (\(info?["CFBundleVersion"] as? String ?? "?"))"
        log.info("app", "Launched Inkbook \(version) on \(UIDevice.current.model), iOS \(UIDevice.current.systemVersion)")
    }

    /// Plain-text report for the Diagnostics screen, sharing and the agent.
    static func report(limit: Int = 80) -> String {
        var text = log.report(limit: limit)
        let perf = PerfRecorder.shared.summaries()
        if !perf.isEmpty {
            text += "\n\nInk performance (this session):\n" + perf.map(\.line).joined(separator: "\n")
        }
        return text
    }
}

/// Records the signal of a fatal crash in a marker file using only async-signal-safe calls, so
/// the next launch can log it. Swift runtime traps (force unwrap, index out of range, exclusivity
/// violations) arrive as SIGTRAP.
private var crashFD: Int32 = -1

private func handleCrashSignal(_ sig: Int32) {
    if crashFD >= 0 {
        var byte = UInt8(truncatingIfNeeded: sig)
        _ = write(crashFD, &byte, 1)
    }
    signal(sig, SIG_DFL)
    raise(sig)
}

enum CrashMarker {
    static let signals: [Int32: String] = [
        SIGTRAP: "SIGTRAP (Swift runtime error: force unwrap, index out of range, exclusivity violation)",
        SIGABRT: "SIGABRT (abort, uncaught exception or failed assertion)",
        SIGSEGV: "SIGSEGV (bad memory access)", SIGBUS: "SIGBUS (bad memory access)",
        SIGILL: "SIGILL (illegal instruction)", SIGFPE: "SIGFPE (arithmetic error)",
    ]

    static var url: URL { AppDiagnostics.folder.appendingPathComponent("crash.marker") }
    static var exceptionURL: URL { AppDiagnostics.folder.appendingPathComponent("exception.txt") }

    static func checkPreviousRun() {
        if let data = try? Data(contentsOf: url), let sig = data.first {
            let name = signals[Int32(sig)] ?? "signal \(sig)"
            AppDiagnostics.log.error("crash", "The previous session crashed: \(name). The entries just before this one show what was happening.")
        }
        if let text = try? String(contentsOf: exceptionURL, encoding: .utf8), !text.isEmpty {
            AppDiagnostics.log.error("crash", "Uncaught exception in the previous session: \(text.prefix(1500))")
            try? FileManager.default.removeItem(at: exceptionURL)
        }
    }

    static func install(at url: URL) {
        crashFD = open(url.path, O_WRONLY | O_CREAT | O_TRUNC, 0o644)
        for sig in signals.keys { signal(sig, handleCrashSignal) }
        NSSetUncaughtExceptionHandler { exception in
            let text = "\(exception.name.rawValue): \(exception.reason ?? "")\n"
                + exception.callStackSymbols.prefix(25).joined(separator: "\n")
            try? text.write(to: CrashMarker.exceptionURL, atomically: true, encoding: .utf8)
        }
    }
}

/// Apple's on-device crash and hang diagnostics (iOS delivers them on a later launch).
private final class MetricsSubscriber: NSObject, MXMetricManagerSubscriber {
    func didReceive(_ payloads: [MXDiagnosticPayload]) {
        for payload in payloads {
            for crash in payload.crashDiagnostics ?? [] {
                let stack = String(decoding: crash.callStackTree.jsonRepresentation(), as: UTF8.self)
                AppDiagnostics.log.error("crash", "Crash report: type \(crash.exceptionType.map { "\($0)" } ?? "?"), "
                    + "signal \(crash.signal.map { "\($0)" } ?? "?"), \(crash.terminationReason ?? ""). Stack: \(stack.prefix(1500))")
            }
            for hang in payload.hangDiagnostics ?? [] {
                AppDiagnostics.log.warning("hang", "App hung for \(hang.hangDuration.formatted()).")
            }
        }
    }
}

/// Timing for the ink pipeline: signposts for Instruments plus millisecond samples for the HUD,
/// the diagnostics report and the agent.
@MainActor
enum InkPerf {
    static let signposter = OSSignposter(subsystem: "app.inkbook", category: "ink")
    static let touch = "touch handling", liveDraw = "live ink draw", pageDraw = "page redraw"
    static let commit = "pen-up commit", frame = "frame interval", fullRedraw = "full page redraw"

    /// The HUD and A/B switch read these.
    static var hudEnabled: Bool { UserDefaults.standard.bool(forKey: "diag.hud") }
    static var legacyLiveInk: Bool { UserDefaults.standard.bool(forKey: "diag.legacyLiveInk") }

    @discardableResult
    static func measure<T>(_ name: StaticString, _ metric: String, _ body: () -> T) -> T {
        let state = signposter.beginInterval(name)
        let start = CACurrentMediaTime()
        defer {
            PerfRecorder.shared.record(metric, ms: (CACurrentMediaTime() - start) * 1000)
            signposter.endInterval(name, state)
        }
        return body()
    }

    /// Measures time between screen refreshes while a stroke is in progress; anything over
    /// 1.5 frames is a visible hitch.
    final class FrameMonitor: NSObject {
        private var link: CADisplayLink?
        private var last: CFTimeInterval = 0
        private(set) var hitches = 0

        func start() {
            guard link == nil else { return }
            last = 0
            let link = CADisplayLink(target: self, selector: #selector(tick(_:)))
            link.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 120, preferred: 120)
            link.add(to: .main, forMode: .common)
            self.link = link
        }

        func stop() {
            link?.invalidate()
            link = nil
        }

        @objc private func tick(_ link: CADisplayLink) {
            defer { last = link.timestamp }
            guard last > 0 else { return }
            let ms = (link.timestamp - last) * 1000
            let expected = max((link.targetTimestamp - link.timestamp) * 1000, 1000.0 / 120)
            PerfRecorder.shared.record(InkPerf.frame, ms: ms)
            if ms > expected * 1.5 { hitches += 1 }
        }
    }
}

/// The user's improvement-notes log (Library › Improvement notes, or the notebook title menu).
@MainActor
final class ImprovementNotesModel: ObservableObject {
    static let shared = ImprovementNotesModel()

    @Published private(set) var notes: [ImprovementNote]
    private let store = ImprovementNotesStore(url: AppDiagnostics.folder.appendingPathComponent("improvement-notes.json"))

    init() { notes = store.load() }

    var plainText: String { ImprovementNotesStore.plainText(notes) }

    func add(_ text: String, category: ImprovementNote.Category, context: String?) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        notes.insert(ImprovementNote(text: t, category: category, context: context), at: 0)
        persist()
    }

    func update(_ note: ImprovementNote) {
        guard let i = notes.firstIndex(where: { $0.id == note.id }) else { return }
        notes[i] = note
        persist()
    }

    func delete(_ ids: Set<UUID>) {
        notes.removeAll { ids.contains($0.id) }
        persist()
    }

    private func persist() {
        do { try store.save(notes) } catch { AppDiagnostics.log.error("notes", "Saving improvement notes failed: \(error.localizedDescription)") }
    }
}
