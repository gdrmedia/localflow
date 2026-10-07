import Foundation
import LocalFlowCore

// localflow-cli — offline test harness for the LocalFlow engine.

let usage = """
localflow-cli — LocalFlow engine from the command line (100% local)

  --status                         model presence, sizes, paths, config
  --download [--model <llm id>]    one-time model download (STT + LLM); the ONLY command that uses the network
  --file <audio> [--repeat N] [--no-cleanup] [--model <id>]
                                   transcribe + clean a file; prints raw, cleaned, per-stage ms
  --eval <cases.jsonl> [--model <id>] [--no-prefix-cache] [--quiet]
                                   run the cleanup eval; writes eval/results/<model>.{md,json}
  --bench [--model <id>] [--runs N]
                                   prefix-cache OFF vs ON latency on a ~10 s transcript
  --settings                       ask the running LocalFlow app to open its Settings window
  --history                        ask the running LocalFlow app to open its History window
  --verbose                        mirror the log to stderr
"""

let argv = Array(CommandLine.arguments.dropFirst())
func has(_ f: String) -> Bool { argv.contains(f) }
func val(_ f: String) -> String? {
    guard let i = argv.firstIndex(of: f), i + 1 < argv.count else { return nil }
    return argv[i + 1]
}
func fail(_ msg: String) -> Never {
    FileHandle.standardError.write(Data(("error: " + msg + "\n").utf8))
    exit(1)
}
func ms(_ d: Double) -> String { String(format: "%.0f ms", d) }
func now() -> Double { Date().timeIntervalSince1970 * 1000 }
func slug(_ s: String) -> String { s.replacingOccurrences(of: "/", with: "__") }
func freeDiskGB() -> Double {
    let v = try? URL(fileURLWithPath: NSHomeDirectory()).resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
    return Double(v?.volumeAvailableCapacityForImportantUsage ?? 0) / 1e9
}

if argv.isEmpty || has("--help") || has("-h") { print(usage); exit(0) }

ModelManager.enforceOffline()
try? LocalFlowPaths.ensureDirectories()
let logger = FlowLogger(url: LocalFlowPaths.logFile, mirrorToStderr: has("--verbose"))
let configLoad = AppConfigStore().load()
var config = configLoad.config
if let e = configLoad.error { FileHandle.standardError.write(Data(("warning: \(e)\n").utf8)) }
if let m = val("--model") { config.llmModel = m }

func loadSTT() async throws -> Transcriber {
    let t = Transcriber()
    let t0 = now()
    try await t.load(sttModel: config.sttModel)
    let t1 = now()
    try await t.warmUp()
    print(String(format: "stt: loaded %@ in %.0f ms, warm-up %.0f ms", config.sttModel, t1 - t0, now() - t1))
    return t
}

func loadLLM(prefixCache: Bool = true) async throws -> MLXCleanupBackend {
    let dir = ModelManager.llmDirectory(for: config.llmModel)
    let be = MLXCleanupBackend(modelID: config.llmModel, directory: dir, logger: logger)
    await be.setPrefixCaching(prefixCache)
    let t0 = now()
    try await be.load()
    let t1 = now()
    let system = CleanupPrompt.system(vocabulary: config.vocabulary)
    let n = prefixCache ? try await be.prepare(system: system) : 0
    let t2 = now()
    try await be.warmUp(system: system)
    print(String(format: "llm: loaded %@ in %.0f ms; prefix cache %@ (%d tokens, %.0f ms); warm-up %.0f ms",
                 config.llmModel, t1 - t0, prefixCache ? "ON" : "OFF", n, t2 - t1, now() - t2))
    return be
}

// MARK: - commands

if has("--settings") {
    LocalFlowIPC.postOpenSettings()
    print("asked LocalFlow to open Settings")
    exit(0)
}

if has("--history") {
    LocalFlowIPC.postOpenHistory()
    print("asked LocalFlow to open History")
    exit(0)
}

if has("--status") {
    let s = ModelManager.status(config: config)
    print("config:  \(LocalFlowPaths.configFile.path)\(configLoad.created ? " (created with defaults)" : "")")
    print("log:     \(LocalFlowPaths.logFile.path)")
    print("models:  \(LocalFlowPaths.modelsDir.path)")
    print("stt:     \(config.sttModel) — \(s.sttPresent ? "present" : "MISSING") (\(ModelManager.humanBytes(s.sttBytes))) at \(s.sttDirectory.path)")
    print("llm:     \(config.llmModel) — \(s.llmPresent ? "present" : "MISSING") (\(ModelManager.humanBytes(s.llmBytes))) at \(s.llmDirectory.path)")
    print("hotkey:  \(config.hotkey.rawValue)   cleanup: \(config.cleanupEnabled)   history: \(config.historyEnabled)   maxRecordingSeconds: \(config.maxRecordingSeconds)")
    print("vocab:   \(config.vocabulary.joined(separator: ", "))")
    print(String(format: "disk:    %.1f GB free", freeDiskGB()))
    exit(0)
}

