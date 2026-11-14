import Foundation

/// Skin photo -> first-line CNN -> Gemini triage-priority score, run on the Edge-Care backend.
/// Demo estimate only: never a diagnosis or a cancer probability. The photo is sent only with explicit consent and is not stored.
public enum SkinRiskBand: String, Codable, Sendable, CaseIterable {
    case low, moderate, high, veryHigh = "very_high"
    public static func from(score: Int) -> SkinRiskBand { score >= 75 ? .veryHigh : score >= 50 ? .high : score >= 25 ? .moderate : .low }
    /// Referral priority recorded with the sealed referral.
    public var referralBand: RiskBand { switch self { case .low: return .low; case .moderate: return .medium; case .high, .veryHigh: return .high } }
}

public struct SkinAssessmentRequest: Encodable, Sendable {
    public let consent: Bool
    public let language: String
    public let imageBase64: String
    public let imageMime: String
    public let profile: ClinicalProfile?
    public let answers: [String: String]
    public let concern: String
    public init(consent: Bool, language: String, image: Data, imageMime: String = "image/jpeg", profile: ClinicalProfile?, answers: [String: String], concern: String) {
        self.consent = consent; self.language = language; imageBase64 = image.base64EncodedString(); self.imageMime = imageMime
        self.profile = profile; self.answers = answers; self.concern = String(concern.prefix(4000))
    }
    enum CodingKeys: String, CodingKey { case consent, language, imageBase64 = "image_base64", imageMime = "image_mime", profile, answers, concern }
}

public struct SkinCNNOutput: Codable, Equatable, Sendable {
    public let probabilities: [String: Double]
    public let top: String
    public let topProbability: Double
    public let malignantProbability: Double
    public let source: String
    public let model: String
    enum CodingKeys: String, CodingKey { case probabilities, top, topProbability = "top_probability", malignantProbability = "malignant_probability", source, model }
}

public struct SkinAssessmentResult: Codable, Equatable, Sendable {
    public let riskScore: Int
    public let band: SkinRiskBand
    public let keyFactors: [String]
    public let patientMessage: String
    public let clinicianNote: String
    public let cnn: SkinCNNOutput
    /// "gemini" or "fallback" (rule-based score when the AI assistant is unavailable).
    public let scoringSource: String
    public init(riskScore: Int, band: SkinRiskBand, keyFactors: [String], patientMessage: String, clinicianNote: String, cnn: SkinCNNOutput, scoringSource: String) {
        self.riskScore = riskScore; self.band = band; self.keyFactors = keyFactors; self.patientMessage = patientMessage
        self.clinicianNote = clinicianNote; self.cnn = cnn; self.scoringSource = scoringSource
    }
    enum CodingKeys: String, CodingKey {
        case riskScore = "risk_score", band, keyFactors = "key_factors", patientMessage = "patient_message"
        case clinicianNote = "clinician_note", cnn, scoringSource = "scoring_source"
    }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        riskScore = min(100, max(0, try values.decode(Int.self, forKey: .riskScore)))
        // The band always follows the score so the UI can never disagree with itself.
        band = SkinRiskBand.from(score: riskScore)
        keyFactors = Array(try values.decode([String].self, forKey: .keyFactors).prefix(4))
        patientMessage = try values.decode(String.self, forKey: .patientMessage)
        clinicianNote = try values.decode(String.self, forKey: .clinicianNote)
        cnn = try values.decode(SkinCNNOutput.self, forKey: .cnn)
        scoringSource = try values.decode(String.self, forKey: .scoringSource)
    }
    /// One line stored with the referral for the clinician; the raw image is never retained.
    public var clinicianSummary: String {
        let cnnLine = "CNN (\(cnn.source)): top \(cnn.top) p=\(String(format: "%.2f", cnn.topProbability)), malignant-class p=\(String(format: "%.2f", cnn.malignantProbability))"
        return "Skin photo demo score \(riskScore)/100 (\(band.rawValue), \(scoringSource)). \(cnnLine). Factors: \(keyFactors.joined(separator: "; ")). \(clinicianNote) Raw image not retained; not a diagnosis."
    }
    /// Merges the photo score into the local guidance. Emergency guidance always wins and is never downgraded.
    public func merged(into local: TriageGuidance, language: String) -> TriageGuidance {
        let patientText = scoringSource == "gemini" || SupportedLanguage.resolve(language) == .en ? patientMessage + "\n\n" : ""
        return TriageGuidance(message: local.requiresEmergencyHelp ? local.message : patientText + local.message,
            followUpQuestions: local.followUpQuestions,
            riskBand: local.requiresEmergencyHelp ? .high : band.referralBand,
            riskScore: local.requiresEmergencyHelp ? max(local.riskScore, riskScore) : riskScore,
            recommendedSpecialty: "dermatology", symptoms: local.symptoms.contains("skin_change") ? local.symptoms : local.symptoms + ["skin_change"],
            clinicianSummary: local.clinicianSummary + " " + clinicianSummary,
            label: "Research CNN + Gemini demo estimate · not a diagnosis", requiresEmergencyHelp: local.requiresEmergencyHelp,
            sources: local.sources + SkinRiskFacts.sources)
    }
}

