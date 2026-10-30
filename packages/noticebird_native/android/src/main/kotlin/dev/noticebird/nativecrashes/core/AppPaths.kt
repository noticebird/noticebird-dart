package dev.noticebird.nativecrashes.core

/**
 * Decides whether a native image belongs to the app: its file lies in the
 * app's install directory (`/data/app/…/<packageName>-…/`, of this install
 * or an earlier one — the directory name is random per install) or in its
 * data directory, or under one of the current install's own [directories].
 */
internal class AppPaths(packageName: String, directories: List<String>) {
    private val prefixes = directories
        .filter { it.startsWith("/") && it.length > 1 }
        .map { if (it.endsWith("/")) it else "$it/" }

    private val patterns: List<Regex> = Regex.escape(packageName).let { name ->
        listOf(
            Regex("^/data/app/(?:[^/]+/)?$name-[^/]+/"),
            Regex("^/mnt/expand/[^/]+/app/(?:[^/]+/)?$name-[^/]+/"),
            Regex("^/data/data/$name/"),
            Regex("^/data/user(?:_de)?/\\d+/$name/"),
            Regex("^/mnt/expand/[^/]+/user(?:_de)?/\\d+/$name/"),
        )
    }

    fun isInApp(path: String): Boolean {
        val file = Sanitize.stripDeleted(path)
        return prefixes.any { file.startsWith(it) } || patterns.any { it.containsMatchIn(file) }
    }
}