if has("--download") {
    print(String(format: "disk before: %.1f GB free", freeDiskGB()))
    let s = ModelManager.status(config: config)
    let bar: @Sendable (String) -> (@Sendable (Double) -> Void) = { label in
        { p in FileHandle.standardError.write(Data(String(format: "\r%@ %3.0f%%", label, p * 100).utf8)) }
    }
    if s.sttPresent {
        print("stt already present: \(s.sttDirectory.path)")
    } else {
        print("downloading STT \(config.sttModel) …")
        let dir = try await ModelManager.downloadSTT(sttModel: config.sttModel, progress: bar("  stt"))
        print("\nstt done: \(dir.path) (\(ModelManager.humanBytes(ModelManager.directorySize(dir))))")
    }
    if s.llmPresent {
        print("llm already present: \(s.llmDirectory.path)")
    } else {
        print("downloading LLM \(config.llmModel) …")
        let dir = try await ModelManager.downloadLLM(id: config.llmModel, progress: bar("  llm"))
        print("\nllm done: \(dir.path) (\(ModelManager.humanBytes(ModelManager.directorySize(dir))))")
    }
    print(String(format: "disk after: %.1f GB free", freeDiskGB()))
    exit(0)
}

if let i = argv.firstIndex(of: "--file") {
    var paths: [String] = []
    for a in argv[(i + 1)...] { if a.hasPrefix("--") { break }; paths.append(a) }
    guard !paths.isEmpty else { fail("--file needs at least one path") }
    for p in paths where !FileManager.default.fileExists(atPath: p) { fail("no such file: \(p)") }
    let repeats = Int(val("--repeat") ?? "1") ?? 1
    let cleanup = !has("--no-cleanup")
    let stt = try await loadSTT()
    let llm: MLXCleanupBackend? = cleanup ? try await loadLLM() : nil
    let pipeline = CleanupPipeline(backend: llm, vocabulary: config.vocabulary, cleanupEnabled: cleanup)

    var totals: [Double] = []
    for path in paths {
    let url = URL(fileURLWithPath: path)
    let samples = try AudioFileLoader.load(url)
    let seconds = Double(samples.count) / Double(Transcriber.sampleRate)
    print(String(format: "\naudio: %@  %.2f s  %.1f dBFS%@", url.lastPathComponent, seconds, AudioFileLoader.dBFS(samples),
                 SilenceGuard.isSilent(samples) ? "  (SILENT — app would skip)" : ""))
    for i in 0..<repeats {
        let t0 = now()
        let r = try await stt.transcribe(samples: samples)
        let t1 = now()
        let c = await pipeline.clean(r.text)
        let t2 = now()
        totals.append(t2 - t0)
        if i == 0 || repeats <= 3 {
            print("raw:     \(r.text)")
            print("cleaned: \(c.text.replacingOccurrences(of: "\n", with: "⏎"))\(c.fallbackReason.map { "   [FALLBACK: \($0)]" } ?? "")")
        }
        print(String(format: "timing:  stt %.0f ms (rtfx %.1fx) | llm %.0f ms (prompt %d, cached %d, gen %d) | total %.0f ms",
                     t1 - t0, seconds / max(0.001, (t1 - t0) / 1000), c.llmMs, c.promptTokens, c.cachedPrefixTokens, c.generatedTokens, t2 - t0))
        logger.timing([("record", seconds * 1000), ("stt", t1 - t0), ("llm", c.llmMs), ("total", t2 - t0)])
    }
    }
    if totals.count > 1 {
        print(String(format: "\np50 total %.0f ms | p95 %.0f ms over %d runs", EvalRunner.percentile(totals, 0.5), EvalRunner.percentile(totals, 0.95), totals.count))
    }
    exit(0)
}

