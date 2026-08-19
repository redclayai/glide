import AutocompleteCore
import Foundation

/// Per-token classification + bias the writer needs in order to emit a profile. This is
/// the "rich" Swift form; the writer projects it into `TokenProfileRecordRaw` plus the
/// flat side tables (special lists, bias overrides, trie). One per token id, sized
/// exactly `vocabSize`.
public struct ACPFTokenEntry: Equatable {
    public var tokenID: TokenID
    public var bytes: [UInt8]
    public var flags: TokenProfileFlags
    public var staticBias: Float
    public var displayWidth: Int
    public var tokenType: UInt16

    public init(
        tokenID: TokenID,
        bytes: [UInt8],
        flags: TokenProfileFlags,
        staticBias: Float,
        displayWidth: Int,
        tokenType: UInt16
    ) {
        self.tokenID = tokenID
        self.bytes = bytes
        self.flags = flags
        self.staticBias = staticBias
        self.displayWidth = displayWidth
        self.tokenType = tokenType
    }
}

/// All inputs needed to serialise a profile, modelled as a single value so callers can
/// build it up cleanly and tests can construct one in a few lines.
public struct ACPFProfileInput {
    public var modelFamily: String
    public var vocabSize: Int
    public var tokenizerDigest: ACPFTokenizerDigestValue
    public var entries: [ACPFTokenEntry]
    public var ggufMetadataDigest: String
    public var generatorVersion: String
    public var builderHost: String
    public var buildTimestamp: Date
    public var headerFlags: UInt32

    public init(
        modelFamily: String,
        vocabSize: Int,
        tokenizerDigest: ACPFTokenizerDigestValue,
        entries: [ACPFTokenEntry],
        ggufMetadataDigest: String = "",
        generatorVersion: String = ACPF.generatorVersion,
        builderHost: String = "",
        buildTimestamp: Date = Date(),
        headerFlags: UInt32 = 0
    ) {
        self.modelFamily = modelFamily
        self.vocabSize = vocabSize
        self.tokenizerDigest = tokenizerDigest
        self.entries = entries
        self.ggufMetadataDigest = ggufMetadataDigest
        self.generatorVersion = generatorVersion
        self.builderHost = builderHost
        self.buildTimestamp = buildTimestamp
        self.headerFlags = headerFlags
    }
}

/// Pure serialiser. The output is one little-endian byte image; section layout is
/// described in `docs/03-token-profiles.md` (and in `ACPFFormat.swift` above). The
/// reader (`MmapAutocompleteProfile`) consumes the same image byte-for-byte.
public enum ACPFWriter {