/// Only our backend is contacted; provider keys stay server-side.
public struct SkinAssessmentClient: Sendable {
    private let transport: DemoHTTPTransport
    public init(baseURL: URL, configuration: AppConfiguration, bearerToken: String? = nil) {
        transport = DemoHTTPTransport(baseURL: baseURL, configuration: configuration, bearerToken: bearerToken, issuerToken: bearerToken)
    }
    public func assess(_ request: SkinAssessmentRequest) async throws -> SkinAssessmentResult {
        guard request.consent else { throw CoreError.consentRequired }
        let data = try await transport.request(path: ["demo", "skin", "assess"], method: "POST", body: try JSONEncoder().encode(request), issuer: true)
        return try JSONDecoder().decode(SkinAssessmentResult.self, from: data)
    }
}

/// Published, cited statistics shown with the score so patients understand why a check matters.
public enum SkinRiskFacts {
    public struct Fact: Sendable, Equatable { public let text: String; public let source: String }
    public static let sources = [
        "https://www.cancerresearchuk.org/about-cancer/melanoma/survival",
        "https://doi.org/10.1093/bjd/ljag086.396",
        "https://www.nhs.uk/conditions/melanoma-skin-cancer/",
    ]
    private static let referral = "British Journal of Dermatology 2026 (England, 2023 referrals)"
    private static let survival = "Cancer Research UK"
    private static let nhs = "NHS"
    /// Ordered so the most relevant fact for the band comes first.
    public static func facts(for band: SkinRiskBand, language: String) -> [Fact] {
        let text = texts[SupportedLanguage.resolve(language)] ?? texts[.en]!
        let diagnosed = Fact(text: text[0], source: referral)
        let early = Fact(text: text[1], source: survival)
        let check = Fact(text: text[2], source: nhs)
        return band == .low ? [check, diagnosed, early] : [diagnosed, early, check]
    }
    private static let texts: [SupportedLanguage: [String]] = [
        .en: ["About 7 in every 100 people referred urgently for a suspected skin cancer are diagnosed with skin cancer. Most are not, but only a check can tell.",
              "When melanoma is found early (stage 1), almost everyone survives 5 years or more. Found later (stage 3), it is about 75 in 100.",
              "Most moles and skin marks are harmless. A mark that is new, changing, bleeding or not healing should always be checked."],
        .fi: ["Noin 7 sadasta ihosyöpäepäilyn vuoksi kiireellisesti lähetetystä saa ihosyöpädiagnoosin. Useimmat eivät saa, mutta vain tutkimus kertoo varmasti.",
              "Kun melanooma löydetään varhain (vaihe 1), lähes kaikki ovat elossa vähintään 5 vuoden kuluttua. Myöhemmin (vaihe 3) löydettynä noin 75 sadasta.",
              "Useimmat luomet ja ihomuutokset ovat vaarattomia. Uusi, muuttuva, vuotava tai parantumaton muutos tulee aina tutkia."],
        .so: ["Qiyaastii 7 ka mid ah 100 qof ee si degdeg ah loogu gudbiyo shaki kansarka maqaarka ayaa laga helaa kansar maqaarka. Inta badan lagama helo, laakiin baaris keliya ayaa caddayn karta.",
              "Marka melanoma goor hore la ogaado (heerka 1), ku dhawaad qof walba wuxuu noolaadaa 5 sano ama ka badan. Marka goor dambe la ogaado (heerka 3), waa qiyaastii 75 ka mid ah 100.",
              "Inta badan barafyada iyo calaamadaha maqaarku waa kuwo aan waxyeello lahayn. Calaamad cusub, isbeddelaysa, dhiigaysa ama aan bogsanayn had iyo jeer waa in la baaro."],
        .ar: ["نحو 7 من كل 100 شخص يُحالون بشكل عاجل للاشتباه بسرطان الجلد يُشخَّصون بسرطان الجلد. معظمهم لا، لكن الفحص وحده يحسم الأمر.",
              "عند اكتشاف الميلانوما مبكراً (المرحلة 1) يعيش الجميع تقريباً 5 سنوات أو أكثر. وعند اكتشافها متأخرة (المرحلة 3) تبلغ النسبة نحو 75 من كل 100.",
              "معظم الشامات وعلامات الجلد غير ضارة. أي علامة جديدة أو متغيرة أو تنزف أو لا تلتئم يجب فحصها دائماً."],
        .uk: ["Приблизно 7 зі 100 людей, яких терміново направили через підозру на рак шкіри, отримують діагноз рак шкіри. Більшість — ні, але лише огляд може це визначити.",
              "Коли меланому виявляють рано (стадія 1), майже всі живуть 5 років і довше. Якщо пізніше (стадія 3) — приблизно 75 зі 100.",
              "Більшість родимок і плям на шкірі нешкідливі. Нову, змінену, кровоточиву чи незагойну пляму завжди слід показати лікарю."],
        .ne: ["छाला क्यान्सरको शङ्कामा तुरुन्त रेफर गरिएका प्रत्येक 100 जनामध्ये लगभग 7 जनालाई छाला क्यान्सर पत्ता लाग्छ। धेरैजसोलाई लाग्दैन, तर जाँचले मात्र थाहा हुन्छ।",
              "मेलानोमा चाँडै (चरण 1) पत्ता लागेमा लगभग सबै जना 5 वर्ष वा बढी बाँच्छन्। ढिलो (चरण 3) पत्ता लागेमा यो लगभग 100 मा 75 हुन्छ।",
              "धेरैजसो कोठी र छालाका दागहरू हानिरहित हुन्छन्। नयाँ, परिवर्तन हुँदै गरेको, रगत बग्ने वा निको नहुने दाग सधैँ जाँच गराउनुपर्छ।"],
    ]
}
