import Foundation
import NIOCore

enum RedisRESPCodec {
    static let maximumReplyBytes = 32 * 1_024 * 1_024
    static let maximumElements = 100_000

    static func encode(_ arguments: [Data], allocator: ByteBufferAllocator = .init()) throws -> ByteBuffer {
        guard !arguments.isEmpty, arguments.count <= 4_096,
              arguments.reduce(0, { $0 + $1.count }) <= RedisCommandService.maximumCommandBytes else { throw RedisClientError.invalidCommand }
        var buffer = allocator.buffer(capacity: arguments.reduce(64, { $0 + $1.count + 24 }))
        buffer.writeString("*\(arguments.count)\r\n")
        for argument in arguments {
            buffer.writeString("$\(argument.count)\r\n")
            buffer.writeBytes(argument)
            buffer.writeString("\r\n")
        }
        return buffer
    }
}

// Consume container headers once, retaining partial-array state between network reads.
// Large fragmented arrays must not cause quadratic reparsing or repeated allocations.
struct RedisRESPParser {
    private struct Frame {
        var remaining: Int
        var values: [RedisReply]
    }
    private var stack: [Frame] = []
    private var pendingBulk: Int?
    private var frameBytes = 0
    private var declaredElements = 0

    mutating func next(from buffer: inout ByteBuffer) throws -> RedisReply? {
        while true {
            if let length = pendingBulk {
                guard buffer.readableBytes >= length + 2 else {
                    guard frameBytes + buffer.readableBytes <= RedisRESPCodec.maximumReplyBytes else { throw RedisClientError.replyTooLarge }
                    return nil
                }
                guard buffer.getInteger(at: buffer.readerIndex + length, as: UInt8.self) == 13,
                      buffer.getInteger(at: buffer.readerIndex + length + 1, as: UInt8.self) == 10 else { throw RedisClientError.malformedReply }
                let value = Data(buffer.readBytes(length: length)!)
                buffer.moveReaderIndex(forwardBy: 2)
                try account(length + 2)
                pendingBulk = nil
                if let result = finish(.bulk(value)) { return result }
                continue
            }
            guard let prefix: UInt8 = buffer.getInteger(at: buffer.readerIndex) else { return nil }
            guard [43, 45, 58, 36, 42].contains(prefix) else { throw RedisClientError.malformedReply }
            let maximumLine = prefix == 43 || prefix == 45 ? 65_536 : 64
            guard let line = try readLine(from: &buffer, maximum: maximumLine) else { return nil }
            try account(line.count + 3)
            switch prefix {
            case 43:
                if let result = finish(.simple(Data(line))) { return result }
            case 45:
                if let result = finish(.error(Data(line))) { return result }
            case 58:
                guard let value = integer(line) else { throw RedisClientError.malformedReply }
                if let result = finish(.integer(value)) { return result }
            case 36:
                guard let count = integer(line), count >= -1 else { throw RedisClientError.malformedReply }
                if count == -1 {
                    if let result = finish(.bulk(nil)) { return result }
                } else {
                    guard count <= RedisRESPCodec.maximumReplyBytes,
                          frameBytes + Int(count) + 2 <= RedisRESPCodec.maximumReplyBytes else { throw RedisClientError.replyTooLarge }
                    pendingBulk = Int(count)
                }
            case 42:
                guard let count = integer(line), count >= -1 else { throw RedisClientError.malformedReply }
                if count == -1 {
                    if let result = finish(.array(nil)) { return result }
                } else if count == 0 {
                    if let result = finish(.array([])) { return result }
                } else {
                    guard stack.count < 64, count <= RedisRESPCodec.maximumElements,
                          declaredElements + Int(count) <= RedisRESPCodec.maximumElements else { throw RedisClientError.replyTooLarge }
                    declaredElements += Int(count)
                    stack.append(Frame(remaining: Int(count), values: []))
                }
            default: throw RedisClientError.malformedReply
            }
        }
    }

    private mutating func finish(_ value: RedisReply) -> RedisReply? {
        var next = value
        while !stack.isEmpty {
            let index = stack.count - 1
            stack[index].values.append(next)
            stack[index].remaining -= 1
            guard stack[index].remaining == 0 else { return nil }
            next = .array(stack.removeLast().values)
        }
        frameBytes = 0
        declaredElements = 0
        return next
    }

    private mutating func account(_ bytes: Int) throws {
        frameBytes += bytes
        guard frameBytes <= RedisRESPCodec.maximumReplyBytes else { throw RedisClientError.replyTooLarge }
    }

    private func integer(_ bytes: [UInt8]) -> Int64? {
        guard !bytes.isEmpty else { return nil }
        let digits = bytes[0] == 45 || bytes[0] == 43 ? bytes.dropFirst() : bytes[...]
        guard !digits.isEmpty, digits.allSatisfy({ (48...57).contains($0) }) else { return nil }
        return Int64(String(decoding: bytes, as: UTF8.self))
    }

    private func readLine(from buffer: inout ByteBuffer, maximum: Int) throws -> [UInt8]? {
        let start = buffer.readerIndex + 1
        let end = min(buffer.writerIndex, start + maximum + 2)
        var index = start
        while index < end {
            let byte: UInt8 = buffer.getInteger(at: index)!
            if byte == 13 {
                guard index + 1 < buffer.writerIndex else { return nil }
                guard buffer.getInteger(at: index + 1, as: UInt8.self) == 10 else { throw RedisClientError.malformedReply }
                let line = buffer.getBytes(at: start, length: index - start)!
                buffer.moveReaderIndex(to: index + 2)
                return line
            }
            guard byte != 10 else { throw RedisClientError.malformedReply }
            index += 1
        }
        guard buffer.readableBytes <= maximum + 2 else { throw RedisClientError.replyTooLarge }
        return nil
    }
}

struct RedisRESPDecoder: ByteToMessageDecoder {
    typealias InboundOut = RedisReply
    private var parser = RedisRESPParser()

    mutating func decode(context: ChannelHandlerContext, buffer: inout ByteBuffer) throws -> DecodingState {
        guard let reply = try parser.next(from: &buffer) else { return .needMoreData }
        context.fireChannelRead(wrapInboundOut(reply))
        return .continue
    }
}