    /// Serialise the input into a single `Data` buffer. Pure; suitable for both writing
    /// to disk and feeding the round-trip tests.
    public static func encode(_ input: ACPFProfileInput) throws -> Data {
        try validate(input)

        // 1. Bytes blob + per-token table.
        var bytesBlob = Data()
        var tokenTable = [TokenProfileRecordRaw](repeating: TokenProfileRecordRaw(), count: input.vocabSize)
        for entry in input.entries {
            let offset = UInt64(bytesBlob.count)
            bytesBlob.append(contentsOf: entry.bytes)
            tokenTable[Int(entry.tokenID)] = TokenProfileRecordRaw(
                bytesOffset: offset,
                bytesLen: UInt32(entry.bytes.count),
                flags: entry.flags.rawValue,
                staticBias: entry.staticBias,
                displayWidth: UInt16(min(entry.displayWidth, Int(UInt16.max))),
                tokenType: entry.tokenType,
                firstByte: entry.bytes.first.map { UInt16($0) } ?? ACPF.emptyFirstByte,
                trieTerminal: ACPF.noTrieTerminal
            )
        }

        // 2. Build the trie from non-excluded tokens, then patch each record's
        //    `trieTerminal` field with the terminal node index for fast lookup.
        let compact = buildAndCompactTrie(entries: input.entries)
        for (tokenID, nodeIndex) in compact.terminalByTokenID {
            // Token ids are sized `Int(tokenID)`; guarded by validate().
            // Node indices fit `UInt16` for any sensible vocab — most tokens share trie
            // depth ≤ 256, but trie nodes are *bytes*, so the count is bounded by the
            // total byte-blob size. For 151 936 tokens of avg ≤ 8 bytes that is ≤ ~1.2M
            // nodes which overflows UInt16. We store the bigger value in the BIAS_TABLES
            // / special-lists path; for the per-record `trieTerminal` we fall back to
            // `noTrieTerminal` whenever the index exceeds UInt16.max — the runtime
            // path then walks from the root, which is correct but slightly slower.
            guard nodeIndex < UInt32(ACPF.noTrieTerminal) else { continue }
            tokenTable[Int(tokenID)].trieTerminal = UInt16(nodeIndex)
        }

        // 3. First-byte buckets (256 buckets, sorted ids per bucket).
        var firstByteBuckets = Array(repeating: [TokenID](), count: 256)
        for entry in input.entries where !entry.flags.contains(.excluded) && !entry.bytes.isEmpty {
            firstByteBuckets[Int(entry.bytes[0])].append(entry.tokenID)
        }
        for i in 0..<firstByteBuckets.count { firstByteBuckets[i].sort() }

        // 4. Special lists.
        var specialLists = [SpecialList: [TokenID]]()
        for kind in SpecialList.allCases { specialLists[kind] = [] }
        for entry in input.entries {
            let f = entry.flags
            if f.contains(.excluded) { specialLists[.excluded]?.append(entry.tokenID) }
            if f.contains(.stop) { specialLists[.stop]?.append(entry.tokenID) }
            if f.contains(.newline) { specialLists[.newline]?.append(entry.tokenID) }
            if f.contains(.whitespace) { specialLists[.whitespace]?.append(entry.tokenID) }
            if f.contains(.sentenceEnd) { specialLists[.sentenceEnd]?.append(entry.tokenID) }
            if f.contains(.emoji) { specialLists[.emoji]?.append(entry.tokenID) }
            if f.contains(.chatMarker) { specialLists[.chatMarker]?.append(entry.tokenID) }
        }
        for kind in SpecialList.allCases { specialLists[kind]?.sort() }

        // 5. Per-mode bias overrides: only emit (id, delta) when delta != 0.
        var biasOverrides = [BiasMode: [(TokenID, Float)]]()
        for mode in BiasMode.allCases { biasOverrides[mode] = [] }
        for entry in input.entries {
            for mode in BiasMode.allCases {
                let delta = BiasPolicy.delta(flags: entry.flags, mode: mode, bytes: entry.bytes)
                if delta != 0 {
                    biasOverrides[mode]?.append((entry.tokenID, delta))
                }
            }
        }
        for mode in BiasMode.allCases {
            biasOverrides[mode]?.sort { $0.0 < $1.0 }
        }

        // 6. Encode each section payload into its own Data and remember its raw size.
        let tokenTableBytes = encodeTokenTable(tokenTable)
        let tokenBytesSection = bytesBlob
        let prefixTrieBytes = encodePrefixTrie(compact)
        let prefixBucketsBytes = encodePrefixBuckets(firstByteBuckets)
        let specialListsBytes = encodeSpecialLists(specialLists)
        let biasTablesBytes = encodeBiasTables(biasOverrides)
        let validationBytes = encodeValidationSection(input)

        let sectionPayloads: [SectionKind: Data] = [
            .tokenTable: tokenTableBytes,
            .tokenBytes: tokenBytesSection,
            .prefixTrie: prefixTrieBytes,
            .prefixBuckets: prefixBucketsBytes,
            .specialLists: specialListsBytes,
            .biasTables: biasTablesBytes,
            .validation: validationBytes
        ]
        let sectionItemSizes: [SectionKind: UInt32] = [
            .tokenTable: UInt32(ACPF.tokenRecordSize),
            .tokenBytes: 1,
            .prefixTrie: 0,
            .prefixBuckets: 0,
            .specialLists: 0,
            .biasTables: 0,
            .validation: 0
        ]
        let sectionItemCounts: [SectionKind: UInt32] = [
            .tokenTable: UInt32(input.vocabSize),
            .tokenBytes: UInt32(bytesBlob.count),
            .prefixTrie: UInt32(compact.nodes.count),
            .prefixBuckets: UInt32(firstByteBuckets.reduce(0) { $0 + $1.count }),
            .specialLists: UInt32(SpecialList.allCases.count),
            .biasTables: UInt32(BiasMode.allCases.count),
            .validation: 1
        ]

        // 7. Compute final layout.
        let familyBytes = Array(input.modelFamily.utf8)
        guard familyBytes.count <= 1024 else {
            throw ACPFWriteError.familyStringTooLong(length: familyBytes.count, max: 1024)
        }
        // Header + family string, padded up to the next 64-byte boundary.
        let headerFamilyEnd = ACPF.headerRawSize + familyBytes.count
        let headerEndPadded = alignUp(headerFamilyEnd, to: ACPF.sectionAlignment)

        var sectionOffsets = [SectionKind: UInt64]()
        var sectionLengths = [SectionKind: UInt64]()
        var cursor = UInt64(headerEndPadded)
        for kind in SectionKind.allCases {
            sectionOffsets[kind] = cursor
            let len = UInt64(sectionPayloads[kind]!.count)
            sectionLengths[kind] = len
            cursor += len
            // Pad to next 64-byte boundary so the following section starts aligned.
            cursor = UInt64(alignUp(Int(cursor), to: ACPF.sectionAlignment))
        }

        // 8. Build the header.
        var sectionsRaw = Array(repeating: ACPFSectionRaw(), count: ACPF.sectionCount)
        for kind in SectionKind.allCases {
            sectionsRaw[kind.rawValue] = ACPFSectionRaw(
                offset: sectionOffsets[kind]!,
                length: sectionLengths[kind]!,
                itemSize: sectionItemSizes[kind]!,
                itemCount: sectionItemCounts[kind]!
            )
        }
        let header = ACPFHeaderRaw(
            magic: ACPF.magic,
            version: ACPF.currentSchemaVersion,
            endian: ACPF.endianSentinel,
            headerSize: UInt32(headerEndPadded),
            vocabSize: UInt32(input.vocabSize),
            tokenizerHashLo: input.tokenizerDigest.lo,
            tokenizerHashHi: input.tokenizerDigest.hi,
            modelFamilyLen: UInt32(familyBytes.count),
            flags: input.headerFlags,
            buildTimestamp: Int64(input.buildTimestamp.timeIntervalSince1970.rounded()),
            sections: sectionsRaw
        )

        // 9. Stitch everything together.
        var out = Data()
        out.reserveCapacity(Int(cursor))
        header.encode(into: &out)
        precondition(out.count == ACPF.headerRawSize)
        out.append(contentsOf: familyBytes)
        out.padToMultiple(of: ACPF.sectionAlignment)
        precondition(out.count == headerEndPadded)
        for kind in SectionKind.allCases {
            precondition(UInt64(out.count) == sectionOffsets[kind]!,
                         "section \(kind) offset drift: \(out.count) vs \(sectionOffsets[kind]!)")
            out.append(sectionPayloads[kind]!)
            out.padToMultiple(of: ACPF.sectionAlignment)
        }
        precondition(UInt64(out.count) == cursor)
        return out
    }

