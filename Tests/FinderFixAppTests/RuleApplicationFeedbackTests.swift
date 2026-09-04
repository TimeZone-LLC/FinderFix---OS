import CoreGraphics
import XCTest
@testable import FinderFixApp

@MainActor
final class RuleApplicationFeedbackTests: XCTestCase {
    func testDisabledRulesDoNotReportSuccess() {
        let feedback: AppViewModel.ActivityState = FinderFixAppDelegate.ruleApplicationFeedback(
            report: report(results: [.skipped(.disabled)]),
            globalPreferenceResult: .noChanges,
            configuration: .disabled
        )

        XCTAssertEqual(feedback, .warning("No Finder rules are enabled."))
    }

    func testPartialPermissionFailureReportsWarning() {
        let configuration: FinderAutomationConfiguration = FinderAutomationConfiguration(
            windows: FinderWindowRuleConfiguration(
                isEnabled: true,
                size: CGSize(width: 900, height: 650)
            ),
            appearance: FinderWindowAppearanceConfiguration(toolbar: .shown)
        )
        let feedback: AppViewModel.ActivityState = FinderFixAppDelegate.ruleApplicationFeedback(
            report: report(results: [.skipped(.accessibilityNotAuthorized), .applied]),
            globalPreferenceResult: .noChanges,
            configuration: configuration
        )

        XCTAssertEqual(
            feedback,
            .warning("Some Finder rules were applied. Window placement needs Accessibility permission.")
        )
    }

    func testAppleEventFailureReportsFailure() {
        let configuration: FinderAutomationConfiguration = FinderAutomationConfiguration(
            appearance: FinderWindowAppearanceConfiguration(toolbar: .shown)
        )
        let feedback: AppViewModel.ActivityState = FinderFixAppDelegate.ruleApplicationFeedback(
            report: report(results: [.failed(.appleEventError(code: -1_743))]),
            globalPreferenceResult: .noChanges,
            configuration: configuration
        )

        XCTAssertEqual(
            feedback,
            .failure("Finder did not accept an appearance setting (error -1743).")
        )
    }

    func testAppliedGeometryReportsWindowCounts() {
        let configuration: FinderAutomationConfiguration = FinderAutomationConfiguration(
            windows: FinderWindowRuleConfiguration(isEnabled: true)
        )
        let feedback: AppViewModel.ActivityState = FinderFixAppDelegate.ruleApplicationFeedback(
            report: report(
                examined: 2,
                applied: 1,
                skipped: 1,
                results: [.applied, .noChanges]
            ),
            globalPreferenceResult: .noChanges,
            configuration: configuration
        )

        XCTAssertEqual(
            feedback,
            .success("Applied Finder rules; 1 of 2 existing windows changed.")
        )
    }

    func testDialogOnlyRulesExplainThatTheyApplyToFutureDialogs() {
        let configuration: FinderAutomationConfiguration = FinderAutomationConfiguration(
            dialogs: FinderDialogPlacementConfiguration(isEnabled: true)
        )
        let feedback: AppViewModel.ActivityState = FinderFixAppDelegate.ruleApplicationFeedback(
            report: report(results: []),
            globalPreferenceResult: .noChanges,
            configuration: configuration
        )

        XCTAssertEqual(
            feedback,
            .warning(
                "Finder dialog placement is active for new eligible dialogs; there is nothing to apply now."
            )
        )
    }

    private func report(
        examined: Int = 0,
        applied: Int = 0,
        skipped: Int = 0,
        failed: Int = 0,
        results: [FinderAutomationOperationResult]
    ) -> FinderWindowApplicationReport {
        FinderWindowApplicationReport(
            examined: examined,
            applied: applied,
            skipped: skipped,
            failed: failed,
            operationResults: results
        )
    }
}
