import KernovaAgentSimulation
import Testing

@Suite("Simulation scenarios")
struct ScenarioSuite {
    static let all: [Scenario] =
        HandshakeScenarios.all + PowerScenarios.all + UpdateScenarios.all
        + IdentityScenarios.all + LogScenarios.all + StreamScenarios.all + LivenessScenarios.all

    @Test("Every property holds over every seed", arguments: ScenarioSuite.all)
    func scenario(_ scenario: Scenario) {
        scenario.runAllSeeds()
    }
}
