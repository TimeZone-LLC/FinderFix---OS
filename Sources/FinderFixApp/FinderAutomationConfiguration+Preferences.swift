import CoreGraphics

extension FinderAutomationConfiguration {
    init(preferences: FinderFixPreferences) {
        let preferences: FinderFixPreferences = preferences.normalized()
        let requestedSize: CGSize? = preferences.resizeWindows
            ? CGSize(
                width: min(max(preferences.windowWidth, 320), 10_000),
                height: min(max(preferences.windowHeight, 240), 10_000)
            )
            : nil

        let position: FinderWindowPositionRule
        if !preferences.repositionWindows {
            position = .unchanged
        } else {
            switch preferences.windowPosition {
            case .centered:
                position = .centered
            case .topLeft:
                position = .topLeft(inset: 24)
            case .topRight:
                position = .topRight(inset: 24)
            case .bottomLeft:
                position = .bottomLeft(inset: 24)
            case .bottomRight:
                position = .bottomRight(inset: 24)
            case .custom:
                position = .topLeftOffset(
                    x: preferences.horizontalOffset,
                    y: preferences.verticalOffset
                )
            }
        }

        let display: FinderWindowDisplayTarget
        switch preferences.displayTarget {
        case .primary:
            display = .primary
        case .pointer:
            display = .pointer
        case .current:
            display = .currentWindow
        }

        let appearance: FinderWindowAppearanceConfiguration
        if preferences.finderChromeEnabled {
            let viewRule: FinderViewRule
            switch preferences.finderChrome.viewStyle {
            case .unchanged: viewRule = .unchanged
            case .icons: viewRule = .icon
            case .list: viewRule = .list
            case .columns: viewRule = .column
            case .gallery: viewRule = .gallery
            }

            appearance = FinderWindowAppearanceConfiguration(
                toolbar: preferences.finderChrome.showToolbar ? .shown : .hidden,
                sidebar: preferences.finderChrome.showSidebar ? .shown : .hidden,
                pathBar: preferences.finderChrome.showPathBar ? .shown : .hidden,
                statusBar: preferences.finderChrome.showStatusBar ? .shown : .hidden,
                sidebarWidth: Int(preferences.finderChrome.sidebarWidth.rounded()),
                view: viewRule
            )
        } else {
            appearance = .unchanged
        }

        self.init(
            isEnabled: preferences.windowRulesEnabled
                || preferences.finderChromeEnabled
                || preferences.moveEligibleFinderDialogs
                || preferences.folderOpeningBehavior != .unchanged,
            windows: FinderWindowRuleConfiguration(
                isEnabled: preferences.windowRulesEnabled,
                size: requestedSize,
                position: position,
                display: display,
                constrainToVisibleFrame: true
            ),
            appearance: appearance,
            dialogs: FinderDialogPlacementConfiguration(
                isEnabled: preferences.moveEligibleFinderDialogs,
                raiseWhenFinderIsFrontmost: preferences.bringFinderDialogsForward
            ),
            openFoldersInNewTabs: preferences.folderOpeningBehavior.openFoldersInNewTabs
        )
    }
}
