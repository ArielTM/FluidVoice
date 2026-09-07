@testable import FluidVoice_Debug
import XCTest

private actor PrivateAIEnhancementProbe {
    struct Call: Sendable, Equatable {
        let inputText: String
        let maxOutputTokens: Int
    }

    private var activeCallCount = 0
    private var calls: [Call] = []
    private var maximumActiveCallCount = 0

    func begin(inputText: String, maxOutputTokens: Int) {
        self.activeCallCount += 1
        self.maximumActiveCallCount = max(self.maximumActiveCallCount, self.activeCallCount)
        self.calls.append(Call(inputText: inputText, maxOutputTokens: maxOutputTokens))
    }

    func end() {
        self.activeCallCount -= 1
    }

    func snapshot() -> (calls: [Call], active: Int, maximumActive: Int) {
        (self.calls, self.activeCallCount, self.maximumActiveCallCount)
    }
}

private struct PrivateAITestFailure: Error {}

private struct PrivateAITestIntegrationProvider: PrivateAIIntegrationProviding {
    let probe: PrivateAIEnhancementProbe
    let delayNanoseconds: UInt64
    let shouldFail: Bool

    var configuredModelID: String { "test-private-model" }
    var selectedModel: PrivateAIRegisteredModel { .unavailable }
    var configuredLocalModelPath: String? { nil }
    var modelDirectoryURL: URL { FileManager.default.temporaryDirectory }
    var isLocalRuntimeConfigured: Bool { true }

    func expectedLocalModelURL(for _: PrivateAIRegisteredModel) -> URL {
        self.modelDirectoryURL.appendingPathComponent("test-private-model")
    }

    func localModelPath(for _: PrivateAIRegisteredModel) -> String? { nil }
    func isModelInstalled(_: PrivateAIRegisteredModel) -> Bool { true }

    func prepareModel(
        _ model: PrivateAIRegisteredModel,
        progressHandler _: PrivateAIModelDownloadProgressHandler?
    ) async throws -> URL {
        self.expectedLocalModelURL(for: model)
    }

    func shouldHandleDictation(model _: String) -> Bool { true }

    func status(for _: PrivateAIIntegrationService.RuntimeConfiguration) async -> PrivateAIStatus {
        PrivateAIStatus(state: .ready, message: nil)
    }

    func loadedModelState() async -> PrivateAIIntegrationService.LoadedModelState? { nil }

    func loadModel(_: PrivateAIRegisteredModel) async throws -> PrivateAIStatus {
        PrivateAIStatus(state: .ready, message: nil)
    }

    func unloadCachedRuntime(reason _: String) async {}

    nonisolated func enhanceDictation(
        _ inputText: String,
        runtime _: PrivateAIIntegrationService.RuntimeConfiguration,
        context _: PrivateAIIntegrationService.AppContext,
        maxOutputTokens: Int
    ) async throws -> PrivateAIIntegrationService.EnhancementResult {
        await self.probe.begin(inputText: inputText, maxOutputTokens: maxOutputTokens)
        do {
            if self.delayNanoseconds > 0 {
                try await Task.sleep(nanoseconds: self.delayNanoseconds)
            }
            if self.shouldFail { throw PrivateAITestFailure() }
            await self.probe.end()
            return PrivateAIIntegrationService.EnhancementResult(
                outputText: "enhanced:\(inputText)",
                backendKind: "test",
                latencyMilliseconds: 1
            )
        } catch {
            await self.probe.end()
            throw error
        }
    }
}

@MainActor
final class PrivateAIDictationTokenBudgetTests: XCTestCase {
    func testPrivateAIDictationTokenBudgetFallsBackBeforeLongInputCanTruncate() {
        let shortTranscript = Array(repeating: "word", count: 600).joined(separator: " ")
        let longTranscript = Array(repeating: "word", count: 3385).joined(separator: " ")
        let tokenDenseIdentifier = String(repeating: "a", count: 6000)
        let unspacedCJKTranscript = String(repeating: "漢", count: 2500)

        XCTAssertTrue(SettingsStore.privateAIDictationTokenBudget(
            forInputText: shortTranscript,
            contextTokenLimit: 4096
        ).hasSufficientHeadroom)
        XCTAssertFalse(SettingsStore.privateAIDictationTokenBudget(
            forInputText: longTranscript,
            contextTokenLimit: 4096
        ).hasSufficientHeadroom)
        XCTAssertFalse(SettingsStore.privateAIDictationTokenBudget(
            forInputText: tokenDenseIdentifier,
            contextTokenLimit: 4096
        ).hasSufficientHeadroom)
        XCTAssertFalse(SettingsStore.privateAIDictationTokenBudget(
            forInputText: unspacedCJKTranscript,
            contextTokenLimit: 4096
        ).hasSufficientHeadroom)
    }

    func testPrivateAIDictationRejectsLongInputBeforeCallingProvider() async {
        await self.assertRejectedBeforeProvider(
            Array(repeating: "word", count: 3385).joined(separator: " "),
            failureMessage: "Expected long dictation to fall back before provider generation"
        )
    }

    func testPrivateAIDictationRejectsTokenDenseInputBeforeCallingProvider() async {
        await self.assertRejectedBeforeProvider(
            String(repeating: "a", count: 6000),
            failureMessage: "Expected token-dense dictation to fall back before provider generation"
        )
    }

