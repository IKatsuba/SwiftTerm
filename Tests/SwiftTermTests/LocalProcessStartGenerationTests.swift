#if os(macOS)
import Foundation
import Testing

@testable import SwiftTerm

private final class ExitWatcher: LocalProcessDelegate {
    private let lock = NSLock()
    private var exits = 0

    var terminated: Int { lock.withLock { exits } }

    func processTerminated(_ source: LocalProcess, exitCode: Int32?) {
        lock.withLock { exits += 1 }
    }
    func dataReceived(slice: ArraySlice<UInt8>) {}
    func getWindowSize() -> winsize { winsize(ws_row: 24, ws_col: 80, ws_xpixel: 0, ws_ypixel: 0) }
}

/// The generation is the receipt a host compares across `startProcess`,
/// because EOF leaves `shellPid`, `childfd` and `running` exactly as a refused
/// start would.
@Suite("LocalProcess start generation")
final class LocalProcessStartGenerationTests {
    private let queue = DispatchQueue(label: "start-generation-tests")

    private func waitUntil(_ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(10)
        while !condition() {
            if Date() > deadline { return false }
            Thread.sleep(forTimeInterval: 0.01)
        }
        return true
    }

    @Test("A successful fork raises it and reports success")
    func successRaisesIt() {
        let watcher = ExitWatcher()
        let process = LocalProcess(delegate: watcher, dispatchQueue: queue)
        #expect(process.startGeneration == 0)
        #expect(process.startProcess(executable: "/bin/sh", args: ["-c", "exit 0"]))
        #expect(process.startGeneration == 1)
        #expect(waitUntil { watcher.terminated == 1 })
    }

    @Test("A refused start while running leaves it alone, as does terminate")
    func refusedStartKeepsIt() {
        let watcher = ExitWatcher()
        let process = LocalProcess(delegate: watcher, dispatchQueue: queue)
        #expect(process.startProcess(executable: "/bin/sleep", args: ["30"]))
        #expect(process.startGeneration == 1)
        #expect(!process.startProcess(executable: "/bin/sh", args: ["-c", "exit 0"]))
        #expect(process.startGeneration == 1)
        let pid = process.shellPid
        process.terminate()
        #expect(process.startGeneration == 1)
        // terminate() cancels the exit source, so the child is reaped here;
        // SIGTERM may be held off in the forked child, and an unreaped child's
        // number is still ours to signal.
        kill(pid, SIGKILL)
        var status: Int32 = 0
        #expect(waitpid(pid, &status, 0) == pid)
    }

    @Test("EOF from a short-lived child keeps it, and the next start raises it again")
    func eofKeepsIt() {
        let watcher = ExitWatcher()
        let process = LocalProcess(delegate: watcher, dispatchQueue: queue)
        #expect(process.startProcess(executable: "/bin/sh", args: ["-c", "exit 0"]))
        // EOF is what resets the marker; waiting for it is what puts the
        // process in the state a refused start would also leave.
        #expect(waitUntil { process.childfd == -1 && !process.running })
        #expect(waitUntil { watcher.terminated == 1 })
        #expect(process.startGeneration == 1)
        #expect(process.startProcess(executable: "/bin/sh", args: ["-c", "exit 0"]))
        #expect(process.startGeneration == 2)
        #expect(waitUntil { watcher.terminated == 2 })
    }
}
#endif
