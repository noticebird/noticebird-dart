/// Names of the numbers MetricKit reports, from the Darwin headers. A number
/// outside a table is dropped, never guessed.
enum DarwinTables {
    /// `<mach/exception_types.h>`
    static let machExceptions: [Int64: String] = [
        1: "EXC_BAD_ACCESS",
        2: "EXC_BAD_INSTRUCTION",
        3: "EXC_ARITHMETIC",
        4: "EXC_EMULATION",
        5: "EXC_SOFTWARE",
        6: "EXC_BREAKPOINT",
        7: "EXC_SYSCALL",
        8: "EXC_MACH_SYSCALL",
        9: "EXC_RPC_ALERT",
        10: "EXC_CRASH",
        11: "EXC_RESOURCE",
        12: "EXC_GUARD",
        13: "EXC_CORPSE_NOTIFY",
    ]

    /// `<sys/signal.h>` (Darwin numbering, which differs from Linux).
    static let signals: [Int64: String] = [
        1: "SIGHUP",
        2: "SIGINT",
        3: "SIGQUIT",
        4: "SIGILL",
        5: "SIGTRAP",
        6: "SIGABRT",
        7: "SIGEMT",
        8: "SIGFPE",
        9: "SIGKILL",
        10: "SIGBUS",
        11: "SIGSEGV",
        12: "SIGSYS",
        13: "SIGPIPE",
        14: "SIGALRM",
        15: "SIGTERM",
        16: "SIGURG",
        17: "SIGSTOP",
        18: "SIGTSTP",
        19: "SIGCONT",
        20: "SIGCHLD",
        21: "SIGTTIN",
        22: "SIGTTOU",
        23: "SIGIO",
        24: "SIGXCPU",
        25: "SIGXFSZ",
        26: "SIGVTALRM",
        27: "SIGPROF",
        28: "SIGWINCH",
        29: "SIGINFO",
        30: "SIGUSR1",
        31: "SIGUSR2",
    ]

    /// The watchdog's termination code ("ate bad food").
    static let watchdogTerminationCode = "0x8badf00d"
}
