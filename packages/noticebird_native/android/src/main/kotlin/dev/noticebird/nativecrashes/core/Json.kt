package dev.noticebird.nativecrashes.core

/**
 * The minimal JSON this collector needs for its own files (the native contract):
 * objects, arrays, strings, booleans and integers. No floating point, no
 * `null` values — the contract omits unknown keys instead.
 *
 * [write] is canonical: object keys sorted at every depth (by UTF-16 code
 * unit, as Dart's `String.compareTo`), no whitespace. That form is also the
 * input of the record id.
 */
internal object Json {
    /** Nesting deeper than this is rejected by [parse]. */
    const val MAX_DEPTH = 16

    fun write(value: Any): String = StringBuilder().also { writeValue(it, value) }.toString()

    private fun writeValue(out: StringBuilder, value: Any) {
        when (value) {
            is String -> writeString(out, value)
            is Boolean -> out.append(if (value) "true" else "false")
            is Int -> out.append(value)
            is Long -> out.append(value)
            is Map<*, *> -> {
                out.append('{')
                val keys = value.keys.map { it as String }.sorted()
                keys.forEachIndexed { index, key ->
                    if (index > 0) out.append(',')
                    writeString(out, key)
                    out.append(':')
                    writeValue(out, requireNotNull(value[key]) { "null value for $key" })
                }
                out.append('}')
            }
            is List<*> -> {
                out.append('[')
                value.forEachIndexed { index, element ->
                    if (index > 0) out.append(',')
                    writeValue(out, requireNotNull(element) { "null element" })
                }
                out.append(']')
            }
            else -> throw IllegalArgumentException("Unsupported JSON value ${value::class.java.name}")
        }
    }

    /** Escapes like Dart's `jsonEncode`: quotes, backslashes, controls, lone surrogates. */
    private fun writeString(out: StringBuilder, value: String) {
        out.append('"')
        var index = 0
        while (index < value.length) {
            val char = value[index]
            when {
                char == '"' -> out.append("\\\"")
                char == '\\' -> out.append("\\\\")
                char == '\b' -> out.append("\\b")
                char == '\u000C' -> out.append("\\f")
                char == '\n' -> out.append("\\n")
                char == '\r' -> out.append("\\r")
                char == '\t' -> out.append("\\t")
                char < ' ' -> out.append(unicodeEscape(char))
                Character.isHighSurrogate(char) &&
                    index + 1 < value.length &&
                    Character.isLowSurrogate(value[index + 1]) -> {
                    out.append(char).append(value[index + 1])
                    index++
                }
                Character.isSurrogate(char) -> out.append(unicodeEscape(char))
                else -> out.append(char)
            }
            index++
        }
        out.append('"')
    }

    private fun unicodeEscape(char: Char): String = "\\u" + char.code.toString(16).padStart(4, '0')

    /**
     * Parses [text], throwing [JsonFormatException] on anything outside the
     * subset above, on duplicate keys and on nesting deeper than [MAX_DEPTH].
     * Objects become `Map<String, Any>`, arrays `List<Any>`, integers `Long`.
     */
    fun parse(text: String): Any {
        val parser = Parser(text)
        val value = parser.readValue(depth = 0)
        parser.skipWhitespace()
        if (!parser.atEnd()) throw JsonFormatException("Trailing characters")
        return value
    }

    private class Parser(private val text: String) {
        private var index = 0

        fun atEnd() = index >= text.length

        fun skipWhitespace() {
            while (index < text.length && text[index].let { it == ' ' || it == '\n' || it == '\r' || it == '\t' }) {
                index++
            }
        }

        fun readValue(depth: Int): Any {
            if (depth > MAX_DEPTH) throw JsonFormatException("Nesting too deep")
            skipWhitespace()
            if (atEnd()) throw JsonFormatException("Unexpected end")
            return when (val char = text[index]) {
                '{' -> readObject(depth)
                '[' -> readArray(depth)
                '"' -> readString()
                't' -> readLiteral("true", true)
                'f' -> readLiteral("false", false)
                else -> if (char == '-' || char in '0'..'9') readInteger() else throw JsonFormatException("Unexpected '$char'")
            }
        }

        private fun readObject(depth: Int): Map<String, Any> {
            index++
            val result = LinkedHashMap<String, Any>()
            skipWhitespace()
            if (peek() == '}') {
                index++
                return result
            }
            while (true) {
                skipWhitespace()
                if (peek() != '"') throw JsonFormatException("Expected a key")
                val key = readString()
                skipWhitespace()
                expect(':')
                if (result.put(key, readValue(depth + 1)) != null) throw JsonFormatException("Duplicate key")
                skipWhitespace()
                when (peek()) {
                    ',' -> index++
                    '}' -> {
                        index++
                        return result
                    }
                    else -> throw JsonFormatException("Expected ',' or '}'")
                }
            }
        }

        private fun readArray(depth: Int): List<Any> {
            index++
            val result = ArrayList<Any>()
            skipWhitespace()
            if (peek() == ']') {
                index++
                return result
            }
            while (true) {
                result.add(readValue(depth + 1))
                skipWhitespace()
                when (peek()) {
                    ',' -> index++
                    ']' -> {
                        index++
                        return result
                    }
                    else -> throw JsonFormatException("Expected ',' or ']'")
                }
            }
        }

        private fun readString(): String {
            index++
            val out = StringBuilder()
            while (true) {
                if (atEnd()) throw JsonFormatException("Unterminated string")
                val char = text[index++]
                when {
                    char == '"' -> return out.toString()
                    char == '\\' -> {
                        if (atEnd()) throw JsonFormatException("Unterminated escape")
                        when (val escaped = text[index++]) {
                            '"', '\\', '/' -> out.append(escaped)
                            'b' -> out.append('\b')
                            'f' -> out.append('\u000C')
                            'n' -> out.append('\n')
                            'r' -> out.append('\r')
                            't' -> out.append('\t')
                            'u' -> {
                                if (index + 4 > text.length) throw JsonFormatException("Short unicode escape")
                                val code = text.substring(index, index + 4).toIntOrNull(16)
                                    ?: throw JsonFormatException("Bad unicode escape")
                                out.append(code.toChar())
                                index += 4
                            }
                            else -> throw JsonFormatException("Bad escape")
                        }
                    }
                    char < ' ' -> throw JsonFormatException("Control character in string")
                    else -> out.append(char)
                }
            }
        }

        private fun readInteger(): Long {
            val start = index
            if (peek() == '-') index++
            val digitsStart = index
            while (index < text.length && text[index] in '0'..'9') index++
            val digits = index - digitsStart
            if (digits == 0) throw JsonFormatException("Expected digits")
            if (digits > 1 && text[digitsStart] == '0') throw JsonFormatException("Leading zero")
            if (index < text.length && text[index].let { it == '.' || it == 'e' || it == 'E' }) {
                throw JsonFormatException("Only integers are supported")
            }
            return text.substring(start, index).toLongOrNull() ?: throw JsonFormatException("Integer out of range")
        }

        private fun readLiteral(literal: String, value: Boolean): Boolean {
            if (!text.startsWith(literal, index)) throw JsonFormatException("Bad literal")
            index += literal.length
            return value
        }

        private fun peek(): Char? = if (atEnd()) null else text[index]

        private fun expect(char: Char) {
            if (peek() != char) throw JsonFormatException("Expected '$char'")
            index++
        }
    }
}

internal class JsonFormatException(message: String) : Exception(message)
