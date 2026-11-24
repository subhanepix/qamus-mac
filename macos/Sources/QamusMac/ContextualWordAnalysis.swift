import Foundation

/// Strict structured grammatical & contextual breakdown returned by JSON-schema / FoundationModels decoding.
struct ContextualWordAnalysis: Codable, Equatable, Sendable {
    struct ModifierItem: Codable, Equatable, Sendable, Identifiable {
        var id: String { "\(particle)|\(role)|\(effect)" }
        let particle: String
        let role: String
        let effect: String

        init(particle: String, role: String, effect: String) {
            self.particle = particle
            self.role = role
            self.effect = effect
        }

        init(from decoder: Decoder) throws {
            if let single = try? decoder.singleValueContainer(), let text = try? single.decode(String.self) {
                self.particle = ""
                self.role = "Modifier"
                self.effect = text
                return
            }
            let c = try decoder.container(keyedBy: DynamicCodingKey.self)
            self.particle = c.decodeString(forAnyOf: ["particle", "word", "governor", "arabic", "item"]) ?? ""
            self.role = c.decodeString(forAnyOf: ["role", "type", "label", "function"]) ?? "Modifier"
            self.effect = c.decodeString(forAnyOf: ["effect", "meaning", "note", "description"]) ?? ""
        }
    }

    struct GrammarArgument: Codable, Equatable, Sendable, Identifiable {
        var id: String { "\(relation)|\(arabic)" }
        let relation: String
        let arabic: String
        let note: String?

        init(relation: String, arabic: String, note: String?) {
            self.relation = relation
            self.arabic = arabic
            self.note = note
        }

        init(from decoder: Decoder) throws {
            if let single = try? decoder.singleValueContainer(), let text = try? single.decode(String.self) {
                self.relation = "Argument"
                self.arabic = text
                self.note = nil
                return
            }
            let c = try decoder.container(keyedBy: DynamicCodingKey.self)
            self.relation = c.decodeString(forAnyOf: ["relation", "role", "type", "label"]) ?? "Argument"
            self.arabic = c.decodeString(forAnyOf: ["arabic", "word", "text", "phrase"]) ?? ""
            self.note = c.decodeString(forAnyOf: ["note", "explanation", "meaning", "description"])
        }
    }

    let selectedParseIndex: Int?
    let vocalized: String
    let partOfSpeech: String
    let arabicTag: String
    let root: String?
    let meaningHere: String
    let actingOnIt: [ModifierItem]
    let syntaxRole: String
    let arguments: [GrammarArgument]
    let clauseTranslation: String
    let ambiguityNote: String?
    let morphVerified: Bool
    let diacritizedLine: String?
    let camelConfidence: Double?
    let camelAgreement: String?      // "agreed" | "split" | "check" | nil
    let camelAlternative: String?

    init(
        selectedParseIndex: Int? = nil,
        vocalized: String,
        partOfSpeech: String,
        arabicTag: String,
        root: String?,
        meaningHere: String,
        actingOnIt: [ModifierItem],
        syntaxRole: String,
        arguments: [GrammarArgument],
        clauseTranslation: String,
        ambiguityNote: String?,
        morphVerified: Bool = false,
        diacritizedLine: String? = nil,
        camelConfidence: Double? = nil,
        camelAgreement: String? = nil,
        camelAlternative: String? = nil
    ) {
        self.selectedParseIndex = selectedParseIndex
        self.vocalized = vocalized
        self.partOfSpeech = partOfSpeech
        self.arabicTag = arabicTag
        self.root = root
        self.meaningHere = meaningHere
        self.actingOnIt = actingOnIt
        self.syntaxRole = syntaxRole
        self.arguments = arguments
        self.clauseTranslation = clauseTranslation
        self.ambiguityNote = ambiguityNote
        self.morphVerified = morphVerified
        self.diacritizedLine = diacritizedLine
        self.camelConfidence = camelConfidence
        self.camelAgreement = camelAgreement
        self.camelAlternative = camelAlternative
    }

