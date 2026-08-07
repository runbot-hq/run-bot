// SkyLightBridge.swift
// MenuBarKit
//
// Runtime-only bridge to the private SkyLight symbols used to hold the system
// menu bar visible. Missing symbols degrade to an unavailable backend; they
// never crash or prevent the panel from opening.

import CoreGraphics
import Darwin

/// Runtime-only bridge to the private SkyLight symbols used to hold the system
/// menu bar visible. Missing symbols must degrade to an unavailable backend;
/// they must never crash or prevent the panel from opening.
enum MBKSkyLight {
    typealias ConnectionID = Int32

    typealias MainConnectionIDFunction =
        @convention(c) () -> ConnectionID

    typealias SetMenuBarVisibilityOverrideFunction =
        @convention(c) (
            ConnectionID,
            CGDirectDisplayID,
            Bool
        ) -> CGError

    /// The dlopen handle is intentionally nonisolated(unsafe) — it is assigned
    /// once at static initialization and never modified. This is safe because
    /// the handle pointer is read-only after load and the process never calls
    /// dlclose on it.
    private nonisolated(unsafe) static let handle: UnsafeMutableRawPointer? = dlopen(
        "/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight",
        RTLD_LAZY | RTLD_LOCAL
    )

    private static func load<T>(
        _ name: String,
        as _: T.Type
    ) -> T? {
        guard let handle else { return nil }
        return name.withCString { cName in
            guard let symbol = dlsym(handle, cName) else { return nil }
            return unsafeBitCast(symbol, to: T.self)
        }
    }

    static let mainConnectionID = load(
        "SLSMainConnectionID",
        as: MainConnectionIDFunction.self
    )

    static let setMenuBarVisibilityOverride = load(
        "SLSSetMenuBarVisibilityOverrideOnDisplay",
        as: SetMenuBarVisibilityOverrideFunction.self
    )

    }
