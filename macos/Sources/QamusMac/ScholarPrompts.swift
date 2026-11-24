import Foundation
import FoundationModels

enum ScholarAction: Identifiable {
    case analyzeInContext(word: String, line: String, surrounding: String, bypassCache: Bool = false)
    case summarizeEntry
    case explainArabicDict
    case draftFlashcard
    case customQuestion(question: String, passage: String)

    var id: String {
        switch self {
        case .analyzeInContext(let word, let line, _, _): return "ctx:\(word):\(line.prefix(32))"
        case .summarizeEntry: return "summarize"
        case .explainArabicDict: return "explain-ar"
        case .draftFlashcard: return "flashcard"
        case .customQuestion(let q, _): return "q:\(q)"
        }
    }

    var title: String {
        switch self {
        case .analyzeInContext(let word, _, _, _): return "Context · \(word)"
        case .summarizeEntry: return "Entry TL;DR"
        case .explainArabicDict: return "Unpack Classical Arabic"
        case .draftFlashcard: return "Draft Flashcard"
        case .customQuestion(let q, _): return q
        }
    }
}

enum ScholarPrompts {
    /// Builds a native FoundationModels `GenerationSchema` dynamically (no Xcode macro plugin required),
    /// guaranteeing 100% schema-valid structured JSON output from Apple On-Device Intelligence.
    static func buildAppleGenerationSchema() throws -> GenerationSchema {
        let str = DynamicGenerationSchema(type: String.self)
        let modifierSchema = DynamicGenerationSchema(
            name: "ModifierItem",
            description: "Particle or preposition directly acting on or collocating with the target word",
            properties: [
                .init(name: "particle", description: "Arabic particle or preposition (e.g. لا or على)", schema: str),
                .init(name: "role", description: "Short English grammatical role", schema: str),
                .init(name: "effect", description: "How it changes the word's meaning or grammar here", schema: str)
            ]
        )
        let argSchema = DynamicGenerationSchema(
            name: "GrammarArgument",
            description: "Key grammatical partner tied to the word (فاعل, نائب فاعل, مفعول به, مضاف إليه)",
            properties: [
                .init(name: "relation", description: "English + Arabic relation label", schema: str),
                .init(name: "arabic", description: "Arabic word or phrase filling that role", schema: str),
                .init(name: "note", description: "Optional brief note", schema: str, isOptional: true)
            ]
        )
        let rootSchema = DynamicGenerationSchema(
            name: "ContextualWordAnalysis",
            description: "Concise Arabic word-in-context lexical and grammatical breakdown",
            properties: [
                .init(name: "selectedParseIndex", description: "Index of the matching verified Buckwalter parse (0..5), or omit if none fits", schema: DynamicGenerationSchema(type: Int.self), isOptional: true),
                .init(name: "vocalized", description: "Target Arabic word vocalized with harakat as read here", schema: str),
                .init(name: "partOfSpeech", description: "Compact English morphology tag including verb form I-X", schema: str),
                .init(name: "arabicTag", description: "Short Arabic grammatical label", schema: str),
                .init(name: "root", description: "Spaced Arabic root letters e.g. ف ر ض", schema: str, isOptional: true),
                .init(name: "meaningHere", description: "Ultra-concise English meaning right here in the clause", schema: str),
                .init(name: "actingOnIt", description: "Particles or prepositions acting on this word", schema: DynamicGenerationSchema(arrayOf: DynamicGenerationSchema(referenceTo: "ModifierItem"), maximumElements: 4)),
                .init(name: "syntaxRole", description: "Concise i'rab role of this target word in the clause", schema: str),
                .init(name: "arguments", description: "Key grammatical partners tied to this word", schema: DynamicGenerationSchema(arrayOf: DynamicGenerationSchema(referenceTo: "GrammarArgument"), maximumElements: 4)),
                .init(name: "clauseTranslation", description: "Natural English translation of the complete clause", schema: str),
                .init(name: "ambiguityNote", description: "Brief caveat only if unvoweled text is genuinely ambiguous", schema: str, isOptional: true)
            ]
        )
        return try GenerationSchema(root: rootSchema, dependencies: [modifierSchema, argSchema])
    }

