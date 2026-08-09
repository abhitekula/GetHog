# Unified Dashboard Hub Design

## Purpose

The regular-width dashboard landing screen currently nests a dashboard list beside a project overview. On Vision, iPad, and Mac this creates three competing vertical bands: the platform navigation, a narrow dashboard list, and a wide overview whose content occupies only part of its width. The result is a large inactive middle area and charts compressed against the trailing edge.

The dashboard landing experience will become one cohesive hub on regular-width Vision, iPad, and Mac. Compact iPhone behavior remains a list that pushes a dashboard detail.

## Layout

The platform shell keeps its existing primary navigation. Inside the Dashboards destination, regular width renders one scrollable content surface rather than another `NavigationSplitView`.

The hub contains:

1. A compact project signal header with project name and dashboard/computed/generated counts.
2. The pinned dashboard preview, using an adaptive tile grid that can consume the full available width.
3. Search and dashboard sections in the same scroll surface. Pinned and remaining dashboards use adaptive cards rather than a permanently narrow list column.
4. Freshness and loading, empty, failure, locked, and no-search-result states in the same content hierarchy.

At narrower regular widths, these regions stack vertically. At wider widths, the layout may place the project signal and pinned preview side by side, but neither receives a fixed trailing column and the dashboard collection remains part of the same hub.

## Navigation

Selecting a dashboard replaces the hub in the same destination content pane with `DashboardDetailView`. The detail toolbar provides a clear `All dashboards` return that restores the hub, search text, scroll-owned model state, and current project scope.

The existing `OpenDetails` selection remains the source of truth so deep links, restoration, detached Mac windows, and cross-size transitions continue to resolve the same selected dashboard. The regular-width presentation changes; selection ownership does not.

On compact iPhone, the existing list and navigation destination remain unchanged.

## State and request behavior

`DashboardsStore` remains owned once by `DashboardsRoot`. The unified hub must not duplicate its task or dashboard request. The pinned preview continues to use the existing cached, non-refreshing dashboard-detail request and must not recompute an insight.

Switching between hub and detail must not:

- reload the dashboard list when the project and store are unchanged;
- send a duplicate pinned-detail request after an ordinary return;
- lose the active search query;
- publish a stale project response after a project or authentication change.

Locked, loading, failed, and successfully empty states each replace the hub content honestly. A search with no matches retains the project summary and presents a local no-results state for the dashboard collection.

## Platform behavior

- **Vision:** remove the inner dashboard split so the section destination controls lead into one spatial content surface.
- **iPad:** use the same unified hub in regular width; compact multitasking retains the compact list-to-detail flow.
- **Mac:** use the unified hub inside the Mac shell. Existing refresh commands, project switcher, context menus, and open-in-new-window actions remain available.
- **iPhone/tvOS/watchOS:** no layout change from this design.

## Verification

Behavior coverage will be written before production changes and will prove:

- regular width chooses the unified-hub policy while compact width keeps list-to-detail;
- the regular hub has no nested dashboard split-column contract;
- selecting and returning preserves search and store identity;
- remounting and returning do not duplicate dashboard-list or pinned-preview requests;
- locked, loading, failure, empty, loaded, and no-search-result states remain distinguishable.

Rendered acceptance will cover current live or deterministic data on Vision, iPad regular and compact widths, and Mac default/narrow/wide windows. The key visual oracle is that project facts, pinned charts, and dashboard cards use the available center width without a persistent empty column, while a selected dashboard still receives the full content surface.
