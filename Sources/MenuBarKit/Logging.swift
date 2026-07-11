// Logging.swift
// MenuBarKit
//
// Lightweight tagged logger. All MenuBarKit log calls use this so output is
// grep-friendly: grep 'MBK][' 
//
// WHY NOT os.Logger / OSLog:
//   OSLog output doesn't appear in the terminal during `swift run`, only in
//   Console.app. For development and spike runs, print() is correct.

import Foundation

public func mbkLog(_ subsystem: String, _ message: String) {
    print("[MBK][\(subsystem)] \(message)")
}
