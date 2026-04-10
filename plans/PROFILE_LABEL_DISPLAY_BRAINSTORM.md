# Profile Label Display on macOS — Brainstorm

## Goal
Show the profile label prominently on macOS so the user can tell which profile each window belongs to — both visually in the window and in the Window menu.

## Current View Hierarchy
```
WindowGroup(for: Profile.ID.self)
  → ProfileWindowView
    → SessionRootView
      → AppRootView
        → ContentView
          → NavigationSplitView
            sidebar: SidebarView (has .navigationTitle("Moolah") — invisible)
            detail: various views (each sets its own .navigationTitle e.g. "Analysis")
```

## Key Discoveries
1. `.navigationTitle` on the sidebar column is **completely invisible** on macOS — NavigationSplitView suppresses it.
2. `.navigationSubtitle` on the sidebar is also invisible.
3. The **Window menu** shows the **detail view's** `.navigationTitle` (e.g. "Analysis").
4. `.navigationTitle` set higher in the hierarchy (on NavigationSplitView or ProfileWindowView) gets overridden by the detail view's title.
5. NSViewRepresentable setting NSWindow.title gets overridden by NavigationSplitView.

---

## Part A: Profile Label in the Sidebar

### A1. Replace SidebarView's .navigationTitle with profile label
- **How:** Change `.navigationTitle("Moolah")` to `.navigationTitle(profile.label)`
- **Result:** TRIED — title is invisible. macOS NavigationSplitView hides sidebar titles entirely.

### A2. Use .navigationSubtitle for profile label
- **How:** Add `.navigationSubtitle(profile.label)` on SidebarView
- **Result:** TRIED — also invisible. Same suppression.

### A3. safeAreaInset(edge: .top) on the sidebar List
- **How:** Pin a Text view above the scrollable List content
- **Result:** TRIED — **WORKS.** Profile label visible at top of sidebar, below toolbar area. Currently implemented.

### A4. safeAreaInset(edge: .top) on the sidebar (earlier attempt on ContentView)
- **Result:** TRIED — positioned below traffic lights, user rejected placement.

### A5. ToolbarItem(placement: .navigation)
- **Result:** TRIED — appeared in a weird blob to the right of the sidebar.

### A6. ToolbarItem(placement: .automatic)
- **Result:** TRIED — right-aligned, user wanted left-aligned.

**Current winner: A3** — safeAreaInset on SidebarView's List.

---

## Part B: Window Menu / Window Title

The Window menu currently shows "Analysis" for all windows. Need each window to show its profile name.

### B1. .navigationTitle on NavigationSplitView itself
- **How:** Put `.navigationTitle(session.profile.label)` on the NavigationSplitView in ContentView
- **Result:** TRIED — overridden by detail view's title. No effect.

### B2. Prefix detail view titles with profile label
- **How:** Modify each detail view to accept and prepend a profile prefix, e.g. "Moolah — Analysis"
- **Pros:** Clear identification in Window menu. Each view shows its profile.
- **Cons:** Need to thread profile label into every detail view. More invasive.
- **Status:** NOT TRIED

### B3. ViewModifier wrapping detail column content
- **How:** Create a modifier like `.profileTitle(session.profile.label)` that wraps the detail column in ContentView. The modifier would apply `.navigationTitle("\(profileLabel) — \(innerTitle)")`.
- **Pros:** Single point of change in ContentView instead of modifying every detail view.
- **Cons:** SwiftUI may not support intercepting/composing inner navigation titles this way.
- **Status:** NOT TRIED

### B4. NSViewRepresentable to observe and override NSWindow.title
- **How:** Embed an NSView that observes `window.title` changes via KVO and prepends the profile label whenever the title changes.
- **Pros:** Reacts to any title change from NavigationSplitView. Single implementation point.
- **Cons:** Relies on AppKit internals. The simple version (set once) was tried and overridden; KVO version might work.
- **Result:** KVO version **WORKS**. Observes window.title changes and prepends profile label. Currently implemented. Undesirable complexity but the only approach that controls the window title.

### B5. .navigationDocument to influence window title
- **How:** Use `.navigationDocument(session.profile.label)` or similar API on the NavigationSplitView.
- **Pros:** Native SwiftUI approach for window document identification.
- **Cons:** Designed for document-based apps, may not apply. May show a file icon.
- **Status:** NOT TRIED

### B6. WindowGroup title parameter
- **How:** Use `WindowGroup("Moolah", for: Profile.ID.self)` to set a static window group title.
- **Pros:** Simple, one-line change in MoolahApp.
- **Cons:** Static — same for all windows, can't include profile name. But might set a base title.
- **Status:** NOT TRIED

### B7. Custom window title observer using onAppear/onChange
- **How:** In ProfileWindowView, use `.onAppear` and `.onChange(of: selection)` to set `NSApp.keyWindow?.title` whenever the detail view changes. Schedule it with a short delay to run after NavigationSplitView sets its title.
- **Pros:** Can compose "Profile — DetailTitle" dynamically.
- **Cons:** Fragile timing dependency. May flash wrong title briefly.
- **Result:** TRIED — no effect. WindowGroup title parameter does not override the detail view's title.

**Recommended order to try:** B4 (KVO) → B2
