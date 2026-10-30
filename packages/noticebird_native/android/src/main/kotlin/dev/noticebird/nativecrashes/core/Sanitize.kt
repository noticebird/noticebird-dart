package dev.noticebird.nativecrashes.core

/**
 * Turns raw OS strings into values the contract allows: every character
 * outside a field's alphabet becomes `_` (one per code point), then the
 * value is cut to the field's length. An empty result is no value.
 */
internal object Sanitize {
    fun symbol(raw: String?): String? =
        replaceAndCut(raw, RecordRules.MAX_SYMBOL_LENGTH) { it.isAsciiAlphanumeric() || it in "_$.<>:~" }

    fun exceptionClass(raw: String?): String? =
        replaceAndCut(raw, RecordRules.MAX_EXCEPTION_CLASS_LENGTH) { it.isAsciiAlphanumeric() || it in "_$." }

    /**
     * An image's name from its path: the basename, and for an ELF embedded in
     * an APK (`…/base.apk!libapp.so`) the embedded file's name.
     */
    fun imageName(path: String): String? {
        val base = stripDeleted(path).substringAfterLast('/').substringAfterLast('!')
        return replaceAndCut(base, RecordRules.MAX_IMAGE_NAME_LENGTH) { it.isAsciiAlphanumeric() || it in "_.+-" }
    }

    /** The path without the kernel's ` (deleted)` suffix of an unlinked mapping. */
    fun stripDeleted(path: String): String = path.removeSuffix(" (deleted)")

    /** A message cut to the contract's length without splitting a surrogate pair. */
    fun message(raw: String?): String? {
        if (raw.isNullOrEmpty()) return null
        if (raw.length <= RecordRules.MAX_MESSAGE_LENGTH) return raw
        var end = RecordRules.MAX_MESSAGE_LENGTH
        if (Character.isHighSurrogate(raw[end - 1])) end--
        return raw.substring(0, end).ifEmpty { null }
    }

    private inline fun replaceAndCut(raw: String?, maxLength: Int, allowed: (Char) -> Boolean): String? {
        if (raw.isNullOrEmpty()) return null
        val out = StringBuilder(minOf(raw.length, maxLength))
        var index = 0
        while (index < raw.length && out.length < maxLength) {
            val char = raw[index]
            if (Character.isHighSurrogate(char) && index + 1 < raw.length && Character.isLowSurrogate(raw[index + 1])) {
                out.append('_')
                index += 2
                continue
            }
            out.append(if (allowed(char)) char else '_')
            index++
        }
        return out.toString().ifEmpty { null }
    }

    private fun Char.isAsciiAlphanumeric() = this in 'a'..'z' || this in 'A'..'Z' || this in '0'..'9'
}

/** Linux signal names by number (arm, arm64, x86, x86_64 share them). */
internal object SignalNames {
    private val names = arrayOf(
        null, "SIGHUP", "SIGINT", "SIGQUIT", "SIGILL", "SIGTRAP", "SIGABRT", "SIGBUS", "SIGFPE", "SIGKILL",
        "SIGUSR1", "SIGSEGV", "SIGUSR2", "SIGPIPE", "SIGALRM", "SIGTERM", "SIGSTKFLT", "SIGCHLD", "SIGCONT",
        "SIGSTOP", "SIGTSTP", "SIGTTIN", "SIGTTOU", "SIGURG", "SIGXCPU", "SIGXFSZ", "SIGVTALRM", "SIGPROF",
        "SIGWINCH", "SIGIO", "SIGPWR", "SIGSYS",
    )

    fun of(number: Int): String? = names.getOrNull(number)

    /** The name the tombstone gives when it is a well-formed one, else the table's. */
    fun resolve(number: Int?, name: String?): String? =
        name?.takeIf { RecordRules.SIGNAL.matches(it) } ?: number?.let { of(it) }
}

/** The lowercase hex of a code's unsigned 64-bit value: `0x32`, `0xfffffffffffffffa`. */
internal fun hexCode(value: Long): String = "0x" + java.lang.Long.toHexString(value)
