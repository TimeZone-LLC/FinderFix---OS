import XCTest
@testable import FinderFixApp

final class AppViewModelTests: XCTestCase {
    @MainActor
    func testApplyRulesPreventsOverlapAndReachesTerminalState() async throws {
        let viewModel: AppViewModel = AppViewModel()
        var invocationCount: Int = 0
        viewModel.configure(
            accessibilityStatus: { true },
            requestAccessibility: {},
            applyRules: {
                invocationCount += 1
                try? await Task.sleep(for: .milliseconds(25))
                return .success("Rules applied.")
            },
            openFinder: {}
        )

        viewModel.applyRulesNow()
        viewModel.applyRulesNow()

        XCTAssertTrue(viewModel.isApplyingRules)
        XCTAssertEqual(viewModel.activity, .working("Applying Finder rules…"))

        for _ in 0..<20 where viewModel.isApplyingRules {
            try await Task.sleep(for: .milliseconds(10))
        }

        XCTAssertEqual(invocationCount, 1)
        XCTAssertFalse(viewModel.isApplyingRules)
        XCTAssertEqual(viewModel.activity, .success("Rules applied."))
    }
}