    func testValidatedBudgetIsPassedToProviderWithoutRecomputation() async throws {
        let probe = PrivateAIEnhancementProbe()
        let service = PrivateAIIntegrationService(testingProvider: PrivateAITestIntegrationProvider(
            probe: probe,
            delayNanoseconds: 0,
            shouldFail: false
        ))
        let inputText = "hello fluid voice"
        let runtime = self.runtimeConfiguration()

        let result = try await service.enhanceDictation(
            inputText,
            runtime: runtime,
            context: self.appContext()
        )
        let snapshot = await probe.snapshot()

        XCTAssertEqual(result.outputText, "enhanced:\(inputText)")
        XCTAssertEqual(snapshot.calls, [PrivateAIEnhancementProbe.Call(
            inputText: inputText,
            maxOutputTokens: SettingsStore.privateAIDictationTokenBudget(
                forInputText: inputText,
                contextTokenLimit: runtime.contextTokenLimit
            ).maxOutputTokens
        )])
    }

    func testValidatedBudgetIsPassedThroughStreamingOverload() async throws {
        let probe = PrivateAIEnhancementProbe()
        let service = PrivateAIIntegrationService(testingProvider: PrivateAITestIntegrationProvider(
            probe: probe,
            delayNanoseconds: 0,
            shouldFail: false
        ))
        let inputText = "streamed fluid voice"
        let runtime = self.runtimeConfiguration()

        let result = try await service.enhanceDictation(
            inputText,
            runtime: runtime,
            context: self.appContext(),
            streamHandler: { _ in }
        )
        let snapshot = await probe.snapshot()

        XCTAssertEqual(result.outputText, "enhanced:\(inputText)")
        XCTAssertEqual(snapshot.calls, [PrivateAIEnhancementProbe.Call(
            inputText: inputText,
            maxOutputTokens: SettingsStore.privateAIDictationTokenBudget(
                forInputText: inputText,
                contextTokenLimit: runtime.contextTokenLimit
            ).maxOutputTokens
        )])
    }

    func testConcurrentEnhancementsRemainIndependentAndCanOverlap() async throws {
        let probe = PrivateAIEnhancementProbe()
        let service = PrivateAIIntegrationService(testingProvider: PrivateAITestIntegrationProvider(
            probe: probe,
            delayNanoseconds: 20_000_000,
            shouldFail: false
        ))
        let runtime = self.runtimeConfiguration()
        let context = self.appContext()

        let outputs = try await withThrowingTaskGroup(of: String.self) { group in
            for index in 0..<20 {
                group.addTask {
                    try await service.enhanceDictation(
                        "request-\(index)",
                        runtime: runtime,
                        context: context
                    ).outputText
                }
            }
            return try await group.reduce(into: []) { $0.append($1) }
        }
        let snapshot = await probe.snapshot()

        XCTAssertEqual(Set(outputs), Set((0..<20).map { "enhanced:request-\($0)" }))
        XCTAssertEqual(snapshot.calls.count, 20)
        XCTAssertEqual(snapshot.active, 0)
        XCTAssertGreaterThan(snapshot.maximumActive, 1)
    }

    func testCancellationPropagatesAndLeavesNoActiveProviderCall() async {
        let probe = PrivateAIEnhancementProbe()
        let service = PrivateAIIntegrationService(testingProvider: PrivateAITestIntegrationProvider(
            probe: probe,
            delayNanoseconds: 5_000_000_000,
            shouldFail: false
        ))
        let task = Task {
            try await service.enhanceDictation(
                "cancel me",
                runtime: self.runtimeConfiguration(),
                context: self.appContext()
            )
        }
        await Task.yield()
        task.cancel()

        do {
            _ = try await task.value
            XCTFail("Expected cancellation to propagate")
        } catch is CancellationError {
            // Expected.
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        let snapshot = await probe.snapshot()
        XCTAssertEqual(snapshot.active, 0)
    }

    func testProviderFailurePropagatesWithoutChangingIt() async {
        let probe = PrivateAIEnhancementProbe()
        let service = PrivateAIIntegrationService(testingProvider: PrivateAITestIntegrationProvider(
            probe: probe,
            delayNanoseconds: 0,
            shouldFail: true
        ))

        do {
            _ = try await service.enhanceDictation(
                "fail me",
                runtime: self.runtimeConfiguration(),
                context: self.appContext()
            )
            XCTFail("Expected provider failure to propagate")
        } catch is PrivateAITestFailure {
            // Expected.
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        let snapshot = await probe.snapshot()
        XCTAssertEqual(snapshot.active, 0)
        XCTAssertEqual(snapshot.calls.count, 1)
    }

    private func assertRejectedBeforeProvider(_ transcript: String, failureMessage: String) async {
        let runtime = self.runtimeConfiguration()
        let context = self.appContext()

        do {
            _ = try await PrivateAIIntegrationService.shared.enhanceDictation(
                transcript,
                runtime: runtime,
                context: context
            )
            XCTFail(failureMessage)
        } catch AIProcessingError.dictationExceedsAIContextWindow {
            // Expected: ContentView catches this and types the complete raw transcript.
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    private func runtimeConfiguration() -> PrivateAIIntegrationService.RuntimeConfiguration {
        PrivateAIIntegrationService.RuntimeConfiguration(
            selectedProviderID: "private",
            providerKey: "private",
            baseURL: "",
            model: "fluid-1",
            apiKey: "",
            localModelPath: nil,
            usesStablePromptPrefixKVCache: true,
            usesFluid1Boost: true,
            contextTokenLimit: 4096
        )
    }

    private func appContext() -> PrivateAIIntegrationService.AppContext {
        PrivateAIIntegrationService.AppContext(
            appName: "Notes",
            bundleID: "com.apple.Notes",
            windowTitle: "",
            appVersion: nil
        )
    }
}
