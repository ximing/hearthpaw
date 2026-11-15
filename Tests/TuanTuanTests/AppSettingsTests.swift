import Foundation
import XCTest
@testable import TuanTuan

final class AppSettingsTests: XCTestCase {
    private var directory: URL!
    private var fileURL: URL { directory.appendingPathComponent("settings.json") }

    override func setUpWithError() throws {
        // All test state stays beneath this project's task directory, never Application Support.
        let project = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        directory = project.appendingPathComponent(".work/ai-020/persona-storage-tests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
    }

    override func tearDownWithError() throws {
        if let directory { try FileManager.default.removeItem(at: directory) }
        directory = nil
    }

    func testDefaultsAndDefaultFileLocation() throws {
        XCTAssertEqual(try AppSettings().validated(), AppSettings(petSize: 160))
        XCTAssertEqual(AppSettings().personaPrompt, AppSettings.defaultPersonaPrompt)
        XCTAssertFalse(AppSettings.defaultPersonaPrompt.isEmpty)
        XCTAssertLessThanOrEqual(AppSettings.defaultPersonaPrompt.count, 6000)
        XCTAssertTrue(AppSettingsStore.defaultFileURL.path.hasSuffix("/Application Support/TuanTuan/settings.json"))
        XCTAssertEqual(try AppSettingsStore(fileURL: fileURL).load(), AppSettings())
        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path))
    }

    func testFiniteInclusiveSizeRange() throws {
        for size in [100.0, 100.5, 160, 219.9, 220] {
            XCTAssertEqual(try AppSettings(petSize: size).validated().petSize, size)
        }
        for size in [99.99, 220.01, 0, -1, Double.nan, Double.infinity, -Double.infinity] {
            XCTAssertThrowsError(try AppSettings(petSize: size).validated())
        }
    }

    func testModelIDsTrimAndKeepSeparateFields() throws {
        let input = AppSettings(companionModelID: " \nopenai/gpt-4.1\t",
                                researchModelID: "\n meta-llama/llama-3.3-70b-instruct:free \n")
        XCTAssertEqual(try input.validated(), AppSettings(
            companionModelID: "openai/gpt-4.1", researchModelID: "meta-llama/llama-3.3-70b-instruct:free"))
        XCTAssertEqual(try AppSettings(companionModelID: " \n\t", researchModelID: "").validated(), AppSettings())
    }

    func testModelIDSyntaxOnlyAllowsProviderAndModel() throws {
        for model in ["openrouter/auto", "anthropic/claude-sonnet-4", "vendor/model_v2.5:extended"] {
            XCTAssertEqual(try AppSettings(companionModelID: model).validated().companionModelID, model)
        }
        let invalid = [
            "https://openrouter.ai/api/v1", "http://example.com/model", "www.openrouter.ai", "gpt-4.1",
            "openai/", "/gpt-4.1", "openai//gpt-4.1", "openai/gpt 4.1", "openai/gpt\n4.1",
            "openai/gpt\t4.1", "openai/gpt\u{00A0}4.1", "openai/gpt\u{200B}4.1",
            "openai/gpt?api_key=example", "openai/gpt#fragment", "openai/gpt/extra",
            "openai/gpt:", "openai/gpt:free:extra", "openai/gpt\0"
        ]
        for model in invalid {
            XCTAssertThrowsError(try AppSettings(companionModelID: model).validated(), "companion: \(model)")
            XCTAssertThrowsError(try AppSettings(researchModelID: model).validated(), "research: \(model)")
        }
    }

    func testAtomicSaveRestartReadbackAndPermissions() throws {
        let nestedURL = directory.appendingPathComponent("fresh", isDirectory: true).appendingPathComponent("settings.json")
        let store = AppSettingsStore(fileURL: nestedURL)
        try store.save(AppSettings(petSize: 178, companionModelID: " openai/gpt-4.1 ", researchModelID: "openrouter/auto"))
        let first = try Data(contentsOf: nestedURL)
        XCTAssertEqual(try AppSettingsStore(fileURL: nestedURL).load(), AppSettings(
            petSize: 178, companionModelID: "openai/gpt-4.1", researchModelID: "openrouter/auto"))
        try store.save(AppSettings(petSize: 178, companionModelID: "openai/gpt-4.1", researchModelID: "openrouter/auto"))
        XCTAssertEqual(try Data(contentsOf: nestedURL), first, "Identical values produce stable JSON")
        try store.save(AppSettings(petSize: 220, researchModelID: "vendor/new-model:free"))
        XCTAssertEqual(try AppSettingsStore(fileURL: nestedURL).load(), AppSettings(
            petSize: 220, researchModelID: "vendor/new-model:free"))
        let attributes = try FileManager.default.attributesOfItem(atPath: nestedURL.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        let directoryAttributes = try FileManager.default.attributesOfItem(atPath: nestedURL.deletingLastPathComponent().path)
        XCTAssertEqual((directoryAttributes[.posixPermissions] as? NSNumber)?.intValue, 0o700)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: nestedURL.deletingLastPathComponent().path), ["settings.json"])
    }

    func testFailedValidationNeverReplacesPreviousBytesOrCreatesFile() throws {
        let store = AppSettingsStore(fileURL: fileURL)
        XCTAssertThrowsError(try store.save(AppSettings(petSize: .nan)))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path))
        try store.save(AppSettings(petSize: 150, companionModelID: "vendor/valid"))
        let previous = try Data(contentsOf: fileURL)
        let invalid = [AppSettings(petSize: 99), AppSettings(petSize: .infinity),
                       AppSettings(companionModelID: "https://example.com"),
                       AppSettings(researchModelID: "vendor/white space"),
                       AppSettings(personaPrompt: String(repeating: "猫", count: 6001))]
        for settings in invalid {
            XCTAssertThrowsError(try store.save(settings))
            XCTAssertEqual(try Data(contentsOf: fileURL), previous)
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), ["settings.json"])
    }

    func testCorruptIncompleteAndInvalidFilesThrowWithoutOverwriting() throws {
        let invalidDocuments = [
            "not JSON", "{", "{}", "[]", "null",
            #"{"petSize":"160","companionModelID":"","researchModelID":""}"#,
            #"{"petSize":99,"companionModelID":"","researchModelID":""}"#,
            #"{"petSize":160,"companionModelID":"https://example.com","researchModelID":""}"#,
            #"{"petSize":160,"companionModelID":"","researchModelID":"","personaPrompt":42}"#,
            #"{"personaPrompt":"角色不能替代三个必填字段"}"#
        ]
        for document in invalidDocuments {
            let original = Data(document.utf8)
            try original.write(to: fileURL)
            XCTAssertThrowsError(try AppSettingsStore(fileURL: fileURL).load())
            XCTAssertEqual(try Data(contentsOf: fileURL), original)
        }
        try Data().write(to: fileURL)
        XCTAssertThrowsError(try AppSettingsStore(fileURL: fileURL).load())
        XCTAssertEqual(try Data(contentsOf: fileURL), Data())
    }

    func testDirectoryIsNotSilentlyTreatedAsMissingAndFailedCommitCleansStagingFile() throws {
        try FileManager.default.createDirectory(at: fileURL, withIntermediateDirectories: false)
        let marker = fileURL.appendingPathComponent("keep.txt")
        try Data("keep".utf8).write(to: marker)
        let store = AppSettingsStore(fileURL: fileURL)
        XCTAssertThrowsError(try store.load())
        XCTAssertThrowsError(try store.save(AppSettings()))
        XCTAssertEqual(try String(contentsOf: marker, encoding: .utf8), "keep")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), ["settings.json"])
    }

    func testParentWriteFailurePreservesExistingBytes() throws {
        let parentFile = directory.appendingPathComponent("not-a-directory")
        let original = Data("unchanged".utf8)
        try original.write(to: parentFile)
        let store = AppSettingsStore(fileURL: parentFile.appendingPathComponent("settings.json"))
        XCTAssertThrowsError(try store.save(AppSettings()))
        XCTAssertEqual(try Data(contentsOf: parentFile), original)
    }

    func testSettingsJSONHasOnlyNonSecretFields() throws {
        // A synthetic token is validated in memory only; it is never given to the JSON store.
        let syntheticKey = "qa-not-a-real-api-key-\(UUID().uuidString)"
        XCTAssertEqual(try KeychainAPIKeyStore.validatedKey(" \(syntheticKey)\n"), syntheticKey)
        let store = AppSettingsStore(fileURL: fileURL)
        try store.save(AppSettings(companionModelID: "vendor/model", researchModelID: "vendor/research"))
        let data = try Data(contentsOf: fileURL)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(Set(object.keys), ["petSize", "companionModelID", "researchModelID", "personaPrompt"])
        XCTAssertEqual(object["personaPrompt"] as? String, AppSettings.defaultPersonaPrompt)
        let text = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertFalse(text.contains(syntheticKey))
        XCTAssertFalse(text.lowercased().contains("apikey"))
        XCTAssertFalse(text.lowercased().contains("api_key"))
    }

    func testLegacyThreeFieldJSONMigratesPersonaWithoutChangingExistingFieldsOrBytes() throws {
        let oldJSON = Data(#"{"petSize":186,"companionModelID":"vendor/companion","researchModelID":"vendor/research:free"}"#.utf8)
        try oldJSON.write(to: fileURL)
        let expected = AppSettings(petSize: 186, companionModelID: "vendor/companion",
                                   researchModelID: "vendor/research:free",
                                   personaPrompt: AppSettings.defaultPersonaPrompt)
        XCTAssertEqual(try JSONDecoder().decode(AppSettings.self, from: oldJSON), expected)
        let store = AppSettingsStore(fileURL: fileURL)
        XCTAssertEqual(try store.load(), expected)
        XCTAssertEqual(try Data(contentsOf: fileURL), oldJSON, "Reading migration must not silently write")
        try store.save(expected)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: fileURL)) as? [String: Any])
        XCTAssertEqual(object["personaPrompt"] as? String, AppSettings.defaultPersonaPrompt)
        XCTAssertEqual(try AppSettingsStore(fileURL: fileURL).load(), expected)
    }

    func testPersonaTrimsKeepsInternalNewlinesAndWhitespaceFallsBackToDefault() throws {
        let custom = "你是安静的小猫。\n  用简短中文回答，尊重用户。"
        let settings = AppSettings(petSize: 172, companionModelID: "vendor/companion",
                                   researchModelID: "vendor/research", personaPrompt: " \n\t\(custom)\n ")
        let validated = try settings.validated()
        XCTAssertEqual(validated.personaPrompt, custom)
        XCTAssertEqual(validated.petSize, 172)
        XCTAssertEqual(validated.companionModelID, "vendor/companion")
        XCTAssertEqual(validated.researchModelID, "vendor/research")
        for blank in ["", " ", "\n\t\r ", "\u{00A0}\u{3000}"] {
            XCTAssertEqual(try AppSettings(personaPrompt: blank).validated().personaPrompt,
                           AppSettings.defaultPersonaPrompt)
        }
    }

    func testPersonaLimitUsesCharactersAndDoesNotSilentlyTruncate() throws {
        for character in ["猫", "🐈‍⬛", "e\u{0301}"] {
            let maximum = String(repeating: character, count: 6000)
            XCTAssertEqual(maximum.count, 6000)
            XCTAssertEqual(try AppSettings(personaPrompt: " \n\(maximum)\n ").validated().personaPrompt, maximum)
            XCTAssertThrowsError(try AppSettings(personaPrompt: maximum + character).validated())
        }
    }

    func testCustomPersonaSurvivesSaveReloadAndStableJSON() throws {
        let store = AppSettingsStore(fileURL: fileURL)
        let expected = AppSettings(petSize: 178, companionModelID: "vendor/companion",
                                   researchModelID: "vendor/research",
                                   personaPrompt: "你是团团，温柔简短。\n不要因用户离开而责备。")
        try store.save(expected)
        let initialBytes = try Data(contentsOf: fileURL)
        XCTAssertEqual(try AppSettingsStore(fileURL: fileURL).load(), expected)
        try store.save(expected)
        XCTAssertEqual(try Data(contentsOf: fileURL), initialBytes)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: initialBytes) as? [String: Any])
        XCTAssertEqual(object["personaPrompt"] as? String, expected.personaPrompt)
    }

    func testSizeAndModelsMutationsAndModelResetPreserveSavedPersona() throws {
        let store = AppSettingsStore(fileURL: fileURL)
        let persona = "独立人格：用平和的中文陪伴用户。"
        try store.save(AppSettings(companionModelID: "vendor/companion", researchModelID: "vendor/research",
                                   personaPrompt: persona))
        var next = try store.load()
        next.petSize = 202
        try store.save(next)
        XCTAssertEqual(try store.load().personaPrompt, persona)
        next = try store.load()
        next.companionModelID = "vendor/new-companion"
        next.researchModelID = "vendor/new-research"
        try store.save(next)
        XCTAssertEqual(try store.load().personaPrompt, persona)
        next = try store.load()
        next.companionModelID = ""
        next.researchModelID = ""
        try store.save(next)
        XCTAssertEqual(try store.load(), AppSettings(petSize: 202, personaPrompt: persona))
    }

    func testPersonaMutationAndResetKeepSizeAndModels() throws {
        let store = AppSettingsStore(fileURL: fileURL)
        let original = AppSettings(petSize: 194, companionModelID: "vendor/companion",
                                   researchModelID: "vendor/research")
        try store.save(original)
        var next = try store.load()
        next.personaPrompt = "自定义身份与语气"
        try store.save(next)
        var expected = original
        expected.personaPrompt = next.personaPrompt
        XCTAssertEqual(try store.load(), expected)
        next = try store.load()
        next.personaPrompt = AppSettings.defaultPersonaPrompt
        try store.save(next)
        XCTAssertEqual(try store.load(), original)
    }
}
