import Foundation
@testable import GhosttyTerminal
import Testing

struct InMemoryTerminalPendingOperationsTests {
    @Test
    func `entries come out in order across compactions`() {
        var queue = InMemoryTerminalPendingOperations()
        var expected = 0
        for value in 0 ..< 5000 {
            queue.append(.write(Data("\(value)".utf8)))
            if value % 3 == 0 {
                #expect(text(queue.popFirst()) == "\(expected)")
                expected += 1
            }
        }
        while let operation = queue.popFirst() {
            #expect(text(operation) == "\(expected)")
            expected += 1
        }
        #expect(expected == 5000)
        #expect(queue.isEmpty)
        #expect(queue.writeByteCount == 0)
    }

    @Test
    func `coalescing joins only consecutive writes`() {
        var queue = InMemoryTerminalPendingOperations()
        queue.appendCoalescing(Data("a".utf8))
        queue.appendCoalescing(Data("b".utf8))
        queue.append(.processExit(exitCode: 1, runtimeMilliseconds: 0))
        queue.appendCoalescing(Data("c".utf8))

        #expect(queue.count == 3)
        #expect(queue.writeByteCount == 3)
        #expect(text(queue.popFirst()) == "ab")
        #expect(text(queue.popFirst()) == "exit:1")
        #expect(text(queue.popFirst()) == "c")
        #expect(queue.popFirst() == nil)
    }

    @Test
    func `trimming drops the oldest bytes and keeps exits`() {
        var queue = InMemoryTerminalPendingOperations()
        queue.append(.write(Data("0123".utf8)))
        queue.append(.processExit(exitCode: 2, runtimeMilliseconds: 0))
        queue.append(.write(Data("4567".utf8)))
        queue.append(.write(Data("89".utf8)))

        queue.trimWrites(toLimit: 3)

        #expect(queue.writeByteCount == 3)
        #expect(queue.count == 3)
        #expect(text(queue.popFirst()) == "exit:2")
        #expect(text(queue.popFirst()) == "7")
        #expect(text(queue.popFirst()) == "89")
        #expect(queue.isEmpty)
    }

    private func text(_ operation: InMemoryTerminalPendingOperations.Operation?) -> String? {
        switch operation {
        case let .write(data)?:
            String(decoding: data, as: UTF8.self)
        case let .processExit(exitCode, _)?:
            "exit:\(exitCode)"
        case nil:
            nil
        }
    }
}
