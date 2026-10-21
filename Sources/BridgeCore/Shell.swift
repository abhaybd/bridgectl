import Foundation

public struct ProcResult {
    public let status: Int32
    public let stdout: String
    public let stderr: String

    public var ok: Bool { status == 0 }
    /// The most useful text for an error message: stderr if there is any, else stdout.
    public var message: String {
        let err = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        return err.isEmpty ? stdout.trimmingCharacters(in: .whitespacesAndNewlines) : err
    }
}

public enum Shell {
    /// Runs `exe` to completion, capturing its output; it is killed after `timeout` seconds.
    /// Not for commands that leave background children holding stdout/stderr (such as `ssh -f`).
    @discardableResult
    public static func run(_ exe: String, _ args: [String], input: String? = nil,
                           env: [String: String] = [:], timeout: TimeInterval = 60) -> ProcResult {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = args
        if !env.isEmpty { p.environment = ProcessInfo.processInfo.environment.merging(env) { $1 } }
        let out = Pipe(), err = Pipe(), inp = Pipe()
        p.standardOutput = out
        p.standardError = err
        p.standardInput = input == nil ? FileHandle.nullDevice : inp
        let exited = DispatchSemaphore(value: 0)
        p.terminationHandler = { _ in exited.signal() }
        do { try p.run() } catch {
            return ProcResult(status: 127, stdout: "", stderr: "\(exe): \(error.localizedDescription)")
        }

        let collected = Collected()
        let readers = DispatchGroup()
        for (pipe, isOut) in [(out, true), (err, false)] {
            readers.enter()
            DispatchQueue.global().async {
                collected.set(pipe.fileHandleForReading.readDataToEndOfFile(), stdout: isOut)
                readers.leave()
            }
        }
        if let input {
            try? inp.fileHandleForWriting.write(contentsOf: Data(input.utf8))
            try? inp.fileHandleForWriting.close()
        }
        var timedOut = false
        if exited.wait(timeout: .now() + timeout) == .timedOut {
            timedOut = true
            p.terminate()
            if exited.wait(timeout: .now() + 3) == .timedOut { kill(p.processIdentifier, SIGKILL) }
        }
        _ = readers.wait(timeout: .now() + 3)
        let (o, e) = collected.get()
        return ProcResult(status: timedOut ? 124 : p.terminationStatus,
                          stdout: String(decoding: o, as: UTF8.self),
                          stderr: timedOut ? "timed out after \(Int(timeout))s" : String(decoding: e, as: UTF8.self))
    }

    /// Quotes `s` for a POSIX shell.
    public static func quote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// The command line of a running process, or nil if it isn't running.
    public static func commandLine(of pid: Int32) -> String? {
        let r = run("/bin/ps", ["-o", "command=", "-p", "\(pid)"], timeout: 5)
        let line = r.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return r.ok && !line.isEmpty ? line : nil
    }
}

private final class Collected {
    private let lock = NSLock()
    private var out = Data(), err = Data()
    func set(_ data: Data, stdout: Bool) { lock.lock(); if stdout { out = data } else { err = data }; lock.unlock() }
    func get() -> (Data, Data) { lock.lock(); defer { lock.unlock() }; return (out, err) }
}

/// Append-only, thread-safe log file. Its handle can be given to child processes as stdout/stderr.
public final class Log {
    public let handle: FileHandle
    private let lock = NSLock()
    private static let stamp: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f
    }()

    public init(_ url: URL) {
        Paths.ensure()
        if let size = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int,
           size > 2_000_000 {
            try? FileManager.default.removeItem(at: url)
        }
        // O_APPEND keeps our lines and children's output from overwriting each other.
        let fd = open(url.path, O_WRONLY | O_APPEND | O_CREAT | O_CLOEXEC, 0o600)
        handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
    }

    public func write(_ line: String) {
        lock.lock(); defer { lock.unlock() }
        try? handle.write(contentsOf: Data("\(Log.stamp.string(from: Date())) \(line)\n".utf8))
    }
}
