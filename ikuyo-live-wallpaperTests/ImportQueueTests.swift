import Testing
import Foundation
@testable import StarTorch_Wallpaper_Engine

@MainActor
@Suite("ImportQueue")
struct ImportQueueTests {
    @Test("Starts empty")
    func startsEmpty() {
        let queue = ImportQueue()
        #expect(queue.isEmpty)
        #expect(queue.current == nil)
        #expect(queue.remainingCount == 0)
    }

    @Test("Enqueuing multiple URLs shows the first and counts the rest")
    func enqueueMultiple() {
        var queue = ImportQueue()
        let urls = [
            URL(fileURLWithPath: "/tmp/a.mp4"),
            URL(fileURLWithPath: "/tmp/b.mp4"),
            URL(fileURLWithPath: "/tmp/c.mp4"),
        ]
        queue.enqueue(urls)
        #expect(!queue.isEmpty)
        #expect(queue.current?.url == urls[0])
        #expect(queue.remainingCount == 2)
    }

    @Test("Advancing walks through the queue one at a time, in order")
    func advanceInOrder() {
        var queue = ImportQueue()
        let urls = [
            URL(fileURLWithPath: "/tmp/a.mp4"),
            URL(fileURLWithPath: "/tmp/b.mp4"),
        ]
        queue.enqueue(urls)

        #expect(queue.current?.url == urls[0])
        queue.advance()
        #expect(queue.current?.url == urls[1])
        #expect(queue.remainingCount == 0)
        queue.advance()
        #expect(queue.isEmpty)
        #expect(queue.current == nil)
    }

    @Test("Advancing an empty queue is a no-op")
    func advanceEmpty() {
        var queue = ImportQueue()
        queue.advance()
        #expect(queue.isEmpty)
    }

    @Test("A later enqueue appends behind what's already pending")
    func enqueueAppends() {
        var queue = ImportQueue()
        queue.enqueue([URL(fileURLWithPath: "/tmp/a.mp4")])
        queue.enqueue([URL(fileURLWithPath: "/tmp/b.mp4"), URL(fileURLWithPath: "/tmp/c.mp4")])
        #expect(queue.pending.map(\.url.lastPathComponent) == ["a.mp4", "b.mp4", "c.mp4"])
    }
}
