import Foundation
import GhosttyKit
@testable import GhosttyTerminal
import Testing

struct TerminalClipboardCompletionPayloadTests {
    @Test
    func `completion copies binary and empty representations with MIME lists`() {
        let binary = Data([0, 0xff, 0x61, 0])
        let contents = [
            TerminalClipboardContent(mime: "application/octet-stream", data: binary),
            TerminalClipboardContent(mime: "text/plain", data: Data()),
        ]
        let copied = withClipboardCompletePayload(
            contents: contents,
            available: ["text/plain", "application/octet-stream"],
            confirmed: true,
            remember: false,
        ) { pointer -> ([String], [Data], [String]) in
            let raw = pointer.pointee
            guard raw.contents_len == 2, let representations = raw.contents,
                  raw.available_len == 2, let available = raw.available
            else {
                Issue.record("Missing clipboard representations or MIME list")
                return ([], [], [])
            }
            var mimes: [String] = []
            var buffers: [Data] = []
            var advertised: [String] = []
            for index in 0 ..< 2 {
                let mime: UnsafePointer<CChar>? = representations[index].mime
                let bytes: UnsafePointer<CChar>? = representations[index].data
                let offered: UnsafePointer<CChar>? = available[index]
                guard let mime, let bytes, let offered else {
                    Issue.record("Missing owned C string or data buffer")
                    return ([], [], [])
                }
                mimes.append(String(cString: mime))
                buffers.append(Data(bytes: bytes, count: representations[index].len))
                advertised.append(String(cString: offered))
            }
            #expect(raw.confirmed && !raw.remember)
            return (mimes, buffers, advertised)
        }

        #expect(copied.0 == ["application/octet-stream", "text/plain"])
        #expect(copied.1 == [binary, Data()])
        #expect(copied.2 == ["text/plain", "application/octet-stream"])
        withClipboardCompletePayload(contents: [], available: [], confirmed: false, remember: true) { pointer in
            #expect(pointer.pointee.contents_len == 0)
            #expect(pointer.pointee.available_len == 0)
            #expect(!pointer.pointee.confirmed && pointer.pointee.remember)
        }
    }
}
