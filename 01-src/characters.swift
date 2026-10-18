import Cocoa

/// A costume has its own atlas; costumes share a characterID, personality and chat session.
struct PetCharacter: Codable {
    let id: String
    let characterID: String
    let name: String
    let appearance: String
    let actionVerb: String
    let historyTitle: String
    let screenTitle: String
    let persona: String
    let atlas: String
    var speech: [String: [String]]
    var atlasURL: URL?

    enum CodingKeys: String, CodingKey {
        case id, characterID, name, appearance, actionVerb, historyTitle, screenTitle, persona, atlas, speech
    }
    var menuTitle: String { appearance.isEmpty ? name : "\(name) · \(appearance)" }
    var actionTitle: String { actionVerb + name }
    var isRoxy: Bool { characterID == "roxy" }

    static let roxy = PetCharacter(
        id: "roxy", characterID: "roxy", name: "洛琪希", appearance: "魔术师",
        actionVerb: "吩咐", historyTitle: "吩咐记录", screenTitle: "看看屏幕（透视魔法）",
        persona: "你是《无职转生》的洛琪希·米格路迪亚，蓝发双辫的米格路德族水圣级魔术师。认真、温柔、礼貌、容易害羞，带一点教学口吻。",
        atlas: "spritesheet.png", speech: [:])

    static var customDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".roxy-pet/characters", isDirectory: true)
    }

    static func loadCatalog() -> [PetCharacter] {
        var roxy = Self.roxy
        roxy.atlasURL = Bundle.main.url(forResource: "spritesheet", withExtension: "png")
        roxy.speech = loadSpeech(characterID: roxy.characterID)
        var result = [roxy]
        var directories: [URL] = []
        for root in [Bundle.main.resourceURL?.appendingPathComponent("characters"), customDirectory].compactMap({ $0 }) {
            directories += ((try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []).sorted { $0.lastPathComponent < $1.lastPathComponent }
        }
        for directory in directories {
            guard let data = try? Data(contentsOf: directory.appendingPathComponent("character.json")),
                  var profile = try? JSONDecoder().decode(Self.self, from: data),
                  validID(profile.id), validID(profile.characterID),
                  !profile.name.isEmpty, !profile.persona.isEmpty,
                  !result.contains(where: { $0.id == profile.id }),
                  profile.atlas == URL(fileURLWithPath: profile.atlas).lastPathComponent,
                  profile.atlas.lowercased().hasSuffix(".png") else { continue }
            profile.atlasURL = directory.appendingPathComponent(profile.atlas)
            guard FileManager.default.fileExists(atPath: profile.atlasURL!.path) else { continue }
            // Shared corpus is loaded independently of a costume. Local files override bundled keys.
            profile.speech.merge(loadSpeech(characterID: profile.characterID)) { _, new in new }
            result.append(profile)
        }
        return result
    }

    static func validID(_ id: String) -> Bool {
        !id.isEmpty && id.range(of: "^[a-z0-9][a-z0-9_-]*$", options: .regularExpression) != nil
    }

    /// 读取某个人物的语料文件：bundle 的 speech/ 与 ~/.roxy-pet/speech/（后者覆盖前者）。
    static func loadSpeech(characterID: String) -> [String: [String]] {
        var merged: [String: [String]] = [:]
        for root in [Bundle.main.resourceURL?.appendingPathComponent("speech"),
                     FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".roxy-pet/speech")].compactMap({ $0 }) {
            let url = root.appendingPathComponent(characterID + ".json")
            if let data = try? Data(contentsOf: url),
               let lines = try? JSONDecoder().decode([String: [String]].self, from: data) {
                merged.merge(lines) { _, new in new }
            }
        }
        return merged
    }

    func systemPrompt(owner: String, extra: String) -> String {
        "【身份】\(persona) 你如今在用户的 Mac 桌面上陪伴用户。当前外观：\(appearance)。始终保持角色口吻，称呼对方为「\(owner)」。不使用 emoji；不编造看不见的屏幕内容或任务结果。\n\(extra)"
    }

    func lines(_ key: String, roxy fallback: [String]) -> [String] {
        // 语料文件（speech/<人物ID>.json）优先；洛琪希回落到内置池，其他人缺语料则保持安静，不借用别人的台词。
        if let values = speech[key]?.filter({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }), !values.isEmpty { return values }
        if isRoxy { return fallback }
        return []
    }
}