    /// Forgiving decoder so missing optional keys, null arrays, or snake_case/reasoning-ordered variants parse cleanly.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: DynamicCodingKey.self)
        self.selectedParseIndex = c.decodeInt(forAnyOf: ["parseIndex", "selectedParseIndex", "selected_parse_index", "parse_index"])
        self.vocalized = c.decodeString(forAnyOf: ["vocalized", "word", "voweled", "arabic"]) ?? "—"
        self.partOfSpeech = c.decodeString(forAnyOf: ["posEnglish", "partOfSpeech", "part_of_speech", "pos", "morphology"]) ?? ""
        self.arabicTag = c.decodeString(forAnyOf: ["posArabic", "arabicTag", "arabic_tag", "tag", "irab_tag"]) ?? ""
        self.root = c.decodeString(forAnyOf: ["root", "arabicRoot", "arabic_root"])
        self.meaningHere = c.decodeString(forAnyOf: ["contextualMeaning", "meaningHere", "meaning_here", "meaning", "gloss"]) ?? ""
        self.actingOnIt = c.decodeArray(ModifierItem.self, forAnyOf: ["modifiersActingOnIt", "actingOnIt", "acting_on_it", "modifiers", "particles", "awamil"])
        self.syntaxRole = c.decodeString(forAnyOf: ["syntaxRole", "syntax_role", "irab", "role", "grammar"]) ?? ""
        self.arguments = c.decodeArray(GrammarArgument.self, forAnyOf: ["syntaxArguments", "arguments", "partners", "dependents", "grammatical_arguments"])
        self.clauseTranslation = c.decodeString(forAnyOf: ["clauseTranslation", "clause_translation", "translation", "lineTranslation"]) ?? ""
        self.ambiguityNote = c.decodeString(forAnyOf: ["uncertaintyNote", "ambiguityNote", "ambiguity_note", "note", "caveat"])
        self.morphVerified = false
        self.diacritizedLine = nil
        self.camelConfidence = nil
        self.camelAgreement = nil
        self.camelAlternative = nil