    /// Keys are intentionally named so Ollama's alphabetical JSON-schema generation follows natural
    /// human reasoning order: translate clause -> contextual meaning -> modifiers -> pick Buckwalter parse -> POS -> syntax -> vocalized.
    static func analysisJSONSchema() -> [String: Any] {
        [
            "type": "object",
            "additionalProperties": false,
            "required": [
                "clauseTranslation",
                "contextualMeaning",
                "modifiersActingOnIt",
                "parseIndex",
                "posArabic",
                "posEnglish",
                "root",
                "syntaxArguments",
                "syntaxRole",
                "uncertaintyNote",
                "vocalized"
            ],
            "properties": [
                "clauseTranslation": [
                    "type": "string",
                    "description": "Crisp, natural English translation of the complete clause containing this word (use surrounding lines if the clause wraps)."
                ],
                "contextualMeaning": [
                    "type": "string",
                    "description": "Ultra-concise English meaning of ONLY the target word itself right here (<= 8 words, zero filler). NEVER include neighboring words (e.g. for إنّا before أرسلناك write 'Indeed, we', NOT 'Indeed, we have sent you')."
                ],
                "modifiersActingOnIt": [
                    "type": "array",
                    "description": "ONLY particles, prepositions, or governing words directly acting on or collocating with the target word (e.g. لا negation, على collocation, إنما). Max 3 items; do NOT put full clauses here.",
                    "items": [
                        "type": "object",
                        "additionalProperties": false,
                        "required": ["particle", "role", "effect"],
                        "properties": [
                            "particle": ["type": "string"],
                            "role": ["type": "string"],
                            "effect": ["type": "string"]
                        ]
                    ]
                ],
                "parseIndex": [
                    "type": ["integer", "null"],
                    "description": "0-based index from Verified Buckwalter Morphological Parses that matches your contextualMeaning (e.g. pick Noun/Verbal Noun for 'seeking', NOT Verb). Set null ONLY if no listed parse fits."
                ],
                "posArabic": [
                    "type": "string",
                    "description": "Compact Arabic grammatical label agreeing with parseIndex (e.g. 'فعل مضارع مبني للمجهول (افْتَعَلَ)' or 'اسم / مصدر')."
                ],
                "posEnglish": [
                    "type": "string",
                    "description": "Compact English morphology tag agreeing with parseIndex (e.g. 'Verb · Form VIII · Present Passive', 'Noun / Verbal Noun')."
                ],
                "root": [
                    "type": ["string", "null"],
                    "description": "Spaced Arabic root letters if applicable (e.g. 'ف ر ض'), or null for particles."
                ],
                "syntaxArguments": [
                    "type": "array",
                    "description": "Key grammatical partners directly tied to this word (e.g. Subject / Deputy Subject / Direct Object / Genitive Complement). Max 3 items; omit if uncertain.",
                    "items": [
                        "type": "object",
                        "additionalProperties": false,
                        "required": ["relation", "arabic", "note"],
                        "properties": [
                            "relation": ["type": "string"],
                            "arabic": ["type": "string"],
                            "note": ["type": ["string", "null"]]
                        ]
                    ]
                ],
                "syntaxRole": [
                    "type": "string",
                    "description": "Concise functional + i'rab role of the target word itself in the clause."
                ],
                "uncertaintyNote": [
                    "type": ["string", "null"],
                    "description": "Brief 1-sentence note ONLY if unvoweled text genuinely allows an alternate reading; otherwise null."
                ],
                "vocalized": [
                    "type": "string",
                    "description": "The target Arabic word vocalized with harakat matching parseIndex and context."
                ]
            ]
        ]
    }

    static func structuredSystemInstructions() -> String {
        """
        You are Qamus Morpho-Syntax Analyzer, a strict classical & modern Arabic grammar and lexical analysis engine.
        Rules:
        1. Analyze ONLY the target word in its immediate Arabic passage, grounded in the provided Qamus dictionary entries. Never write a sharh, sermon, or commentary beyond the text.
        2. Write explanations (`clauseTranslation`, `contextualMeaning`, `role`, `effect`, `posEnglish`, `syntaxRole`, `note`, `uncertaintyNote`) in clear, concise ENGLISH (with Arabic terms in parentheses where helpful). Put Arabic script in `vocalized`, `posArabic`, `root`, `particle`, and `arabic`.
        3. Be ultra-concise and zero-fluff: no preambles, no repetition.
        4. Reasoning flow:
           - First translate the full clause (`clauseTranslation`) and state the exact meaning of ONLY the target word itself (`contextualMeaning`, <= 8 words — never pull in adjacent words like the following verb).
           - In `modifiersActingOnIt`, list ONLY short particles/prepositions directly acting on or collocating with the target word (e.g. لا, على, بـ, إنما — max 3 items, never full phrases).
           - In `parseIndex`, pick the exact matching index from the Verified Buckwalter Morphological Parses that matches your `contextualMeaning` (e.g. if it means "seeking", pick Noun/Verbal Noun, NOT Past Verb; never guess past tense from Hans Wehr's past-tense lemma!).
           - Escape hatch: ONLY set `parseIndex: null` if the word is a rare classical form genuinely absent from the listed parses.
        5. Check syntax carefully:
           - `syntaxRole` must describe the TARGET WORD itself and agree with the chosen `parseIndex`.
           - A prepositional phrase (جار ومجرور such as على كل مسلم, له, عليه) is NEVER the فاعل or نائب فاعل when an overt nominative noun follows.
           - A PASSIVE verb (مبني للمجهول) takes a Deputy Subject (نائب فاعل), NEVER a Direct Object (مفعول به) for its promoted subject.
        6. Restraint over guessing: if an attachment is unclear or unvoweled text allows two readings, keep `syntaxArguments` minimal and add a 1-sentence `uncertaintyNote`.
        """
    }

