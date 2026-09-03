import Foundation
import Testing
@testable import BannyCore

struct LiveModelEndpointTests {
    @Test func grokIsAnAuthenticatedLocalCLIPreset() {
        let grok = LiveModelEndpoint.presets().first { $0.shape == .grok }

        #expect(grok?.name == "Grok")
        #expect(grok?.baseURL == URL(string: "script://grok"))
        #expect(grok?.model == "")
        #expect(grok?.shape.scriptName == "banny-grok.sh")
    }

    @Test func grokOffersTheModelsReportedByTheCLI() {
        let models = LiveModelEndpoint.Shape.grok.suggestedModels

        #expect(models.first?.label == "Default")
        #expect(models.first?.value == "")
        #expect(models.contains { $0.value == "grok-4.6" })
        #expect(models.contains { $0.value == "grok-4.5" })
    }
}
