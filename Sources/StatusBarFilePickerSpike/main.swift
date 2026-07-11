// main.swift
// StatusBarFilePickerSpike
//
// Entry point for the isolated statusbar + file-picker spike.
// Run with: swift run StatusBarFilePickerSpike
import AppKit

let delegate = StatusBarFilePickerAppDelegate()
NSApplication.shared.delegate = delegate
NSApplication.shared.run()
