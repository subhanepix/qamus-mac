import Foundation

/// A single deterministic Buckwalter morphological candidate decoded from Qamus's bundled `data/morph.json`.
struct BuckwalterCandidate: Equatable, Sendable, Identifiable {
    let id: Int
    let vocalized: String
    let lemma: String
    let root: String?
    let isVerb: Bool
    let isNoun: Bool
    let isParticle: Bool
    let verbFormLabel: String?   // e.g. "Form VIII (افْتَعَلَ)"
    let englishPOS: String       // e.g. "Verb · Form VIII · Present Passive (3rd m. sg.)"
    let arabicTag: String        // e.g. "فعل مضارع مبني للمجهول (افْتَعَلَ)"
    let affixNote: String?       // e.g. "Prefix يُـ (3rd m. sg.)"

    var promptLine: String {
        var parts = ["[\(id)] \(vocalized) — \(englishPOS) | \(arabicTag)"]
        if let root, !root.isEmpty {
            parts.append("Root: \(root)")
        }
        if !lemma.isEmpty {
            parts.append("Lemma: \(lemma)")
        }
        if let affixNote, !affixNote.isEmpty {
            parts.append(affixNote)
        }
        return parts.joined(separator: " · ")
    }
}

/// Deterministic, zero-AI Buckwalter morphological analyzer reading Qamus's own bundled `data/morph.json`.
/// Runs in <1 ms once loaded, providing verified tense/voice/form/root candidates so LLMs never hallucinate
/// basic morphology (e.g. calling present passive `يُفْتَرَضُ` past tense `فعل ماضٍ`).
actor BuckwalterAnalyzer {
    private struct RawEntry {
        let vocalized: String
        let cat: String
        let gloss: String
        let rootIdx: Int
        let lemma: String
    }

    private var isLoaded = false
    private var prefixes: [String: [RawEntry]] = [:]
    private var suffixes: [String: [RawEntry]] = [:]
    private var stems: [String: [RawEntry]] = [:]
    private var roots: [String] = []
    private var ab: Set<String> = []
    private var ac: Set<String> = []
    private var bc: Set<String> = []

    func load(from webRootURL: URL) {
        guard !isLoaded else { return }
        let morphURL = webRootURL.appendingPathComponent("data/morph.json")
        guard let data = try? Data(contentsOf: morphURL),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return
        }

        if let abArr = json["AB"] as? [String] { self.ab = Set(abArr) }
        if let acArr = json["AC"] as? [String] { self.ac = Set(acArr) }
        if let bcArr = json["BC"] as? [String] { self.bc = Set(bcArr) }

        if let rawRoots = json["roots"] as? [[Any]] {
            self.roots = rawRoots.map { arr in
                let raw = (arr.first as? String) ?? ""
                return Self.cleanRootString(raw)
            }
        }

        self.prefixes = Self.parseAffixTable(json["prefixes"] as? [String: [[Any]]])
        self.suffixes = Self.parseAffixTable(json["suffixes"] as? [String: [[Any]]])
        self.stems = Self.parseStemTable(json["stems"] as? [String: [[Any]]])
        self.isLoaded = true
    }

    func analyze(_ rawWord: String) -> [BuckwalterCandidate] {
        guard isLoaded else { return [] }
        let trimmed = rawWord.trimmingCharacters(in: .whitespacesAndNewlines)
        let n = Self.normalize(trimmed)
        guard !n.isEmpty else { return [] }

        let chars = Array(n)
        let count = chars.count
        var rawMatches: [(pre: RawEntry, stem: RawEntry, suf: RawEntry, affixLen: Int, score: Int)] = []
        var seenKeys = Set<String>()

        let maxPre = min(5, count - 1)
        for i in 0...maxPre {
            let pk = String(chars[0..<i])
            guard let pList = prefixes[pk] else { continue }
            for j in stride(from: count, through: i + 1, by: -1) {
                let sufLen = count - j
                if sufLen > 7 { break }
                let sk = String(chars[j..<count])
                guard let sList = suffixes[sk] else { continue }
                let stemKey = String(chars[i..<j])
                guard let stList = stems[stemKey] else { continue }

                for p in pList {
                    for st in stList {
                        guard ab.contains("\(p.cat) \(st.cat)") else { continue }
                        for x in sList {
                            guard ac.contains("\(p.cat) \(x.cat)"),
                                  bc.contains("\(st.cat) \(x.cat)") else { continue }
                            let vocalized = p.vocalized + st.vocalized + x.vocalized
                            let key = "\(vocalized)|\(Self.coarseCat(st.cat))|\(st.lemma)"
                            if seenKeys.contains(key) { continue }
                            seenKeys.insert(key)

                            let score = Self.tashkeelCompatibilityScore(query: trimmed, candidate: vocalized)
                            rawMatches.append((p, st, x, i + sufLen, score))
                        }
                    }
                }
            }
        }

        // Prefer matching tashkeel (if input had harakat), then fewer split affixes, then verbs/nouns cleanly
        rawMatches.sort { a, b in
            if a.score != b.score { return a.score > b.score }
            if a.affixLen != b.affixLen { return a.affixLen < b.affixLen }
            return a.stem.vocalized.count > b.stem.vocalized.count
        }

        // Deduplicate by semantic signature so the LLM sees clean, distinct options (max 6)
        var candidates: [BuckwalterCandidate] = []
        var sigSet = Set<String>()

        for m in rawMatches {
            let rootStr: String? = (m.stem.rootIdx >= 0 && m.stem.rootIdx < roots.count && !roots[m.stem.rootIdx].isEmpty)
                ? roots[m.stem.rootIdx]
                : nil
            let decoded = Self.decodeMorphology(pre: m.pre, stem: m.stem, suf: m.suf, root: rootStr)
            let vocalized = m.pre.vocalized + m.stem.vocalized + m.suf.vocalized
            let sig = "\(decoded.englishPOS)|\(decoded.arabicTag)|\(rootStr ?? "")|\(Self.stripHarakat(vocalized))"
            if sigSet.contains(sig) { continue }
            sigSet.insert(sig)

            candidates.append(
                BuckwalterCandidate(
                    id: candidates.count,
                    vocalized: vocalized,
                    lemma: m.stem.lemma,
                    root: rootStr,
                    isVerb: decoded.isVerb,
                    isNoun: decoded.isNoun,
                    isParticle: decoded.isParticle,
                    verbFormLabel: decoded.verbFormLabel,
                    englishPOS: decoded.englishPOS,
                    arabicTag: decoded.arabicTag,
                    affixNote: decoded.affixNote
                )
            )
            if candidates.count >= 6 { break }
        }

        return candidates
    }

    // MARK: - Buckwalter Tag & Verb Form Decoding

    private struct DecodedMorph {
        let isVerb: Bool
        let isNoun: Bool
        let isParticle: Bool
        let verbFormLabel: String?
        let englishPOS: String
        let arabicTag: String
        let affixNote: String?
    }

    private static func decodeMorphology(
        pre: RawEntry,
        stem: RawEntry,
        suf: RawEntry,
        root: String?
    ) -> DecodedMorph {
        let cat = stem.cat
        let pCat = pre.cat
        let sCat = suf.cat

        let affixPieces = describeAffixes(pre: pre, suf: suf)
        let affixNote = affixPieces.isEmpty ? nil : affixPieces.joined(separator: "; ")

        // 1. Imperfect / Present Verb (IV...)
        if cat.hasPrefix("IV") {
            let isPassive = cat.contains("Pass") || pCat.contains("-yu") || pCat.contains("-tu") || pCat.contains("-Au") || pCat.contains("-nu")
                ? cat.contains("Pass")
                : false
            let form = inferVerbForm(lemma: stem.lemma, root: root)
            let person = decodeIVPerson(pCat: pCat, sCat: sCat)

            let formEn = form.map { " · \($0.english)" } ?? ""
            let formAr = form.map { " (\($0.pattern))" } ?? ""
            let personEn = person.map { " (\($0))" } ?? ""

            if isPassive {
                return DecodedMorph(
                    isVerb: true, isNoun: false, isParticle: false,
                    verbFormLabel: form.map { "\($0.english) (\($0.pattern))" },
                    englishPOS: "Verb\(formEn) · Present Passive\(personEn)",
                    arabicTag: "فعل مضارع مبني للمجهول\(formAr)",
                    affixNote: affixNote
                )
            } else {
                return DecodedMorph(
                    isVerb: true, isNoun: false, isParticle: false,
                    verbFormLabel: form.map { "\($0.english) (\($0.pattern))" },
                    englishPOS: "Verb\(formEn) · Present Active\(personEn)",
                    arabicTag: "فعل مضارع مبني للمعلوم\(formAr)",
                    affixNote: affixNote
                )
            }
        }

        // 2. Perfect / Past Verb (PV...)
        if cat.hasPrefix("PV") {
            let isPassive = cat.contains("Pass")
            let form = inferVerbForm(lemma: stem.lemma, root: root)
            let formEn = form.map { " · \($0.english)" } ?? ""
            let formAr = form.map { " (\($0.pattern))" } ?? ""

            if isPassive {
                return DecodedMorph(
                    isVerb: true, isNoun: false, isParticle: false,
                    verbFormLabel: form.map { "\($0.english) (\($0.pattern))" },
                    englishPOS: "Verb\(formEn) · Past Passive",
                    arabicTag: "فعل ماضٍ مبني للمجهول\(formAr)",
                    affixNote: affixNote
                )
            } else {
                return DecodedMorph(
                    isVerb: true, isNoun: false, isParticle: false,
                    verbFormLabel: form.map { "\($0.english) (\($0.pattern))" },
                    englishPOS: "Verb\(formEn) · Past Active",
                    arabicTag: "فعل ماضٍ مبني للمعلوم\(formAr)",
                    affixNote: affixNote
                )
            }
        }

        // 3. Imperative Verb (CV...)
        if cat.hasPrefix("CV") {
            let form = inferVerbForm(lemma: stem.lemma, root: root)
            let formEn = form.map { " · \($0.english)" } ?? ""
            let formAr = form.map { " (\($0.pattern))" } ?? ""
            return DecodedMorph(
                isVerb: true, isNoun: false, isParticle: false,
                verbFormLabel: form.map { "\($0.english) (\($0.pattern))" },
                englishPOS: "Verb\(formEn) · Imperative",
                arabicTag: "فعل أمر\(formAr)",
                affixNote: affixNote
            )
        }

        // 4. Proper Noun
        if cat.hasPrefix("Nprop") {
            return DecodedMorph(
                isVerb: false, isNoun: true, isParticle: false,
                verbFormLabel: nil,
                englishPOS: "Proper Noun",
                arabicTag: "اسم علم",
                affixNote: affixNote
            )
        }

        // 5. Noun / Maṣdar / Participle / Adjective
        if cat.hasPrefix("N") {
            let isFem = sCat.contains("-ap") || sCat.contains("-At")
            let isDual = sCat.contains("An") || sCat.contains("ayn")
            let isPl = sCat.contains("uwn") || sCat.contains("iyn") || sCat.contains("-At")
            var qual = ""
            if isDual { qual = " · Dual" }
            else if isPl { qual = " · Plural" }
            else if isFem { qual = " · Fem." }

            return DecodedMorph(
                isVerb: false, isNoun: true, isParticle: false,
                verbFormLabel: nil,
                englishPOS: "Noun / Verbal Noun\(qual)",
                arabicTag: "اسم / مصدر",
                affixNote: affixNote
            )
        }

        // 6. Function Word / Particle / Preposition / Pronoun
        return DecodedMorph(
            isVerb: false, isNoun: false, isParticle: true,
            verbFormLabel: nil,
            englishPOS: "Particle / Function Word",
            arabicTag: "حرف / أداة",
            affixNote: affixNote
        )
    }

    private struct VerbFormInfo {
        let english: String
        let pattern: String
    }

    /// Infers Arabic derived verb Form I–X from the vocalized Buckwalter lemma (e.g. `ٱِفْتَرَض` -> Form VIII).
    private static func inferVerbForm(lemma: String, root: String?) -> VerbFormInfo? {
        let clean = lemma.replacingOccurrences(of: "ٱ", with: "ا").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return nil }

        let baseChars = Array(stripHarakat(clean))
        let rootLetters = (root ?? "").replacingOccurrences(of: " ", with: "")
        let count = baseChars.count
        let hasShaddaAfterIndex: (Int) -> Bool = { targetIdx in
            var idx = -1
            for scalar in clean.unicodeScalars {
                if scalar.value == 0x0651 { // shadda
                    if idx == targetIdx { return true }
                } else if !Self.isDiacritic(scalar) {
                    idx += 1
                }
            }
            return false
        }

        // Form X: استـ... (6+ base letters)
        if count >= 6 && baseChars[0] == "ا" && baseChars[1] == "س" && baseChars[2] == "ت" {
            return VerbFormInfo(english: "Form X", pattern: "اسْتَفْعَلَ")
        }

        // Form VII: انـ... (5 base letters, root doesn't start with ن)
        if count == 5 && baseChars[0] == "ا" && baseChars[1] == "ن" && rootLetters.first != "ن" {
            return VerbFormInfo(english: "Form VII", pattern: "انْفَعَلَ")
        }

        // Form VIII: افتعل (5 base letters, starts with ا, 3rd letter ت or assimilated ط/د, OR 4 base letters with shadda on ت like اتّقى)
        if count == 5 && baseChars[0] == "ا" && (baseChars[2] == "ت" || baseChars[2] == "ط" || baseChars[2] == "د") {
            return VerbFormInfo(english: "Form VIII", pattern: "افْتَعَلَ")
        }
        if count == 4 && baseChars[0] == "ا" && baseChars[1] == "ت" && hasShaddaAfterIndex(1) {
            return VerbFormInfo(english: "Form VIII", pattern: "افْتَعَلَ")
        }

        // Form VI: تفاعل (5 base letters, starts with ت, 3rd letter ا)
        if count == 5 && baseChars[0] == "ت" && baseChars[2] == "ا" {
            return VerbFormInfo(english: "Form VI", pattern: "تَفَاعَلَ")
        }

        // Form V: تفعّل (4 base letters, starts with ت, shadda on 3rd letter)
        if count == 4 && baseChars[0] == "ت" && hasShaddaAfterIndex(2) {
            return VerbFormInfo(english: "Form V", pattern: "تَفَعَّلَ")
        }

        // Form IV: أفعل (4 base letters, starts with أ)
        if count == 4 && baseChars[0] == "أ" && rootLetters.first != "أ" {
            return VerbFormInfo(english: "Form IV", pattern: "أَفْعَلَ")
        }

        // Form III: فاعل (4 base letters, 2nd letter ا)
        if count == 4 && baseChars[1] == "ا" {
            return VerbFormInfo(english: "Form III", pattern: "فَاعَلَ")
        }

        // Form II: فعّل (3 base letters, shadda on 2nd letter)
        if count == 3 && hasShaddaAfterIndex(1) {
            return VerbFormInfo(english: "Form II", pattern: "فَعَّلَ")
        }

        // Form I: فعل (3 base letters, or 2 with shadda on geminate)
        if count == 3 || (count == 2 && hasShaddaAfterIndex(1)) {
            return VerbFormInfo(english: "Form I", pattern: "فَعَلَ")
        }

        return nil
    }

    private static func decodeIVPerson(pCat: String, sCat: String) -> String? {
        if pCat.contains("-hw-") { return "3rd m. sg." }
        if pCat.contains("-hy-") { return "3rd f. sg." }
        if pCat.contains("-hmA-") { return "3rd dual" }
        if pCat.contains("-hm-") { return "3rd m. pl." }
        if pCat.contains("-hn-") { return "3rd f. pl." }
        if pCat.contains("-Anta-") { return "2nd m. sg." }
        if pCat.contains("-Anti-") { return "2nd f. sg." }
        if pCat.contains("-AntmA-") { return "2nd dual" }
        if pCat.contains("-Antm-") { return "2nd m. pl." }
        if pCat.contains("-Antn-") { return "2nd f. pl." }
        if pCat.contains("-Ana-") { return "1st sg." }
        if pCat.contains("-nHn-") { return "1st pl." }
        return nil
    }

    private static func describeAffixes(pre: RawEntry, suf: RawEntry) -> [String] {
        var out: [String] = []
        if !pre.vocalized.isEmpty {
            let g = pre.gloss.isEmpty ? pre.cat : pre.gloss
            out.append("Prefix \(pre.vocalized) (\(g))")
        }
        if !suf.vocalized.isEmpty {
            let g = suf.gloss.isEmpty ? suf.cat : suf.gloss
            out.append("Suffix \(suf.vocalized) (\(g))")
        }
        return out
    }

    // MARK: - Parsing & Normalization Helpers

    private static func parseAffixTable(_ raw: [String: [[Any]]]?) -> [String: [RawEntry]] {
        guard let raw else { return [:] }
        var out: [String: [RawEntry]] = [:]
        out.reserveCapacity(raw.count)
        for (k, arr) in raw {
            out[k] = arr.compactMap { row in
                guard row.count >= 2,
                      let voc = row[0] as? String,
                      let cat = row[1] as? String else { return nil }
                let gloss = row.count >= 3 ? (row[2] as? String ?? "") : ""
                return RawEntry(vocalized: voc, cat: cat, gloss: gloss, rootIdx: -1, lemma: "")
            }
        }
        return out
    }

    private static func parseStemTable(_ raw: [String: [[Any]]]?) -> [String: [RawEntry]] {
        guard let raw else { return [:] }
        var out: [String: [RawEntry]] = [:]
        out.reserveCapacity(raw.count)
        for (k, arr) in raw {
            out[k] = arr.compactMap { row in
                guard row.count >= 2,
                      let voc = row[0] as? String,
                      let cat = row[1] as? String else { return nil }
                let gloss = row.count >= 3 ? (row[2] as? String ?? "") : ""
                let rootIdx = row.count >= 4 ? (row[3] as? Int ?? -1) : -1
                let lemma = row.count >= 5 ? (row[4] as? String ?? "") : ""
                return RawEntry(vocalized: voc, cat: cat, gloss: gloss, rootIdx: rootIdx, lemma: lemma)
            }
        }
        return out
    }

    private static func coarseCat(_ cat: String) -> String {
        if cat.hasPrefix("IV") { return cat.contains("Pass") ? "IV_PASS" : "IV" }
        if cat.hasPrefix("PV") { return cat.contains("Pass") ? "PV_PASS" : "PV" }
        if cat.hasPrefix("CV") { return "CV" }
        if cat.hasPrefix("Nprop") { return "NPROP" }
        if cat.hasPrefix("N") { return "N" }
        return "FW"
    }

    private static func cleanRootString(_ raw: String) -> String {
        // Strip trailing digits/parens/slashes like "فرض(1)" -> "ف ر ض"
        let letters = raw.unicodeScalars.filter { (0x0621...0x064A).contains($0.value) }
        return letters.map { String($0) }.joined(separator: " ")
    }

    private static func isDiacritic(_ scalar: UnicodeScalar) -> Bool {
        let v = scalar.value
        return (0x0610...0x061A).contains(v) || (0x064B...0x065F).contains(v) || v == 0x0670 || (0x06D6...0x06ED).contains(v) || v == 0x0640
    }

    private static func stripHarakat(_ s: String) -> String {
        String(String.UnicodeScalarView(s.unicodeScalars.filter { !isDiacritic($0) }))
    }

    /// Mirrors Qamus `engine.js` `norm()` exactly so keys match `morph.json`.
    private static func normalize(_ s: String) -> String {
        var out = ""
        for scalar in s.unicodeScalars {
            if isDiacritic(scalar) { continue }
            switch scalar {
            case "أ", "إ", "آ", "ٱ", "ء", "ؤ", "ئ": out.append("ا")
            case "ى", "ی": out.append("ي")
            case "ة": out.append("ه")
            case "ک": out.append("ك")
            default: out.unicodeScalars.append(scalar)
            }
        }
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Light tashkeel compatibility score: boosts candidates whose vowels match explicit harakat in the query.
    private static func tashkeelCompatibilityScore(query: String, candidate: String) -> Int {
        let hasMarks = query.unicodeScalars.contains { (0x064B...0x0652).contains($0.value) }
        guard hasMarks else { return 0 }
        // Simple vowel check on first letter (e.g. يُ vs يَ distinguishes passive vs active!)
        let qVowels = extractFirstVowel(query)
        let cVowels = extractFirstVowel(candidate)
        if let qv = qVowels, let cv = cVowels {
            return qv == cv ? 20 : -20
        }
        return 0
    }

    private static func extractFirstVowel(_ s: String) -> UnicodeScalar? {
        var sawConsonant = false
        for sc in s.unicodeScalars {
            if !sawConsonant && !isDiacritic(sc) {
                sawConsonant = true
            } else if sawConsonant && (0x064E...0x0650).contains(sc.value) {
                return sc
            } else if sawConsonant && !isDiacritic(sc) {
                break
            }
        }
        return nil
    }
}
