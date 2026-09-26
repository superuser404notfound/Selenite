import Foundation
import Testing
@testable import HostKit

@Test func keychainLabelIsStablePerCertificateAndDistinctAcrossCertificates() throws {
    let a = try ClientIdentity.generate()
    let b = try ClientIdentity.generate()
    #expect(IdentityStore.keychainLabel(for: a.certificateDER) == IdentityStore.keychainLabel(for: a.certificateDER))
    #expect(IdentityStore.keychainLabel(for: a.certificateDER) != IdentityStore.keychainLabel(for: b.certificateDER))
}