    static func structuredPrompt(
        word: String,
        line: String,
        surrounding: String,
        snapshot: CurrentLookupSnapshot,
        backendMode: AIBackendMode,
        morphCandidates: [BuckwalterCandidate],
        camelResult: CamelAnalysisResponse?
    ) -> String {
        let grounded = snapshot.groundedContext(maxChars: backendMode == .appleOnDevice ? 2800 : 6500)
        let trimmedSurrounding = surrounding.trimmingCharacters(in: .whitespacesAndNewlines)
        let passageSection = trimmedSurrounding.isEmpty || trimmedSurrounding == line
            ? "Target Line:\n\(line)"
            : "Immediate Passage (surrounding sentences for full clause):\n\(trimmedSurrounding)\n\nTarget Line:\n\(line)"

        let camelSection: String
        if let camelResult, !camelResult.diacritizedSentence.isEmpty {
            camelSection = "\n\n\(camelResult.promptBlock(for: word))\n(Use CAMeL's context harakat and case endings as strong syntactic evidence — especially nominative مرفوع vs accusative منصوب vs genitive مجرور — while deriving classical meaning from Qamus below.)"
        } else {
            camelSection = ""
        }

        let morphSection: String
        if morphCandidates.isEmpty {
            morphSection = "Verified Buckwalter Morphological Parses:\n(None in Buckwalter table — set parseIndex to null and determine morphology directly from context + dictionary.)"
        } else {
            let lines = morphCandidates.map(\.promptLine).joined(separator: "\n")
            morphSection = """
            Verified Buckwalter Morphological Parses for "\(word)" (pick the matching index in `parseIndex`, or null ONLY if none fits):
            \(lines)
            """
        }

        return """
        \(passageSection)

        Target Word: \(word)\(camelSection)

        \(morphSection)

        Retrieved Qamus Dictionary Entries (for classical/contextual meaning):
        \(grounded.isEmpty ? "(No dictionary entry loaded — rely strictly on the Arabic passage above.)" : grounded)

        Return the structured JSON analysis for "\(word)" as used in the Target Line.
        """
    }

    static func freeformSystemInstructions() -> String {
        """
        You are Qamus Lexicon Assistant, a concise, accurate classical & modern Arabic lexicography tool.
        Rules:
        1. Ground every answer in the provided Qamus dictionary entries (Hans Wehr, Particles, Wiktionary, Lane's Lexicon, al-Mufradāt, Mukhtār al-Ṣiḥāḥ) and the active passage if given.
        2. Never invent commentary, legal rulings, or fake citations.
        3. Be crisp and scannable with zero filler or conversational preamble.
        """
    }

    static func freeformPrompt(
        action: ScholarAction,
        snapshot: CurrentLookupSnapshot,
        backendMode: AIBackendMode
    ) -> String {
        let grounded = snapshot.groundedContext(maxChars: backendMode == .appleOnDevice ? 3000 : 6500)
        let dictBlock = """
        Retrieved Qamus Dictionary Data:
        \(grounded.isEmpty ? "(No entry currently open.)" : grounded)
        """

        switch action {
        case .summarizeEntry:
            return """
            \(dictBlock)

            Give a crisp TL;DR of the retrieved entry for "\(snapshot.displayTitle)" in 3–4 short bullets: core root sense, main meanings, and key prepositional idioms. No preamble.
            """
        case .explainArabicDict:
            let arOnly = snapshot.arabicDictsText.isEmpty ? grounded : String(snapshot.arabicDictsText.prefix(2800))
            return """
            Classical Arabic Dictionary Text (al-Mufradāt / Mukhtār al-Ṣiḥāḥ):
            \(arOnly)

            Translate and unpack this classical Arabic lexicon entry for "\(snapshot.displayTitle)" into clear, concise English. Highlight the root's core concept and key derivatives. No preamble.
            """
        case .draftFlashcard:
            return """
            \(dictBlock)

            Draft a crisp flashcard for "\(snapshot.displayTitle)":
            - **Gloss**: (<= 10 words)
            - **Root & Pattern**: (brief)
            - **Example**: Short vocalized Arabic phrase + English
            - **Hook**: 1 short sentence tying it to its root.
            """
        case .customQuestion(let question, let passage):
            let passagePart = passage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? ""
                : "Active Arabic Passage:\n\(passage)\n\n"
            return """
            \(passagePart)\(dictBlock)

            Question: \(question)
            Answer directly and concisely, grounded in the passage and dictionary data above.
            """
        case .analyzeInContext:
            return ""
        }
    }
}
