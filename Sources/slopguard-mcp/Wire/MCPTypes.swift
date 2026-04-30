import Foundation

// MARK: - Tool descriptors

public struct ToolDescriptor: Sendable, Codable {
    public let name: String
    public let title: String?
    public let description: String?
    public let inputSchema: JSONValue
    public let annotations: ToolAnnotations?

    public init(
        name: String,
        title: String? = nil,
        description: String? = nil,
        inputSchema: JSONValue,
        annotations: ToolAnnotations? = nil
    ) {
        self.name = name
        self.title = title
        self.description = description
        self.inputSchema = inputSchema
        self.annotations = annotations
    }

    private enum CodingKeys: String, CodingKey {
        case name, title, description, inputSchema, annotations
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(name, forKey: .name)
        try c.encodeIfPresent(title, forKey: .title)
        try c.encodeIfPresent(description, forKey: .description)
        try c.encode(inputSchema, forKey: .inputSchema)
        try c.encodeIfPresent(annotations, forKey: .annotations)
    }
}

public struct ToolAnnotations: Sendable, Codable {
    public let title: String?
    public let readOnlyHint: Bool?
    public let destructiveHint: Bool?
    public let idempotentHint: Bool?
    public let openWorldHint: Bool?

    public init(
        title: String? = nil,
        readOnlyHint: Bool? = nil,
        destructiveHint: Bool? = nil,
        idempotentHint: Bool? = nil,
        openWorldHint: Bool? = nil
    ) {
        self.title = title
        self.readOnlyHint = readOnlyHint
        self.destructiveHint = destructiveHint
        self.idempotentHint = idempotentHint
        self.openWorldHint = openWorldHint
    }
}

// MARK: - Tool call result

public enum ToolResultContent: Sendable, Codable {
    case text(String)

    private enum CodingKeys: String, CodingKey { case type, text }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let type = try c.decode(String.self, forKey: .type)
        switch type {
        case "text":
            self = .text(try c.decode(String.self, forKey: .text))
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .type, in: c,
                debugDescription: "Unsupported content type '\(type)'"
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .text(let s):
            try c.encode("text", forKey: .type)
            try c.encode(s, forKey: .text)
        }
    }
}

public struct ToolCallResult: Sendable, Codable {
    public let content: [ToolResultContent]
    public let structuredContent: JSONValue?
    public let isError: Bool

    public init(
        content: [ToolResultContent],
        structuredContent: JSONValue? = nil,
        isError: Bool = false
    ) {
        self.content = content
        self.structuredContent = structuredContent
        self.isError = isError
    }

    private enum CodingKeys: String, CodingKey {
        case content, structuredContent, isError
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(content, forKey: .content)
        try c.encodeIfPresent(structuredContent, forKey: .structuredContent)
        try c.encode(isError, forKey: .isError)
    }
}

// MARK: - Server identity

public struct ServerInfo: Sendable, Codable {
    public let name: String
    public let version: String

    public init(name: String, version: String) {
        self.name = name
        self.version = version
    }
}
