# macOS verification checklist

This is a current-source checklist, not a record of a historical merge or of
manual evidence. Run the commands below before recording a result; unchecked
items deliberately make no claim that a visual or system integration has been
observed.

## Adaptive shell contract

- [ ] Launch the main `WindowGroup` at its 1200 × 780 default, then resize it
      to 560 × 420, the source's minimum content size. At the compact size,
      detail content must receive the compact width class when its measured
      content width is below 720 pt. A collapsed sidebar is an adaptive state,
      not a failure.
- [ ] At 560 × 420, use **View → Show Sidebar** if needed and the **Go** menu
      to reach destinations; no route should depend on the source list being
      visible. Return to a regular-width window and confirm the detail resumes
      its regular split layout at 720 pt of content width.
- [ ] Check the native Settings window opened with **⌘,**. It has exactly four
      panes — Account, Display, Refresh & Notifications, and Advanced — with
      native grouped Form rows and regular desktop control sizing. On a wide
      Settings window, explanatory text remains bounded to the form measure
      rather than spanning the entire window.
- [ ] In **Display**, change source-list expansion, choose **Reset Sidebar
      Sections**, and confirm that Analyze and Monitor are expanded again. The
      reset changes no other preference.

## Native commands and windows

- [ ] **GetHog → Settings…** and **⌘,** open the native Settings scene; closing
      it returns to the existing main window. **GetHog → About GetHog** opens
      the native About window.
- [ ] **View → Hide Sidebar / Show Sidebar** changes source-list visibility.
      **View → Refresh** is enabled only when the focused screen publishes a
      refresh action. **Customize Toolbar…** is available on the Dashboard and
      Sessions toolbars that declare customizable items.
- [ ] **Go** mirrors `AppTab.sections`; **⌘1** through **⌘9** reach its first
      nine destinations. Search and Settings remain out of that menu because
      Search is a loose utility row and Settings is a separate scene.
- [ ] The native Window and File commands preserve their system roles: New
      Window opens another main shell, Close closes the front window, Minimize
      removes it from the visible window set, and Zoom, full screen, and Window
      → Move & Resize remain available from the system menu.
- [ ] Dashboard and replay tear-offs open resizable native windows. A restored
      titled window is clamped to a visible screen frame rather than reopening
      off-screen.

## Automated checks

Run Mac builds serially with other Xcode builds because the project shares
default DerivedData. `GetHogMacTests` uses Swift Testing: use the nonzero
`Test run with N tests` count, not the adjacent empty XCTest shell.

```bash
xcodebuild build -project GetHog.xcodeproj -scheme GetHogMac -destination 'platform=macOS'
xcodebuild test -project GetHog.xcodeproj -scheme GetHogMac -destination 'platform=macOS' \
  -only-testing:GetHogMacTests
xcodebuild test -project GetHog.xcodeproj -scheme GetHogMac -destination 'platform=macOS' \
  -parallel-testing-enabled NO -only-testing:GetHogMacUITests
xcodebuild build -project GetHog.xcodeproj -scheme GetHogMac \
  -destination 'platform=macOS' -configuration Release CODE_SIGNING_ALLOWED=NO
```

The UI suite requires an unlocked macOS GUI session. If the screen is locked,
the app can launch in the background and every UI case can fail before an
assertion; that is an environment failure, not evidence about this checklist.

## Manual system surfaces

- [ ] Add the Metric, Health, and Flag Mac widgets from the system gallery;
      verify synthetic snapshot rendering in light and dark appearance and a
      flag-toggle round trip.
- [ ] Check the menu-bar popover without another status-bar utility obscuring
      it: headline metric, health state, quick flag toggle when permitted, and
      the "Keep GetHog in the menu bar when the window is closed" setting.
- [ ] Verify Focus Filter registration and filtering in System Settings.
- [ ] Use synthetic data or an authorized live account to inspect the
      retention-cell hover treatment. Keep any live screenshots under ignored
      `build/`; committed evidence must remain synthetic.

## Archive checks

- [ ] Inspect the first signed archive's entitlements for a non-empty team-ID
      prefix on the App Group in both GetHogMac and GetHogMacWidgets.
- [ ] Confirm `LSApplicationCategoryType` in the archived Mac app and prepare
      the screenshot scheme only when Mac App Store assets are needed.
