import Foundation

/// The one mutex. 🔐
///
/// Sesam has exactly two threads that matter: the main one, which draws the
/// menu and the panel, and a background one, which runs the subprocesses. They
/// meet at the sources, whose fields are written while an index is running and
/// read the moment somebody opens the menu.
///
/// The rule this type exists to make cheap: **a lock is held around a field,
/// never around a subprocess.** Every critical section here is a dictionary
/// swap or a count read, measured in microseconds, so the main thread never
/// waits on anything slow. A lock taken for the whole of `keepassxc-cli export`
/// would freeze the menu bar for a second and a half, which is how a mutex
/// turns into a hang.
final class Lock {

    private let mutex = NSLock()

    func around<T>(_ body: () throws -> T) rethrows -> T {
        mutex.lock()
        defer { mutex.unlock() }
        return try body()
    }
}
