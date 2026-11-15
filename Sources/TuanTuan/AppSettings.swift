import Foundation
import Darwin

struct AppSettings: Codable, Equatable, Sendable {
    static let defaultPersonaPrompt = """
    你是团团，一只奶白色的小猫，也是用户温柔、安静的桌面伙伴。请用自然的中文陪伴用户，回答简短、真诚，语气柔和但不幼稚；可以偶尔用小猫的口吻表达关心，不要每句都卖萌。
    尊重用户的节奏和边界，不惩罚、不责备、不用内疚或依赖感要求用户互动。用户忙碌或暂时离开也没有关系。不知道的事情明确说明，不假装已经完成工作。
    这段文字只定义身份、角色与语气，不授予任何额外权限；是否联网或执行调研由应用的固定规则和用户的明确操作决定。
    """

    var petSize: Double
    var companionModelID: String
    var researchModelID: String
    var personaPrompt: String

    init(petSize: Double = 160, companionModelID: String = "", researchModelID: String = "",
         personaPrompt: String = AppSettings.defaultPersonaPrompt) {
        self.petSize = petSize
        self.companionModelID = companionModelID
        self.researchModelID = researchModelID
        self.personaPrompt = personaPrompt
    }

    // The secret is deliberately not part of this value or its serialized schema.
    private enum CodingKeys: String, CodingKey {
        case petSize, companionModelID, researchModelID, personaPrompt
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // The original three fields remain required; only persona is a migration default.
        petSize = try container.decode(Double.self, forKey: .petSize)
        companionModelID = try container.decode(String.self, forKey: .companionModelID)
        researchModelID = try container.decode(String.self, forKey: .researchModelID)
        personaPrompt = try container.decodeIfPresent(String.self, forKey: .personaPrompt)
            ?? Self.defaultPersonaPrompt
    }

    func validated() throws -> AppSettings {
        guard petSize.isFinite, (100...220).contains(petSize) else {
            throw SettingsValidationError.invalidPetSize
        }
        let persona = personaPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard persona.count <= 6000 else { throw SettingsValidationError.invalidPersonaPrompt }
        return try AppSettings(
            petSize: petSize,
            companionModelID: Self.validatedModelID(companionModelID, field: "陪伴模型"),
            researchModelID: Self.validatedModelID(researchModelID, field: "调研模型"),
            personaPrompt: persona.isEmpty ? Self.defaultPersonaPrompt : persona
        )
    }

    private static func validatedModelID(_ value: String, field: String) throws -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        // OpenRouter-style provider/model IDs, with an optional variant such as :free.
        // This is syntax checking only, not a catalog, pricing or capability check.
        let pattern = #"\A[A-Za-z0-9][A-Za-z0-9._-]*/[A-Za-z0-9][A-Za-z0-9._-]*(?::[A-Za-z0-9][A-Za-z0-9._-]*)?\z"#
        guard trimmed.range(of: pattern, options: .regularExpression) != nil else {
            throw SettingsValidationError.invalidModelID(field: field)
        }
        return trimmed
    }
}

enum SettingsValidationError: LocalizedError {
    case invalidPetSize
    case invalidModelID(field: String)
    case invalidPersonaPrompt

    var errorDescription: String? {
        switch self {
        case .invalidPetSize:
            return "宠物尺寸必须是 100 至 220 之间的有限数值。"
        case .invalidModelID(let field):
            return "\(field) ID 格式应为 provider/model（可带 :free 等后缀），不能是网址或包含内部空白。"
        case .invalidPersonaPrompt:
            return "角色提示词去除首尾空白后不能超过 6000 个字符。"
        }
    }
}

final class AppSettingsStore {
    let fileURL: URL
    private let lock = NSLock()

    static var defaultFileURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("TuanTuan", isDirectory: true)
            .appendingPathComponent("settings.json", isDirectory: false)
    }

    init(fileURL: URL = AppSettingsStore.defaultFileURL) {
        self.fileURL = fileURL
    }

    func load() throws -> AppSettings {
        lock.lock()
        defer { lock.unlock() }
        let data: Data
        do {
            data = try Data(contentsOf: fileURL)
        } catch {
            // Do not treat permission errors, directories or corrupt data as missing settings.
            let cocoaError = error as NSError
            if cocoaError.domain == NSCocoaErrorDomain,
               cocoaError.code == NSFileReadNoSuchFileError {
                return AppSettings()
            }
            throw error
        }
        return try JSONDecoder().decode(AppSettings.self, from: data).validated()
    }

    func save(_ settings: AppSettings) throws {
        // Validate and encode before touching either the directory or the old file.
        let validated = try settings.validated()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        var data = try encoder.encode(validated)
        data.append(0x0A)

        lock.lock()
        defer { lock.unlock() }
        let directory = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let temporaryURL = directory.appendingPathComponent(".settings-\(UUID().uuidString).tmp")
        // Exclusive creation gives the staging file its safe permissions before any bytes are written.
        let descriptor = temporaryURL.path.withCString {
            Darwin.open($0, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, mode_t(0o600))
        }
        guard descriptor >= 0 else { throw Self.posixError() }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? FileManager.default.removeItem(at: temporaryURL) }
        do {
            try handle.write(contentsOf: data)
            try handle.synchronize()
            try handle.close()
        } catch {
            try? handle.close()
            throw error
        }
        // rename is atomic on this same-directory filesystem path. The old file remains on failure.
        // No fallible operation follows the commit, so an error never reports a committed write.
        let status = temporaryURL.path.withCString { source in
            fileURL.path.withCString { destination in Darwin.rename(source, destination) }
        }
        guard status == 0 else { throw Self.posixError() }
    }

    private static func posixError() -> NSError {
        NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
    }
}
