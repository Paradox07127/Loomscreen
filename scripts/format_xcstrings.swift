#!/usr/bin/env swift

import Foundation

let usageText = """
Usage:
  swift scripts/format_xcstrings.swift [--check] <file.xcstrings> [...]

Formats .xcstrings files using Foundation's stable JSON style,
matching Xcode's spacing and sorted-key output.
"""

enum FormatError: LocalizedError {
    case usage
    case readFailed(String, Error)
    case parseFailed(String, Error)
    case serializeFailed(String, Error)
    case writeFailed(String, Error)

    var errorDescription: String? {
        switch self {
        case .usage:
            return usageText
        case .readFailed(let path, let error):
            return "Failed to read \(path): \(error.localizedDescription)"
        case .parseFailed(let path, let error):
            return "Failed to parse \(path): \(error.localizedDescription)"
        case .serializeFailed(let path, let error):
            return "Failed to serialize \(path): \(error.localizedDescription)"
        case .writeFailed(let path, let error):
            return "Failed to write \(path): \(error.localizedDescription)"
        }
    }
}

struct Formatter {
    let checkOnly: Bool

    func run(paths: [String]) throws -> Int32 {
        var hasDifferences = false

        for path in paths {
            let url = URL(fileURLWithPath: path)
            let originalData: Data
            do {
                originalData = try Data(contentsOf: url)
            } catch {
                throw FormatError.readFailed(path, error)
            }

            let object: Any
            do {
                object = try JSONSerialization.jsonObject(with: originalData)
            } catch {
                throw FormatError.parseFailed(path, error)
            }

            let formattedData: Data
            do {
                let jsonData = try JSONSerialization.data(
                    withJSONObject: object,
                    options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
                )
                formattedData = jsonData + Data([0x0A])
            } catch {
                throw FormatError.serializeFailed(path, error)
            }

            guard formattedData != originalData else {
                continue
            }

            hasDifferences = true
            if checkOnly {
                print("\(path) is not formatted")
            } else {
                do {
                    try formattedData.write(to: url, options: .atomic)
                    print("formatted \(path)")
                } catch {
                    throw FormatError.writeFailed(path, error)
                }
            }
        }

        return checkOnly && hasDifferences ? 1 : 0
    }
}

func parseArguments(_ args: [String]) throws -> (checkOnly: Bool, paths: [String]) {
    var checkOnly = false
    var paths: [String] = []

    for arg in args {
        switch arg {
        case "--check":
            checkOnly = true
        case "-h", "--help":
            throw FormatError.usage
        default:
            paths.append(arg)
        }
    }

    guard !paths.isEmpty else {
        throw FormatError.usage
    }

    return (checkOnly, paths)
}

do {
    let rawArguments = Array(CommandLine.arguments.dropFirst())
    if rawArguments.contains("-h") || rawArguments.contains("--help") {
        print(usageText)
        exit(0)
    }

    let arguments = try parseArguments(rawArguments)
    let exitCode = try Formatter(checkOnly: arguments.checkOnly).run(paths: arguments.paths)
    exit(exitCode)
} catch {
    if let description = (error as? LocalizedError)?.errorDescription {
        fputs(description + "\n", stderr)
    } else {
        fputs(String(describing: error) + "\n", stderr)
    }
    exit(2)
}