    /// Serialise + write atomically to `url`. Used by the CLI; `encode` is used by the
    /// in-memory round-trip tests.
    public static func write(_ input: ACPFProfileInput, to url: URL) throws {
        let data = try encode(input)
        try data.write(to: url, options: [.atomic])
    }

    // MARK: - Input validation

    private static func validate(_ input: ACPFProfileInput) throws {
        if input.entries.count != input.vocabSize {
            throw ACPFWriteError.wrongRecordCount(expected: input.vocabSize, actual: input.entries.count)
        }
        var seen = [Bool](repeating: false, count: input.vocabSize)
        for entry in input.entries {
            let i = Int(entry.tokenID)
            if i < 0 || i >= input.vocabSize {
                throw ACPFWriteError.recordOutOfRange(tokenID: entry.tokenID, vocabSize: input.vocabSize)
            }
            if seen[i] {
                throw ACPFWriteError.recordOutOfRange(tokenID: entry.tokenID, vocabSize: input.vocabSize)
            }
            if entry.bytes.count > Int(UInt32.max) {
                throw ACPFWriteError.tokenBytesTooLong(tokenID: entry.tokenID, length: entry.bytes.count, max: Int(UInt32.max))
            }
            seen[i] = true
        }
        for (i, present) in seen.enumerated() where !present {
            throw ACPFWriteError.recordOutOfRange(tokenID: TokenID(i), vocabSize: input.vocabSize)
        }
    }

    // MARK: - Trie compaction

    /// Builds the byte-level prefix trie from non-excluded entries and compacts it into
    /// a flat node/edge representation suitable for memory-mapped lookup.
    static func buildAndCompactTrie(entries: [ACPFTokenEntry]) -> CompactTrie {
        let root = TrieBuilderNode()
        for entry in entries where !entry.flags.contains(.excluded) && !entry.bytes.isEmpty {
            var node = root
            for b in entry.bytes {
                if let child = node.children[b] {
                    node = child
                } else {
                    let child = TrieBuilderNode()
                    node.children[b] = child
                    node = child
                }
            }
            node.terminalTokenID = entry.tokenID
        }
        return compact(root: root)
    }

