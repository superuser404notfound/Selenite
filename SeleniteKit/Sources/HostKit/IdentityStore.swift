import Foundation
import Security

/// Keeps the client identity in the keychain and exposes it as a SecIdentity for TLS client auth.
public enum IdentityStore {
    public enum Error: Swift.Error { case keychain(OSStatus), key(String) }

    private static let service = "de.superuser404.Selenite.identity"
    private static let label = "Selenite GameStream Client"

    public static func loadOrCreate() throws -> ClientIdentity {
        let query: [CFString: Any] = [kSecClass: kSecClassGenericPassword, kSecAttrService: service,
                                      kSecReturnData: true, kSecMatchLimit: kSecMatchLimitOne]
        var item: CFTypeRef?
        if SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data {
            return try JSONDecoder().decode(ClientIdentity.self, from: data)
        }
        let identity = try ClientIdentity.generate()
        let add: [CFString: Any] = [kSecClass: kSecClassGenericPassword, kSecAttrService: service,
                                    kSecValueData: try JSONEncoder().encode(identity)]
        let status = SecItemAdd(add as CFDictionary, nil)
        guard status == errSecSuccess else { throw Error.keychain(status) }
        return identity
    }

    public static func secIdentity(for identity: ClientIdentity) throws -> SecIdentity {
        var cfError: Unmanaged<CFError>?
        let attributes: [CFString: Any] = [kSecAttrKeyType: kSecAttrKeyTypeRSA, kSecAttrKeyClass: kSecAttrKeyClassPrivate]
        guard let key = SecKeyCreateWithData(identity.privateKeyDER as CFData, attributes as CFDictionary, &cfError) else {
            throw Error.key(cfError.map { String(describing: $0.takeRetainedValue()) } ?? "unknown")
        }
        guard let certificate = SecCertificateCreateWithData(nil, identity.certificateDER as CFData) else {
            throw Error.key("certificate")
        }
        for (itemClass, ref) in [(kSecClassKey, key as AnyObject), (kSecClassCertificate, certificate as AnyObject)] {
            let status = SecItemAdd([kSecClass: itemClass, kSecValueRef: ref, kSecAttrLabel: label] as CFDictionary, nil)
            guard status == errSecSuccess || status == errSecDuplicateItem else { throw Error.keychain(status) }
        }
        var item: CFTypeRef?
        let status = SecItemCopyMatching([kSecClass: kSecClassIdentity, kSecAttrLabel: label,
                                          kSecReturnRef: true, kSecMatchLimit: kSecMatchLimitOne] as CFDictionary, &item)
        guard status == errSecSuccess, let found = item else { throw Error.keychain(status) }
        return found as! SecIdentity
    }
}
