# 0.2.6 Responsive UI review

## Reported problem
On a Mac, 0.2.5 opened too large. The lower part of the window could be outside the usable desktop and the window could not be made small enough.

## Root cause
- MainWindow explicitly requested 1480 x 940.
- Several control groups used one long horizontal row.
- Child page size hints propagated through QTabWidget and effectively raised the window's minimum useful size.
- Pages did not have an outer scroll area, so content below the visible desktop could not always be reached.

## Fix
- Initial size is calculated from `QScreen.availableGeometry()` and never exceeds the usable desktop.
- Main window minimum size is 640 x 480.
- Every page is hosted inside a widget-resizable `QScrollArea` with horizontal/vertical scrollbars as needed.
- The tab bar uses scroll buttons and elides labels instead of forcing the whole window wider.
- Wide control rows were converted to compact grids:
  - connection/readiness controls
  - live marker buttons
  - drive marker buttons
  - offline replay controls
  - payload A/B controls
  - correlation controls
  - ECU saved-session controls
- Large drive-test buttons remain easy to press, but their minimum height was reduced modestly.

## Expected behavior
- The window is freely resizable on macOS.
- On a small display, lower content remains reachable by vertical scrolling.
- If a page is still wider than the viewport, only that page gets a horizontal scrollbar; the main window is not forced wider.
- On a large external monitor, the app does not open excessively large (initial size capped at 1280 x 820).

## Automated verification
`recommended_window_size()` is tested with 1440x900, 1280x800, 1024x768, 800x600, and 640x480 usable desktops and must never return a size larger than the available screen.

Qt visual/offscreen rendering is not executed in the build container because PySide6 is not installed there. Functional and non-Qt regressions still run through pytest.
