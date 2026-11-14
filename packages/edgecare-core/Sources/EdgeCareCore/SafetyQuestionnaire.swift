import Foundation

public enum SafetyQuestionID: String, Codable, CaseIterable, Sendable {
    case urgentBreathing, urgentChestPain, urgentBleeding, urgentGeneral
    case followSkin, followLump, followCough, followBleeding, followScreening, followGeneral
}

public enum SafetyQuestionCategory: String, Codable, Sendable {
    case emergency, persistence, routing
}

/// Copy keys identify fixed, translated questions; this plan never generates clinical advice.
public struct SafetyQuestion: Equatable, Sendable, Identifiable {
    public let id: SafetyQuestionID
    public var copyKey: String { id.rawValue }
    public let category: SafetyQuestionCategory
    public init(id: SafetyQuestionID, category: SafetyQuestionCategory) {
        self.id = id
        self.category = category
    }
}

public enum SafetyAnswer: String, Codable, Sendable {
    case yes, no, unsure
}

public enum SafetyQuestionnaire {
    /// Combine English clinical values, stable form IDs and the original concern to select relevant questions.
    /// Keyword matching selects questions only. It does not interpret negation or assign urgency.
    public static func plan(profile: ClinicalProfile = ClinicalProfile(), selectedSymptoms: Set<String> = [],
                            originalConcern: String = "") -> [SafetyQuestion] {
        let canonical = ([profile.concernEnglish] + profile.symptomsEnglish + [profile.additionalContextEnglish])
            .joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        let text = (canonical + " " + originalConcern).lowercased()
        func matches(_ ids: [String], _ words: [String]) -> Bool {
            ids.contains { selectedSymptoms.contains($0) } || words.contains { text.contains($0) }
        }
        let skin = matches(["skin_change"], ["mole", "skin", "lesion", "luomi", "iho", "maqaarka", "شامة", "جلد", "родим", "шкір"])
        let lump = matches(["lump", "lump_or_swelling"], ["lump", "swelling", "kyhmy", "patti", "buro", "كتلة", "пухлин", "ущільнен", "припухлість"])
        let cough = matches(["persistent_cough", "cough"], ["cough", "yskä", "qufac", "سعال", "кашель", "кашл"])
        let breathing = matches([], ["breath", "hengitys", "neef", "تنفس", "диха", "задишк"])
        let chest = matches([], ["chest", "rinta", "laabta", "الصدر", "груд"])
        let bleeding = matches(["unexplained_bleeding"], ["bleed", "blood", "veri", "verenvuoto", "dhiig", "نزيف", "دم", "кров"])
        let screening = matches(["screening_letter"], ["letter", "screening", "kirje", "seulonta", "warqad", "baaritaan", "رسالة", "فحص", "лист", "скринінг"])
        var questions: [SafetyQuestion] = []
        if cough || breathing { questions.append(.init(id: .urgentBreathing, category: .emergency)) }
        if chest { questions.append(.init(id: .urgentChestPain, category: .emergency)) }
        if bleeding { questions.append(.init(id: .urgentBleeding, category: .emergency)) }
        // This fixed question must cover all other emergency symptoms in the localized copy.
        questions.append(.init(id: .urgentGeneral, category: .emergency))
        if skin { questions.append(.init(id: .followSkin, category: .persistence)) }
        if lump { questions.append(.init(id: .followLump, category: .persistence)) }
        if cough { questions.append(.init(id: .followCough, category: .persistence)) }
        if bleeding { questions.append(.init(id: .followBleeding, category: .persistence)) }
        if screening { questions.append(.init(id: .followScreening, category: .routing)) }
        if (!skin && !lump && !cough && !bleeding && !screening) || selectedSymptoms.contains("other_concern") {
            questions.append(.init(id: .followGeneral, category: .persistence))
        }
        return questions
    }
}

/// Answers remain attached to their questions when the patient continues after emergency advice.
public struct SafetyQuestionnaireState: Equatable, Sendable {
    public private(set) var plan: [SafetyQuestion]
    public private(set) var answers: [String: String]
    public private(set) var currentIndex: Int = 0
    public var totalCount: Int { plan.count }
    public init(plan: [SafetyQuestion], answers: [String: String] = [:]) {
        self.plan = plan
        self.answers = answers.filter { key, value in
            plan.contains { $0.id.rawValue == key } && SafetyAnswer(rawValue: value) != nil
        }
        currentIndex = plan.firstIndex { self.answers[$0.id.rawValue] == nil } ?? plan.count
    }
    public var portableAnswers: [String: String] { answers }
    public var currentQuestion: SafetyQuestion? { plan.indices.contains(currentIndex) ? plan[currentIndex] : nil }
    public var isComplete: Bool { currentIndex >= plan.count && plan.allSatisfy { answers[$0.id.rawValue] != nil } }
    public var requiresEmergencyHelp: Bool { hasYes(in: .emergency) }
    public var hasPersistentOrChangingSymptom: Bool { hasYes(in: .persistence) }
    private func hasYes(in category: SafetyQuestionCategory) -> Bool {
        plan.contains { $0.category == category && answers[$0.id.rawValue] == SafetyAnswer.yes.rawValue }
    }
    public mutating func answer(_ answer: SafetyAnswer, for id: SafetyQuestionID) {
        guard plan.contains(where: { $0.id == id }) else { return }
        answers[id.rawValue] = answer.rawValue
        if let index = plan.firstIndex(where: { $0.id == id }) { currentIndex = index + 1 }
    }
    @discardableResult
    public mutating func moveBack() -> Bool {
        guard currentIndex > 0 else { return false }
        currentIndex -= 1
        return true
    }
    public mutating func reset(plan: [SafetyQuestion]) {
        self = Self(plan: plan)
    }
}
