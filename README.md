# RTL Fixer for macOS

RTL Fixer is a small menu bar app that helps with Arabic/Hebrew direction across macOS apps without modifying those apps.

Its main mode copies selected text and shows it in a floating RTL viewer window. It does not patch application bundles, edit `app.asar`, or re-sign other apps.

## Features

- Floating RTL viewer window.
- Accessibility container picker that extracts all text exposed inside a chosen UI element without OCR.
- Direction mode: Auto, RTL, or LTR.
- Auto-detects simple code/terminal lines and keeps them LTR.
- Refresh button to read the current selection again.
- Pin mode to keep the window above other apps.
- Search inside the viewed text.
- Copy plain text or copy text wrapped with RTL marks.
- Clipboard fallback when selected text cannot be read.
- History menu for the last 10 viewed snippets.
- App icon and menu bar app behavior.

## Shortcuts

- `Control + Option + E`: Pick a UI container, then extract all of its Accessibility text.
- Double-tap `Option`: Show selected text in the RTL viewer.
- `Control + Option + S`: Select a screen region and OCR it into the RTL viewer.
- `Control + Option + C`: Show clipboard text in the RTL viewer.

## Permissions

macOS will ask for Accessibility permission because the app reads selected text and the Accessibility tree of picked UI containers.
macOS will ask for Screen Recording permission when using OCR region capture.

Enable it from:

`System Settings -> Privacy & Security -> Accessibility -> RTL Fixer`

## Limits

Container picking works when the target app exposes its content through macOS Accessibility. While picking, move over an element, use the scroll wheel to choose a parent or child container, click to capture, or press Escape to cancel. Apps that hide their accessibility tree may still require OCR.
