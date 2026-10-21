import BridgeCore
import Foundation

/// Keeps one child process running, restarting it after `retryDelay` whenever it exits.
/// It counts as up once a stderr line contains `upMarker`.
final class Supervised {
    enum State: Equatable { case starting, up, down(String), stopped }

    let name: String
    private let exe: String
    private let args: [String]
    private let upMarker: String
    private let retryDelay: TimeInterval
    private let before: () -> Void
    private let onStdout: ((String) -> Void)?
    private let onState: (State) -> Void
    private let log: Log

    private let lock = NSLock()
    private var process: Process?
    private var stopped = false
    private var lastLine = ""
    private let wake = DispatchSemaphore(value: 0)

    /// `before` runs ahead of every (re)start, e.g. to clean up after a previous instance.
    /// With `onStdout`, the child's stdout lines go there (and to the log), and its stdin is a pipe
    /// that stays open until it exits, so a remote command reading it lives as long as the connection.
    init(name: String, exe: String, args: [String], upMarker: String, retryDelay: TimeInterval,
         before: @escaping () -> Void = {}, onStdout: ((String) -> Void)? = nil,
         onState: @escaping (State) -> Void) {
        self.name = name; self.exe = exe; self.args = args; self.upMarker = upMarker
        self.retryDelay = retryDelay; self.before = before; self.onStdout = onStdout; self.onState = onState
        log = Log(Paths.log(name))
    }

    /// Text that identifies this child in `ps` output (used to clean up after a crash).
    var signature: String { args.joined(separator: " ") }

    func start() {
        let thread = Thread { [self] in loop() }
        thread.name = name
        thread.start()
    }

    /// Kills the current child so it restarts right away.
    func restart() {
        locked { process }?.terminate()
        wake.signal()
    }

    func stop() {
        locked { stopped = true; return process }?.terminate()
        wake.signal()
    }

    private func loop() {
        while !locked({ stopped }) {
            onState(.starting)
            locked { lastLine = "" }
            before()
            if locked({ stopped }) { break }
            let p = Process()
            p.executableURL = URL(fileURLWithPath: exe)
            p.arguments = args
            let stdin = Pipe(), stdout = Pipe()
            p.standardInput = onStdout == nil ? FileHandle.nullDevice : stdin
            p.standardOutput = onStdout == nil ? log.handle : stdout
            if let onStdout {
                let out = LineSplitter { [weak self] line in self?.log.write(line); onStdout(line) }
                stdout.fileHandleForReading.readabilityHandler = { h in
                    let data = h.availableData
                    if data.isEmpty { h.readabilityHandler = nil } else { out.feed(data) }
                }
            }
            let stderr = Pipe()
            p.standardError = stderr
            let lines = LineSplitter { [weak self] in self?.handle(line: $0) }
            stderr.fileHandleForReading.readabilityHandler = { h in
                let data = h.availableData
                if data.isEmpty { h.readabilityHandler = nil } else { lines.feed(data) }
            }
            let exited = DispatchSemaphore(value: 0)
            p.terminationHandler = { _ in exited.signal() }
            var status: Int32 = -1
            do {
                try p.run()
                locked { process = p }
                try? "\(p.processIdentifier)\n\(signature)\n".write(to: Paths.pidFile(name), atomically: true, encoding: .utf8)
                exited.wait()
                try? stdin.fileHandleForWriting.close()
                status = p.terminationStatus
                locked { process = nil }
                try? FileManager.default.removeItem(at: Paths.pidFile(name))
            } catch {
                locked { lastLine = "couldn't start \(exe): \(error.localizedDescription)" }
            }
            if locked({ stopped }) { break }
            let why = locked { lastLine.isEmpty ? "exited with status \(status)" : lastLine }
            onState(.down(why))
            log.write("\(name) stopped (\(why)); restarting in \(Int(retryDelay))s")
            _ = wake.wait(timeout: .now() + retryDelay)
        }
        onState(.stopped)
    }

    private func handle(line: String) {
        if line.contains(upMarker) { onState(.up) }
        if line.hasPrefix("debug") { return }  // `ssh -v` chatter; only used to spot upMarker
        log.write(line)
        locked { lastLine = line }
    }

    private func locked<T>(_ body: () -> T) -> T {
        lock.lock(); defer { lock.unlock() }
        return body()
    }

    /// Kills children left behind by an app instance that crashed (found through their pid files).
    static func killOrphans() {
        let files = (try? FileManager.default.contentsOfDirectory(at: Paths.run, includingPropertiesForKeys: nil)) ?? []
        for file in files where file.pathExtension == "pid" {
            let parts = ((try? String(contentsOf: file, encoding: .utf8)) ?? "").split(separator: "\n", maxSplits: 1)
            if parts.count == 2, let pid = Int32(parts[0]),
               let command = Shell.commandLine(of: pid), command.contains(parts[1].trimmingCharacters(in: .newlines)) {
                kill(pid, SIGTERM)
            }
            try? FileManager.default.removeItem(at: file)
        }
    }
}

/// Splits a byte stream into lines.
private final class LineSplitter {
    private var buffer = Data()
    private let onLine: (String) -> Void
    init(_ onLine: @escaping (String) -> Void) { self.onLine = onLine }

    func feed(_ data: Data) {
        buffer.append(data)
        while let i = buffer.firstIndex(of: UInt8(ascii: "\n")) {
            let line = String(decoding: buffer[buffer.startIndex..<i], as: UTF8.self)
            buffer.removeSubrange(buffer.startIndex...i)
            if !line.isEmpty { onLine(line) }
        }
    }
}