if let path = val("--eval") {
    let cases = try EvalRunner.loadCases(from: URL(fileURLWithPath: path))
    let prefix = !has("--no-prefix-cache")
    let quiet = has("--quiet")
    config.vocabulary = AppConfig.defaultVocabulary   // reproducible: the eval never depends on a personal config
    let llm = try await loadLLM(prefixCache: prefix)
    let pipeline = CleanupPipeline(backend: llm, vocabulary: config.vocabulary)
    print("eval: \(cases.count) cases, model \(config.llmModel), prefix cache \(prefix ? "ON" : "OFF")\n")
    let report = await EvalRunner.run(cases: cases, pipeline: pipeline, model: config.llmModel) { r in
        let mark = r.passed ? "✓" : "✗"
        let latency = r.usedLLM ? String(format: "%4.0f ms", r.llmMs) : "  code "
        var line = "\(mark) #\(String(format: "%2d", r.caseID)) \(latency)  \(r.actual.replacingOccurrences(of: "\n", with: "⏎"))"
        if !r.passed { line += "\n      expected: \(r.expected.replacingOccurrences(of: "\n", with: "⏎"))\n      input:    \(r.input)" }
        if let f = r.fallbackReason { line += "\n      fallback: \(f)" }
        if !quiet || !r.passed { print(line) }
    }
    print(String(format: "\nresult: %d/%d = %.1f%%  must-pass(1/7/8/9/17): %@  llm p50 %.0f ms  p95 %.0f ms",
                 report.passed, report.total, report.accuracy * 100, report.mustPassAllOK ? "PASS" : "FAIL", report.p50, report.p95))
    let outDir = URL(fileURLWithPath: path).deletingLastPathComponent().appendingPathComponent("results")
    try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
    let base = slug(config.llmModel) + (prefix ? "" : "__noprefix")
    var md = "# \(config.llmModel)\n\n" + EvalRunner.markdownTable([report]) + "\n| # | ok | ms | input | expected | actual |\n|---|---|---|---|---|---|\n"
    for r in report.results {
        md += "| \(r.caseID) | \(r.passed ? "✓" : "✗") | \(r.usedLLM ? String(format: "%.0f", r.llmMs) : "-") | \(r.input) | \(r.expected.replacingOccurrences(of: "\n", with: "⏎")) | \(r.actual.replacingOccurrences(of: "\n", with: "⏎")) |\n"
    }
    try md.write(to: outDir.appendingPathComponent(base + ".md"), atomically: true, encoding: .utf8)
    struct J: Codable { let model: String; let accuracy: Double; let p50: Double; let p95: Double; let mustPass: Bool
        let cases: [C]; struct C: Codable { let id: Int; let passed: Bool; let ms: Double; let input: String; let expected: String; let actual: String; let fallback: String? } }
    let j = J(model: config.llmModel, accuracy: report.accuracy, p50: report.p50, p95: report.p95, mustPass: report.mustPassAllOK,
              cases: report.results.map { .init(id: $0.caseID, passed: $0.passed, ms: $0.llmMs, input: $0.input, expected: $0.expected, actual: $0.actual, fallback: $0.fallbackReason) })
    let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
    try enc.encode(j).write(to: outDir.appendingPathComponent(base + ".json"))
    print("wrote \(outDir.appendingPathComponent(base + ".md").path)")
    exit(report.accuracy >= 0.9 && report.mustPassAllOK ? 0 : 2)
}

if has("--bench") {
    let runs = Int(val("--runs") ?? "5") ?? 5
    // ~30 words ≈ a 10-second utterance
    let transcript = "um so I was thinking that we should probably uh move the client meeting to Thursday afternoon no sorry I meant Friday afternoon because Dana has the dentist on Thursday"
    let system = CleanupPrompt.system(vocabulary: config.vocabulary)
    let user = CleanupPrompt.user(transcript: transcript)
    var table: [(String, [LLMOutput])] = []
    for prefix in [false, true] {
        let llm = try await loadLLM(prefixCache: prefix)
        var outs: [LLMOutput] = []
        for _ in 0..<runs {
            outs.append(try await llm.generate(system: system, user: user, maxTokensForInput: { CleanupPrompt.maxTokens(forInputTokens: $0) }))
        }
        table.append((prefix ? "prefix cache ON" : "prefix cache OFF", outs))
        print("  → \(outs.last!.text)")
        await llm.unload()
    }
    print("\n| mode | prompt tokens | cached | generated | prefill p50 | generate p50 | total p50 | total p95 |\n|---|---|---|---|---|---|---|---|")
    for (name, outs) in table {
        let pre = outs.map(\.prefillMs), gen = outs.map(\.generateMs), tot = outs.map(\.totalMs)
        print(String(format: "| %@ | %d | %d | %d | %.0f ms | %.0f ms | %.0f ms | %.0f ms |", name, outs[0].promptTokens, outs[0].cachedPrefixTokens, outs[0].generatedTokens,
                     EvalRunner.percentile(pre, 0.5), EvalRunner.percentile(gen, 0.5), EvalRunner.percentile(tot, 0.5), EvalRunner.percentile(tot, 0.95)))
    }
    exit(0)
}

print(usage)
exit(1)
