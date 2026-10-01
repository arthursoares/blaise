import BlaiseMCPServer
import Foundation

// stdio MCP server: one JSON-RPC message per line. Replies go out with one
// unbuffered write each, so a client waiting in lockstep always gets them.
while let line = readLine(strippingNewline: true) {
    if let reply = handle(line: line) {
        FileHandle.standardOutput.write(Data((reply + "\n").utf8))
    }
}
exit(0)
