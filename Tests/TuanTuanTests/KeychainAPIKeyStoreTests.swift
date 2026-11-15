import Foundation
import XCTest
import Security
@testable import TuanTuan

/// Pure logic only: no existing or QA Keychain item is queried, saved or deleted here.
final class KeychainAPIKeyStoreTests: XCTestCase {
    func testKeyValidationTrimsOuterWhitespaceAndUsesUTF8() throws {
        let token = "qa-not-a-real-key-密钥"
        let validated = try KeychainAPIKeyStore.validatedKey(" \t\n\(token)\r\n ")
        XCTAssertEqual(validated, token)
        XCTAssertEqual(String(data: Data(validated.utf8), encoding: .utf8), token)
    }

    func testKeyValidationRejectsEmptyInternalWhitespaceAndControls() {
        let invalid = ["", " \n\t", "qa key", "qa\nkey", "qa\tkey", "qa\rkey",
                       "qa\u{00A0}key", "qa\0key", "qa\u{0007}key"]
        for key in invalid {
            XCTAssertThrowsError(try KeychainAPIKeyStore.validatedKey(key))
        }
    }

    func testInvalidSaveIsRejectedBeforeAnyKeychainOperation() {
        // Even if validation regresses, this test can only target its unique QA service.
        let service = "com.tuantuan.prototype.qa.settings-012.\(UUID().uuidString)"
        let store = KeychainAPIKeyStore(service: service, account: "validation-only")
        for key in ["", " \n\t", "qa invalid value"] {
            XCTAssertThrowsError(try store.save(key)) { error in
                XCTAssertTrue(error is APIKeyValidationError)
            }
        }
    }

    func testErrorsContainOSStatusWithoutSecretOrServiceDetails() {
        let error = KeychainStoreError(operation: "保存密钥", status: errSecInteractionNotAllowed)
        XCTAssertTrue(error.localizedDescription.contains("OSStatus: \(errSecInteractionNotAllowed)"))
        XCTAssertFalse(error.localizedDescription.contains("qa-secret"))
        let rejected = "qa-secret invalid-value"
        XCTAssertThrowsError(try KeychainAPIKeyStore.validatedKey(rejected)) { error in
            XCTAssertFalse(error.localizedDescription.contains(rejected))
        }
    }
}
