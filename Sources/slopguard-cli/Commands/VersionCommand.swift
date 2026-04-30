import Foundation
import ArgumentParser
import SlopguardCore

struct VersionCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "version",
        abstract: "Print version metadata as JSON."
    )

    func run() throws {
        let payload = VersionPayload(
            name: SlopguardVersion.toolName,
            version: SlopguardVersion.version,
            mcpProtocol: SlopguardVersion.mcpProtocolVersion
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(payload)
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write(Data([0x0A]))
    }

    private struct VersionPayload: Codable {
        let name: String
        let version: String
        let mcpProtocol: String
    }
}
