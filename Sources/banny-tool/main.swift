import Foundation
import BannyCLI

do {
    exit(try await runCLI(arguments: CommandLine.arguments))
} catch {
    FileHandle.standardError.write(Data(("\(error)\n").utf8))
    exit(1)
}
