import Foundation

/// The small print. 🛡️
///
/// A few lines that run before anything else, each of which closes a way a
/// password could leave this process without anybody asking it to, or a way a
/// child process could take Sesam down with it.
///
/// **No core dumps.** A crash writes the process's memory to disk, and while
/// Sesam is unlocked that memory contains the decrypted contents of a KeePassXC
/// database. `RLIMIT_CORE` at zero means the kernel writes nothing.
///
/// **A debugger is not kept out, and that is worth stating correctly.** An
/// earlier version of this comment said `PT_DENY_ATTACH` was left out because
/// it stops nothing that root cannot undo. That reasoning holds for a binary
/// signed with a Developer ID and the hardened runtime, where attaching already
/// needs an entitlement. Sesam is ad-hoc signed and has neither, so a process
/// running as this user can attach to it and read the unlocked vault straight
/// out of memory, no root required, and every byte buffer in this project is
/// beside the point against that.
///
/// It is still not called here, for two reasons that are about honesty rather
/// than security: `PT_DENY_ATTACH` is bypassable by the same attacker it aims
/// at, and it would have prevented the `sample` that diagnosed a real report
/// from the owner of this Mac. The real fix is a Developer ID signature with
/// the hardened runtime, which a build-from-source project does not have. Until
/// then, "a process running as you wins" is a documented property of Sesam and
/// not something a line here quietly papers over.
///
/// **No accidental logging.** There is no logging. The one place a password
/// could be printed by mistake is `print` in a debug build, and the way that is
/// prevented is that no code path formats a `Secret` into a string except
/// `withString`, which every caller has to write out loud.
enum Hardening {

    static func apply() {
        var limit = rlimit(rlim_cur: 0, rlim_max: 0)
        setrlimit(RLIMIT_CORE, &limit)
        // Writing the master password to a child that has already exited (a
        // bad key file, a moved database) raises SIGPIPE, whose default action
        // ends the whole menu bar app. Ignored, the write fails with EPIPE and
        // `Shell.run` reports what the child said on stderr instead.
        signal(SIGPIPE, SIG_IGN)
    }
}
