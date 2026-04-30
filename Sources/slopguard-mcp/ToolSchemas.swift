import Foundation

/// JSON Schema literals for slopguard's MCP tool inputs. We hand-author these as
/// `JSONValue` literals so they round-trip cleanly through the encoder and stay
/// human-readable for agents that look at the `tools/list` response.
enum ToolSchemas {

    static var analyzeDirectory: JSONValue {
        [
            "type": "object",
            "properties": [
                "path": [
                    "type": "string",
                    "description": "Absolute or relative path to a directory of Swift sources to analyze."
                ],
                "threshold": [
                    "type": "number",
                    "default": 30,
                    "description": "CRAP score above which a method or class is flagged as crappy."
                ],
                "scheme": [
                    "type": "string",
                    "description": "Optional override for the xcodebuild scheme used to gather coverage. Auto-discovered when omitted."
                ],
                "destination": [
                    "type": "string",
                    "default": "platform=macOS",
                    "description": "xcodebuild destination string."
                ],
                "include": [
                    "type": "array",
                    "items": ["type": "string"],
                    "description": "Optional list of fnmatch globs (e.g. `**/Foo/**/*.swift`) — only matching files are analyzed."
                ],
                "exclude": [
                    "type": "array",
                    "items": ["type": "string"],
                    "description": "Extra fnmatch globs to skip. Combined with the built-in defaults (.build, Pods, Carthage, Generated, *Tests, *Spec, etc.) unless `noDefaultExcludes` is true."
                ],
                "noDefaultExcludes": [
                    "type": "boolean",
                    "default": false,
                    "description": "Skip the built-in default excludes (so you can analyze test code or take total manual control of the exclude list)."
                ]
            ],
            "required": ["path"]
        ]
    }

    static var analyzeFile: JSONValue {
        [
            "type": "object",
            "properties": [
                "path": [
                    "type": "string",
                    "description": "Absolute or relative path to a single .swift file."
                ],
                "threshold": [
                    "type": "number",
                    "default": 30
                ],
                "scheme": [
                    "type": "string",
                    "description": "Optional xcodebuild scheme override. Auto-discovered when omitted."
                ],
                "destination": [
                    "type": "string",
                    "default": "platform=macOS",
                    "description": "xcodebuild destination string."
                ]
            ],
            "required": ["path"]
        ]
    }

    static var getCrapReport: JSONValue {
        [
            "type": "object",
            "properties": [
                "filterFile": [
                    "type": "string",
                    "description": "Substring match against MethodCrap.file — keep entries whose file path contains this string."
                ],
                "filterClass": [
                    "type": "string",
                    "description": "Exact match against MethodCrap.typeName / TypeCrap.name."
                ],
                "filterMethod": [
                    "type": "string",
                    "description": "Substring match against MethodCrap.qualifiedName."
                ],
                "threshold": [
                    "type": "number",
                    "description": "Override the default crappy-threshold for the response (does not re-analyze)."
                ],
                "limit": [
                    "type": "integer",
                    "default": 100,
                    "description": "Cap on returned methods to keep agent context small. The full report is preserved server-side."
                ]
            ]
        ]
    }

    static var findCrappyCode: JSONValue {
        [
            "type": "object",
            "properties": [
                "threshold": [
                    "type": "number",
                    "default": 30,
                    "description": "Lower bound for CRAP — only entries with crap > threshold are returned."
                ],
                "limit": [
                    "type": "integer",
                    "default": 20,
                    "description": "Maximum number of entries to return, sorted by CRAP descending."
                ],
                "level": [
                    "type": "string",
                    "enum": ["method", "class"],
                    "default": "method",
                    "description": "Aggregate level — per-method (the worst offenders) or per-class (the worst types)."
                ]
            ]
        ]
    }

    static var getCoverageGaps: JSONValue {
        [
            "type": "object",
            "properties": [
                "minComplexity": [
                    "type": "integer",
                    "default": 5,
                    "description": "Only consider methods with complexity at or above this value."
                ],
                "maxCoverage": [
                    "type": "number",
                    "default": 50,
                    "description": "Only consider methods with coverage at or below this percentage."
                ],
                "limit": [
                    "type": "integer",
                    "default": 20
                ]
            ]
        ]
    }

    static var suggestRefactor: JSONValue {
        [
            "type": "object",
            "properties": [
                "methodId": [
                    "type": "string",
                    "description": "MethodCrap.id from a prior report (e.g. `Sources/Foo.swift#Foo.bar(_:)@42`)."
                ]
            ],
            "required": ["methodId"]
        ]
    }
}