    private static func compact(root: TrieBuilderNode) -> CompactTrie {
        // BFS, assigning indices in order. queueNodes[i] is the builder node at compact
        // index `i`; queueIndex tracks the next un-processed node so we never call
        // `removeFirst()` (avoids O(n^2)).
        var queueNodes: [TrieBuilderNode] = [root]
        var nodes: [TrieNodeRaw] = [TrieNodeRaw(
            terminalTokenID: root.terminalTokenID.map { Int32($0) } ?? -1,
            firstEdgeIndex: 0,
            byteEdgeCount: 0
        )]
        var edges: [TrieEdge] = []
        var terminalByTokenID: [TokenID: UInt32] = [:]
        if let term = root.terminalTokenID {
            terminalByTokenID[term] = 0
        }
        var head = 0
        while head < queueNodes.count {
            let node = queueNodes[head]
            let idx = head
            head += 1
            let sortedChildren = node.children.sorted { $0.key < $1.key }
            let firstEdgeIdx = UInt32(edges.count)
            for (byte, child) in sortedChildren {
                let childIdx = UInt32(queueNodes.count)
                queueNodes.append(child)
                nodes.append(TrieNodeRaw(
                    terminalTokenID: child.terminalTokenID.map { Int32($0) } ?? -1,
                    firstEdgeIndex: 0,
                    byteEdgeCount: 0
                ))
                if let term = child.terminalTokenID {
                    terminalByTokenID[term] = childIdx
                }
                edges.append(TrieEdge(byte: byte, childIndex: childIdx))
            }
            nodes[idx].firstEdgeIndex = firstEdgeIdx
            nodes[idx].byteEdgeCount = UInt16(sortedChildren.count)
        }
        return CompactTrie(nodes: nodes, edges: edges, terminalByTokenID: terminalByTokenID)
    }

    // MARK: - Section encoders

    private static func encodeTokenTable(_ records: [TokenProfileRecordRaw]) -> Data {
        var out = Data()
        out.reserveCapacity(records.count * ACPF.tokenRecordSize)
        for r in records { r.encode(into: &out) }
        return out
    }

    private static func encodePrefixTrie(_ trie: CompactTrie) -> Data {
        var out = Data()
        out.appendLE(UInt32(trie.nodes.count))
        out.appendLE(UInt32(trie.edges.count))
        for n in trie.nodes { n.encode(into: &out) }
        for e in trie.edges { e.encode(into: &out) }
        return out
    }

    private static func encodePrefixBuckets(_ buckets: [[TokenID]]) -> Data {
        precondition(buckets.count == 256)
        var out = Data()
        var running: UInt32 = 0
        // 257 cumulative offsets so the runtime can compute counts with a single
        // subtraction.
        for bucket in buckets {
            out.appendLE(running)
            running &+= UInt32(bucket.count)
        }
        out.appendLE(running)
        for bucket in buckets {
            for id in bucket { out.appendLE(Int32(id)) }
        }
        return out
    }

    private static func encodeSpecialLists(_ lists: [SpecialList: [TokenID]]) -> Data {
        var out = Data()
        out.appendLE(UInt32(SpecialList.allCases.count))
        for kind in SpecialList.allCases {
            let ids = lists[kind] ?? []
            out.appendLE(UInt32(ids.count))
            for id in ids { out.appendLE(Int32(id)) }
        }
        return out
    }

    private static func encodeBiasTables(_ tables: [BiasMode: [(TokenID, Float)]]) -> Data {
        var out = Data()
        out.appendLE(UInt32(BiasMode.allCases.count))
        for mode in BiasMode.allCases {
            let pairs = tables[mode] ?? []
            out.appendLE(UInt32(pairs.count))
            for (id, delta) in pairs {
                out.appendLE(Int32(id))
                out.appendLE(delta.bitPattern)
            }
        }
        return out
    }

    private static func encodeValidationSection(_ input: ACPFProfileInput) -> Data {
        var out = Data()
        appendString(&out, input.ggufMetadataDigest)
        appendString(&out, input.generatorVersion)
        appendString(&out, input.builderHost)
        return out
    }

    private static func appendString(_ out: inout Data, _ string: String) {
        let bytes = Array(string.utf8)
        out.appendLE(UInt32(bytes.count))
        out.append(contentsOf: bytes)
    }

    // MARK: - Helpers

    private static func alignUp(_ value: Int, to alignment: Int) -> Int {
        let r = value % alignment
        return r == 0 ? value : value + (alignment - r)
    }
}

// MARK: - In-memory trie types used during compaction

/// Mutable trie node used during building. Discarded after `ACPFWriter.encode` finishes.
final class TrieBuilderNode {
    var terminalTokenID: TokenID?
    var children: [UInt8: TrieBuilderNode] = [:]
}

/// Result of trie compaction: a flat node array, a flat edge array, and a back-link from
/// terminal token id to the node index where it ends.
struct CompactTrie {
    var nodes: [TrieNodeRaw]
    var edges: [TrieEdge]
    var terminalByTokenID: [TokenID: UInt32]
}
