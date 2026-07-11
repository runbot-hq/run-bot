// Logging.swift
// RunBotSpike - spike/swiftui-nav-sheet
//
// Lightweight tagged logger. All spike log calls use this so output is
// grep-friendly by subsystem (e.g. grep NavSheet\]\[AnchoredSheet logs).
//
// WHY NOT os.Logger / OSLog:
//   OSLog output doesn't appear in the terminal during `swift run`, only in
//   Console.app. For a spike that is run from the terminal, print() is the
//   right call — output lands directly in the session.

import Foundation

func log(_ subsystem: String, _ message: String) {
    print("[NavSheet][\(subsystem)] \(message)")
}
