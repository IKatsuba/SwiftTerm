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
    func successRaisesIt() throws {
        let watcher = ExitWatcher()
        let process = LocalProcess(delegate: watcher, dispatchQueue: queue)
        #expect(process.startGeneration == 0)
        try #require(process.startProcess(executable: "/bin/sh", args: ["-c", "exit 0"]))
        let pid = process.shellPid
        try #require(pid > 0)
        #expect(process.startGeneration == 1)
        #expect(waitUntil { watcher.terminated == 1 })
        var status: Int32 = 0
        #expect(waitpid(pid, &status, WNOHANG) == pid)
    }

    @Test("A refused start while running leaves it alone, as does terminate")
    func refusedStartKeepsIt() throws {
        let watcher = ExitWatcher()
        let process = LocalProcess(delegate: watcher, dispatchQueue: queue)
        // A child that ends by itself: the runner's children may ignore the
        // SIGTERM terminate() sends, and this test sends no signal of its own.
        try #require(process.startProcess(executable: "/bin/sleep", args: ["3"]))
        let pid = process.shellPid
        try #require(pid > 0)
        #expect(process.startGeneration == 1)
        let refused = !process.startProcess(executable: "/bin/sh", args: ["-c", "exit 0"])
        #expect(refused)
        #expect(process.startGeneration == 1)
        var status: Int32 = 0
        guard refused else {
            // Taken anyway: reap both children and signal neither, since
            // terminate() would aim at a number this test may have collected.
            let stray = process.shellPid
            if stray > 0, stray != pid {
                #expect(waitUntil { waitpid(stray, &status, WNOHANG) == stray })
            }
            #expect(waitUntil { waitpid(pid, &status, WNOHANG) == pid })
            return
        }
        #expect(waitUntil { watcher.terminated == 1 })
        // Called while the exited child is unreaped — LocalProcess reads exits
        // with WNOWAIT and never collects — so its SIGTERM can reach only the
        // corpse this test started.
        process.terminate()
        #expect(process.startGeneration == 1)
        #expect(waitpid(pid, &status, WNOHANG) == pid)
    }

    @Test("EOF from a short-lived child keeps it, and the next start raises it again")
    func eofKeepsIt() throws {
        let watcher = ExitWatcher()
        let process = LocalProcess(delegate: watcher, dispatchQueue: queue)
        try #require(process.startProcess(executable: "/bin/sh", args: ["-c", "exit 0"]))
        let first = process.shellPid
        try #require(first > 0)
        // EOF is what resets the marker; waiting for it is what puts the
        // process in the state a refused start would also leave.
        #expect(waitUntil { process.childfd == -1 && !process.running })
        #expect(waitUntil { watcher.terminated == 1 })
        #expect(process.startGeneration == 1)
        var status: Int32 = 0
        #expect(waitpid(first, &status, WNOHANG) == first)

        try #require(process.startProcess(executable: "/bin/sh", args: ["-c", "exit 0"]))
        let second = process.shellPid
        try #require(second > 0)
        #expect(process.startGeneration == 2)
        #expect(waitUntil { watcher.terminated == 2 })
        #expect(waitpid(second, &status, WNOHANG) == second)
    }
}
#endif