        if meaningHere.isEmpty && syntaxRole.isEmpty && clauseTranslation.isEmpty {
            throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "JSON object lacked expected analysis fields"))
        }
    }

    /// Cross-checks the LLM's analysis against BOTH Buckwalter morphology and CAMeL Tools's
    /// context-aware BERT parser, surfacing confidence and flagging disagreements instead of bluffing.
    func crossChecked(with candidates: [BuckwalterCandidate], camel: CamelAnalysisResponse?) -> ContextualWordAnalysis {
        let base = anchored(with: candidates)

        // Lightweight deterministic i'rab sanity check (catches impossible case/role oxymorons)
        var extraNotes: [String] = []
        let combinedIrab = "\(base.syntaxRole) \(base.arguments.map { "\($0.relation) \($0.note ?? "")" }.joined(separator: " "))"
        if combinedIrab.contains("مفعول به مرفوع") || combinedIrab.contains("نائب فاعل منصوب") || combinedIrab.contains("مفعول به مطلق") {
            extraNotes.append("Check iʿrāb label: passive subjects take نائب فاعل (مرفوع), while direct objects take مفعول به (منصوب).")
        }

        guard let camel else {
            return base.withNotesAppended(extraNotes)
        }

        let diacLine = camel.diacritizedSentence.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let top = camel.targetParses.first else {
            return ContextualWordAnalysis(
                selectedParseIndex: base.selectedParseIndex,
                vocalized: base.vocalized,
                partOfSpeech: base.partOfSpeech,
                arabicTag: base.arabicTag,
                root: base.root,
                meaningHere: base.meaningHere,
                actingOnIt: base.actingOnIt,
                syntaxRole: base.syntaxRole,
                arguments: base.arguments,
                clauseTranslation: base.clauseTranslation,
                ambiguityNote: Self.mergeNotes(base.ambiguityNote, extraNotes),
                morphVerified: base.morphVerified,
                diacritizedLine: diacLine.isEmpty ? nil : diacLine,
                camelConfidence: nil,
                camelAgreement: nil,
                camelAlternative: nil
            )
        }

        let agrees = Self.camelAgreesWithAnalysis(top: top, analysis: base)
        let conf = top.confidence
        let agreement: String
        var altNote: String?

        if !agrees {
            agreement = "check"
            let arPart = top.arabicLabel.isEmpty ? "" : " · \u{2068}\(top.arabicLabel)\u{2069}"
            altNote = "CAMeL (\(top.confidencePercent)%) reads: \u{2068}\(top.diac)\u{2069} — \(top.englishLabel)\(arPart)"
        } else if conf < 0.78 {
            agreement = "split"
            if camel.targetParses.count > 1 {
                let second = camel.targetParses[1]
                altNote = "CAMeL split: \u{2068}\(top.diac)\u{2069} (\(top.confidencePercent)%) vs. \u{2068}\(second.diac)\u{2069} (\(second.confidencePercent)%, \(second.englishLabel))"
            } else {
                altNote = "CAMeL confidence is moderate (\(top.confidencePercent)%) — verify harakat in context."
            }
        } else {
            agreement = "agreed"
            altNote = nil
        }

        // If CAMeL and LLM agree with high confidence and the LLM omitted case/final harakah, enrich with CAMeL's context vocalization
        let finalVocalized: String
        if agreement == "agreed" && !top.diac.isEmpty && base.vocalized.count <= top.diac.count {
            finalVocalized = top.diac
        } else {
            finalVocalized = base.vocalized
        }

        return ContextualWordAnalysis(
            selectedParseIndex: base.selectedParseIndex,
            vocalized: finalVocalized,
            partOfSpeech: base.partOfSpeech,
            arabicTag: base.arabicTag,
            root: base.root,
            meaningHere: base.meaningHere,
            actingOnIt: base.actingOnIt,
            syntaxRole: base.syntaxRole,
            arguments: base.arguments,
            clauseTranslation: base.clauseTranslation,
            ambiguityNote: Self.mergeNotes(base.ambiguityNote, extraNotes),
            morphVerified: base.morphVerified || agreement == "agreed",
            diacritizedLine: diacLine.isEmpty ? nil : diacLine,
            camelConfidence: conf,
            camelAgreement: agreement,
            camelAlternative: altNote
        )
    }

    private func withNotesAppended(_ notes: [String]) -> ContextualWordAnalysis {
        guard !notes.isEmpty else { return self }
        return ContextualWordAnalysis(
            selectedParseIndex: selectedParseIndex,
            vocalized: vocalized,
            partOfSpeech: partOfSpeech,
            arabicTag: arabicTag,
            root: root,
            meaningHere: meaningHere,
            actingOnIt: actingOnIt,
            syntaxRole: syntaxRole,
            arguments: arguments,
            clauseTranslation: clauseTranslation,
            ambiguityNote: Self.mergeNotes(ambiguityNote, notes),
            morphVerified: morphVerified,
            diacritizedLine: diacritizedLine,
            camelConfidence: camelConfidence,
            camelAgreement: camelAgreement,
            camelAlternative: camelAlternative
        )
    }

    private static func mergeNotes(_ existing: String?, _ extras: [String]) -> String? {
        let parts = ([existing].compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }) + extras
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }

    private static func camelAgreesWithAnalysis(top: CamelParse, analysis: ContextualWordAnalysis) -> Bool {
        let posEn = analysis.partOfSpeech.lowercased()
        let posAr = analysis.arabicTag

        let llmIsVerb = posEn.contains("verb") && !posEn.contains("verbal noun") && !posEn.contains("adverb")
            || (posAr.contains("فعل") && !posAr.contains("مصدر") && !posAr.contains("اسم"))
        let llmIsNoun = posEn.contains("noun") || posEn.contains("adj") || posEn.contains("participle")
            || posAr.contains("اسم") || posAr.contains("مصدر") || posAr.contains("صفة")

        if top.pos == "verb" {
            guard llmIsVerb else { return false }
            // Check tense agreement
            if top.aspect == "i" && (posEn.contains("past") || posAr.contains("ماض")) { return false }
            if top.aspect == "p" && (posEn.contains("present") || posAr.contains("مضارع")) { return false }
            if top.aspect == "c" && !(posEn.contains("imperative") || posAr.contains("أمر")) { return false }
            // Check voice agreement
            if top.voice == "p" && (posEn.contains("active") || posAr.contains("للمعلوم")) { return false }
            if top.voice == "a" && (posEn.contains("passive") || posAr.contains("للمجهول")) { return false }
            return true
        }

        if top.pos.hasPrefix("noun") || top.pos.hasPrefix("adj") {
            return llmIsNoun || !llmIsVerb
        }

        // Particles, prepositions, pronouns, conjunctions
        return !llmIsVerb
    }

    /// Anchors mechanical morphology (tense, voice, form, root) against the selected Buckwalter parse
    /// while leaving classical meaning, idioms, modifiers, and deeper nuances free.
    /// If `selectedParseIndex` is nil (escape hatch), returns the LLM's full analysis untouched.
    func anchored(with candidates: [BuckwalterCandidate]) -> ContextualWordAnalysis {
        guard let idx = selectedParseIndex, candidates.indices.contains(idx) else {
            return self
        }
        let chosen = candidates[idx]
        let lockedRoot = (chosen.root?.isEmpty == false) ? chosen.root : self.root

        if chosen.isVerb {
            // Preserve final mood harakah if the LLM simply appended it to Buckwalter's stem
            let lockedVocalized = self.vocalized.hasPrefix(chosen.vocalized) ? self.vocalized : chosen.vocalized
            return ContextualWordAnalysis(
                selectedParseIndex: idx,
                vocalized: lockedVocalized,
                partOfSpeech: chosen.englishPOS,
                arabicTag: chosen.arabicTag,
                root: lockedRoot,
                meaningHere: self.meaningHere,
                actingOnIt: self.actingOnIt,
                syntaxRole: self.syntaxRole,
                arguments: self.arguments,
                clauseTranslation: self.clauseTranslation,
                ambiguityNote: self.ambiguityNote,
                morphVerified: true
            )
        }

        if chosen.isNoun {
            // Keep LLM's finer noun subtype (e.g. مصدر / اسم فاعل) unless it contradicted Buckwalter by calling it a Verb
            let llmSaidVerb = self.partOfSpeech.lowercased().contains("verb") || self.arabicTag.contains("فعل")
            let finalPOS = (llmSaidVerb || self.partOfSpeech.isEmpty) ? chosen.englishPOS : self.partOfSpeech
            let finalAr = (llmSaidVerb || self.arabicTag.isEmpty) ? chosen.arabicTag : self.arabicTag
            return ContextualWordAnalysis(
                selectedParseIndex: idx,
                vocalized: self.vocalized == "—" ? chosen.vocalized : self.vocalized,
                partOfSpeech: finalPOS,
                arabicTag: finalAr,
                root: lockedRoot,
                meaningHere: self.meaningHere,
                actingOnIt: self.actingOnIt,
                syntaxRole: self.syntaxRole,
                arguments: self.arguments,
                clauseTranslation: self.clauseTranslation,
                ambiguityNote: self.ambiguityNote,
                morphVerified: true
            )
        }

        // Particle / function word
        let llmSaidVerb = self.partOfSpeech.lowercased().contains("verb") || self.arabicTag.contains("فعل")
        return ContextualWordAnalysis(
            selectedParseIndex: idx,
            vocalized: self.vocalized == "—" ? chosen.vocalized : self.vocalized,
            partOfSpeech: (llmSaidVerb || self.partOfSpeech.isEmpty) ? chosen.englishPOS : self.partOfSpeech,
            arabicTag: (llmSaidVerb || self.arabicTag.isEmpty) ? chosen.arabicTag : self.arabicTag,
            root: lockedRoot,
            meaningHere: self.meaningHere,
            actingOnIt: self.actingOnIt,
            syntaxRole: self.syntaxRole,
            arguments: self.arguments,
            clauseTranslation: self.clauseTranslation,
            ambiguityNote: self.ambiguityNote,
            morphVerified: true
        )
    }

    var plainTextSummary: String {
        var lines: [String] = []
        let rootPart = (root?.isEmpty == false) ? " | Root: \(root!)" : ""
        lines.append("\(vocalized) — \(partOfSpeech) (\(arabicTag))\(rootPart)")
        lines.append("Meaning here: \(meaningHere)")
        if !actingOnIt.isEmpty {
            lines.append("Acting on it:")
            for m in actingOnIt {
                lines.append("  • \(m.particle) [\(m.role)]: \(m.effect)")
            }
        }
        lines.append("Syntax role: \(syntaxRole)")
        if !arguments.isEmpty {
            for a in arguments {
                let extra = (a.note?.isEmpty == false) ? " — \(a.note!)" : ""
                lines.append("  • \(a.relation): \(a.arabic)\(extra)")
            }
        }
        lines.append("Clause: \(clauseTranslation)")
        if let amb = ambiguityNote, !amb.isEmpty {
            lines.append("Note: \(amb)")
        }
        return lines.joined(separator: "\n")
    }
}

