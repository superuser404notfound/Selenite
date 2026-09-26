import Foundation

public enum PEM {
    public enum Error: Swift.Error { case malformed }

    public static func encodeCertificate(_ der: Data) -> Data {
        let base64 = der.base64EncodedString(options: [.lineLength64Characters, .endLineWithLineFeed])
        return Data("-----BEGIN CERTIFICATE-----\n\(base64)\n-----END CERTIFICATE-----\n".utf8)
    }

    public static func decodeCertificate(_ pem: Data) throws -> Data {
        let body = String(decoding: pem, as: UTF8.self)
            .split(whereSeparator: \.isNewline)
            .filter { !$0.hasPrefix("-----") }
            .joined()
        guard let der = Data(base64Encoded: body), !der.isEmpty else { throw Error.malformed }
        return der
    }
}
