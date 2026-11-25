//
//  ApplicationRelauncher.swift
//  boringNotch
//
//  Created by Corentin132 on 03/10/2025.
//

import AppKit

enum ApplicationRelauncher {
    static func restart() {
        let workspace = NSWorkspace.shared

        // Relaunch THIS bundle, not whatever copy LaunchServices resolves the
        // bundle id to (dev builds register several), so the hook launchers
        // keep pointing at the app the user is actually running.
        let appURL = Bundle.main.bundleURL

        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        // Keep SuperNotch's own switches (e.g. SUPERNOTCH_SKIP_HOOK_INSTALL);
        // a LaunchServices launch would otherwise drop them.
        configuration.environment = ProcessInfo.processInfo.environment
            .filter { $0.key.hasPrefix("SUPERNOTCH_") }

        workspace.openApplication(at: appURL, configuration: configuration, completionHandler: nil)

        NSApplication.shared.terminate(nil)
    }
}
