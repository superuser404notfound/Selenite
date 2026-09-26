import Foundation

public enum NvError: Error, Equatable {
    case malformed
    case status(Int, String)
}

/// A GameStream XML reply: `<root status_code=".." status_message="..">` with flat child
/// elements, plus repeated `<App>` blocks in /applist.
public struct NvResponse: Sendable {
    public let statusCode: Int
    public let statusMessage: String
    public let fields: [String: String]
    public let apps: [[String: String]]

    public subscript(_ key: String) -> String? { fields[key] }

    public func requireOK() throws -> NvResponse {
        guard statusCode == 200 else { throw NvError.status(statusCode, statusMessage) }
        return self
    }

    public static func parse(_ data: Data) throws -> NvResponse {
        let delegate = Delegate()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        guard parser.parse(), let status = delegate.statusCode else { throw NvError.malformed }
        return NvResponse(statusCode: status, statusMessage: delegate.statusMessage,
                          fields: delegate.fields, apps: delegate.apps)
    }

    private final class Delegate: NSObject, XMLParserDelegate {
        var statusCode: Int?
        var statusMessage = ""
        var fields: [String: String] = [:]
        var apps: [[String: String]] = []
        private var path: [String] = []
        private var text = ""
        private var currentApp: [String: String]?

        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?,
                    qualifiedName: String?, attributes: [String: String]) {
            if path.isEmpty, name == "root" {
                statusCode = attributes["status_code"].flatMap(Int.init)
                statusMessage = attributes["status_message"] ?? ""
            }
            if name == "App" { currentApp = [:] }
            path.append(name)
            text = ""
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            text += string
        }

        func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
            path.removeLast()
            let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if name == "App", let app = currentApp {
                apps.append(app)
                currentApp = nil
            } else if currentApp != nil {
                currentApp?[name] = value
            } else if path.count == 1 {
                fields[name] = value
            }
            text = ""
        }
    }
}
