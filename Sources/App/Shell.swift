import Foundation

/// The errand boy. 🏃
///
/// Two of the three sources are other people's binaries (`op` and
/// `keepassxc-cli`), so this is the one place that spawns a process, and the
/// one place a master password is written to a pipe.
///
/// **Nothing sensitive is ever an argument.** Arguments are world readable
/// through `ps` for as long as the process lives, so a password goes on stdin
/// and only on stdin. The caller hands over bytes, this writes them, closes the
/// pipe, and the caller's buffer is the caller's to wipe.
///
/// The trap: writing a large stdin and then reading stdout deadlocks when the
/// child fills its output pipe before it has finished reading its input.
/// Sesam's inputs are one line and its outputs are megabytes, so the order here
/// (write everything, close, then read to the end) is safe for what it is used
/// for and would not be safe in general. Said out loud so nobody reaches for it
/// as a general purpose runner.
enum Shell {

    struct Result {
        let status: Int32
        /// Mutable so a caller holding something sensitive can overwrite it in
        /// place the moment it has been parsed.
        var out: Data
        let err: String

        var ok: Bool { status == 0 }
        var text: String { String(decoding: out, as: UTF8.self) }
    }

    /// Run `path` and wait. `stdin` is written and closed before anything is
    /// read back. `timeout` kills a child that has stopped making sense, which
    /// on this path means a CLI that decided to prompt on a terminal that is
    /// not there.
    static func run(_ path: String, _ args: [String],
                    stdin: [UInt8]? = nil,
                    timeout: TimeInterval = 20) throws -> Result {

        guard FileManager.default.isExecutableFile(atPath: path) else {
            throw VaultError("\(path) is not installed.")
        }

        let task = Process()
        task.executableURL = URL(fileURLWithPath: path)
        task.arguments = args

        let outPipe = Pipe(), errPipe = Pipe(), inPipe = Pipe()
        task.standardOutput = outPipe
        task.standardError = errPipe
        task.standardInput = inPipe

        // A CLI that finds no terminal behaves differently from one that does,
        // and both `op` and keepassxc-cli decide that by looking at the
        // environment as well. Keep the user's environment (op needs its
        // session variables and the desktop app socket) and add nothing.
        try task.run()

        if let stdin {
            // `write(_:)` raises an Objective-C exception on a broken pipe,
            // which Swift cannot catch. The throwing form turns it into an
            // error, and the child's own stderr is the better explanation.
            try? inPipe.fileHandleForWriting.write(contentsOf: Data(stdin))
        }
        try? inPipe.fileHandleForWriting.close()

        // The deadline has to be able to reach a child that has stopped saying
        // anything. `readDataToEndOfFile` below blocks until the child closes
        // stdout, so a poll loop after it would never get its turn: a child
        // that hangs without writing would wedge this thread for good. Killing
        // the child is what makes the read return.
        let started = Date()
        let watchdog = DispatchWorkItem { if task.isRunning { task.terminate() } }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout,
                                                      execute: watchdog)

        // Read both pipes concurrently, so a chatty stderr cannot block stdout.
        var errData = Data()
        let errDone = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            errData = errPipe.fileHandleForReading.readDataToEndOfFile()
            errDone.signal()
        }
        let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
        errDone.wait()

        task.waitUntilExit()
        // A child killed by a signal before the deadline crashed; one killed at
        // or after it was killed here. The distinction only changes the message,
        // but the wrong message sends somebody looking in the wrong place.
        let timedOut = task.terminationReason == .uncaughtSignal
                    && Date().timeIntervalSince(started) >= timeout
        watchdog.cancel()
        if timedOut {
            throw VaultError("\(URL(fileURLWithPath: path).lastPathComponent) "
                             + "did not answer in \(Int(timeout))s.")
        }

        return Result(status: task.terminationStatus, out: outData,
                      err: String(decoding: errData, as: UTF8.self)
                            .trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// The first of `candidates` that exists and can be run, or nil. Used to
    /// find `op` and `keepassxc-cli` without asking the user where they are:
    /// a GUI app inherits no PATH worth the name, so the search is a list of
    /// the three places these two actually land.
    static func locate(_ candidates: [String]) -> String? {
        candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }
}