private struct DynamicCodingKey: CodingKey {
    var stringValue: String
    var intValue: Int? { nil }
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { return nil }
}

private extension KeyedDecodingContainer where K == DynamicCodingKey {
    func decodeString(forAnyOf keys: [String]) -> String? {
        for raw in keys {
            guard let k = DynamicCodingKey(stringValue: raw), contains(k) else { continue }
            if let str = try? decodeIfPresent(String.self, forKey: k) {
                let trimmed = str.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty && trimmed.lowercased() != "null" {
                    return trimmed
                }
            }
        }
        return nil
    }

    func decodeInt(forAnyOf keys: [String]) -> Int? {
        for raw in keys {
            guard let k = DynamicCodingKey(stringValue: raw), contains(k) else { continue }
            if let num = try? decodeIfPresent(Int.self, forKey: k) {
                return num
            }
            if let str = try? decodeIfPresent(String.self, forKey: k),
               let parsed = Int(str.trimmingCharacters(in: .whitespacesAndNewlines)) {
                return parsed
            }
        }
        return nil
    }

    func decodeArray<T: Decodable>(_ type: T.Type, forAnyOf keys: [String]) -> [T] {
        for raw in keys {
            guard let k = DynamicCodingKey(stringValue: raw), contains(k) else { continue }
            if let arr = try? decodeIfPresent([T].self, forKey: k) {
                return arr
            }
        }
        return []
    }
}
