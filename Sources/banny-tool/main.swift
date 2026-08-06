import Foundation
import BannyCLI

do {
    exit(try await runCLI(arguments: CommandLine.arguments))
} catch {
    writeCLIError(error, json: CommandLine.arguments.contains("--json"))
    exit(cliExitCode(for: error))
}
