package dev.noticebird.nativecrashes.core

import java.nio.ByteBuffer
import java.nio.charset.CharacterCodingException
import java.nio.charset.CodingErrorAction

/**
 * A bounded reader for the protobuf wire format, over one message in
 * [buffer] between [start] and [end]. It knows no schema: the caller asks
 * for the next field and either reads it with the accessor its wire type
 * demands or skips it. Anything malformed — a truncated field, a varint of
 * more than 10 bytes or beyond 64 bits, a length past the message's end,
 * a group or an unknown wire type, field number 0, nesting deeper than
 * [MAX_DEPTH] — throws [MalformedProtobufException].
 */
internal class ProtoReader private constructor(
    private val buffer: ByteArray,
    start: Int,
    private val end: Int,
    private val depth: Int,
) {
    private var position = start

    /** The field number of the field [nextField] just read. */
    var fieldNumber = 0
        private set

    /** The wire type of the field [nextField] just read. */
    var wireType = 0
        private set

    /** Reads the next field's tag; false at the end of the message. */
    fun nextField(): Boolean {
        if (position >= end) return false
        val tag = readRawVarint()
        if (tag < 0 || tag > 0xFFFFFFFFL) throw MalformedProtobufException("tag out of range")
        wireType = (tag and 0x7).toInt()
        val number = tag ushr 3
        if (number == 0L || number > MAX_FIELD_NUMBER) throw MalformedProtobufException("field number $number")
        fieldNumber = number.toInt()
        if (wireType != VARINT && wireType != FIXED64 && wireType != LENGTH_DELIMITED && wireType != FIXED32) {
            throw MalformedProtobufException("wire type $wireType")
        }
        return true
    }

    /** The current field as a varint (the raw 64 bits, as protobuf sign-extends `int32`). */
    fun varint(): Long {
        expectWireType(VARINT)
        return readRawVarint()
    }

    /** The current length-delimited field as a nested message. */
    fun message(): ProtoReader {
        expectWireType(LENGTH_DELIMITED)
        if (depth + 1 > MAX_DEPTH) throw MalformedProtobufException("nesting too deep")
        val length = readLength()
        val reader = ProtoReader(buffer, position, position + length, depth + 1)
        position += length
        return reader
    }

    /** The current length-delimited field as strictly valid UTF-8. */
    fun string(): String {
        expectWireType(LENGTH_DELIMITED)
        val length = readLength()
        val decoder = Charsets.UTF_8.newDecoder()
            .onMalformedInput(CodingErrorAction.REPORT)
            .onUnmappableCharacter(CodingErrorAction.REPORT)
        val text = try {
            decoder.decode(ByteBuffer.wrap(buffer, position, length)).toString()
        } catch (error: CharacterCodingException) {
            throw MalformedProtobufException("invalid UTF-8")
        }
        position += length
        return text
    }

    /** Skips the current field by its wire type. */
    fun skip() {
        when (wireType) {
            VARINT -> readRawVarint()
            FIXED64 -> advance(8)
            FIXED32 -> advance(4)
            LENGTH_DELIMITED -> advance(readLength())
            else -> throw MalformedProtobufException("wire type $wireType")
        }
    }

    private fun expectWireType(expected: Int) {
        if (wireType != expected) {
            throw MalformedProtobufException("field $fieldNumber: wire type $wireType, expected $expected")
        }
    }

    private fun readLength(): Int {
        val length = readRawVarint()
        if (length < 0 || length > end - position) throw MalformedProtobufException("length $length")
        return length.toInt()
    }

    private fun advance(count: Int) {
        if (count > end - position) throw MalformedProtobufException("truncated")
        position += count
    }

    private fun readRawVarint(): Long {
        var result = 0L
        var shift = 0
        while (true) {
            if (position >= end) throw MalformedProtobufException("truncated varint")
            val byte = buffer[position++].toInt() and 0xff
            if (shift == 63 && byte > 1) throw MalformedProtobufException("varint overflow")
            result = result or ((byte and 0x7f).toLong() shl shift)
            if (byte and 0x80 == 0) return result
            shift += 7
            if (shift > 63) throw MalformedProtobufException("varint longer than 10 bytes")
        }
    }

    companion object {
        const val VARINT = 0
        const val FIXED64 = 1
        const val LENGTH_DELIMITED = 2
        const val FIXED32 = 5

        /** Messages nested deeper than this are rejected. */
        const val MAX_DEPTH = 8

        private const val MAX_FIELD_NUMBER = (1L shl 29) - 1

        /** A reader over the whole of [buffer], the top-level message. */
        fun of(buffer: ByteArray, length: Int = buffer.size): ProtoReader {
            require(length in 0..buffer.size)
            return ProtoReader(buffer, 0, length, 0)
        }
    }
}

internal class MalformedProtobufException(message: String) : Exception(message)
