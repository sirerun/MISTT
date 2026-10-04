# Xcode UI previews

Open `MISTTPreview.xcodeproj` in Xcode, select `PreviewApp.swift`, and enable **Editor → Canvas**. Press **Resume** in the canvas. Named previews show Muted, On with three clients, and Unavailable. Running this preview host also lets you click the microphone to toggle its fixture.

This target compiles the production `MicrophoneWindow.swift` and presentation model with a preview-only controller. It has no capture, relay, updater, Sparkle, or network dependency. It previews UI, not end-to-end audio behavior.

Derived data is configured on the external BuildOffload volume. The isolated target built successfully using Xcode 27.0 on 2026-10-04; Canvas rendering is not confirmed. Full native build, capture validation, installation, and runtime acceptance remain deferred.

The preview build fixed the production contrast environment key, unsupported live-region modifier, and missing client-count return. Status decoding moved unchanged to `RelayStatusDecoding.swift` so this target includes only the presentation model.
