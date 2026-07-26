// Plonker Blocker — Copyright 2026 RoundDarkMatter
// SPDX-License-Identifier: Apache-2.0

import AppKit
import Security

// Shared administrator-authorization gate, used by both the manager app and the
// per-app launcher stubs.
enum Gate {

    /// Outcome of an authorization prompt. `failed` means the user entered a
    /// wrong password (the dialog exhausts its own retries first); `cancelled`
    /// means they dismissed it.
    enum Outcome { case authorized, cancelled, failed }

    /// Presents the native macOS admin dialog and reports the outcome. No
    /// credential caching: every call demands a fresh authentication.
    static func authorize(prompt: String) -> Outcome {
        var authRef: AuthorizationRef?
        let createStatus = AuthorizationCreate(nil, nil, [], &authRef)
        guard createStatus == errAuthorizationSuccess, let authRef else {
            return .failed
        }
        defer { AuthorizationFree(authRef, [.destroyRights]) }

        let status: OSStatus = prompt.withCString { promptValue -> OSStatus in
            kAuthorizationEnvironmentPrompt.withCString { promptKey -> OSStatus in
                var envItem = AuthorizationItem(
                    name: promptKey,
                    valueLength: strlen(promptValue),
                    value: UnsafeMutableRawPointer(mutating: promptValue),
                    flags: 0
                )
                return withUnsafeMutablePointer(to: &envItem) { envItemPtr -> OSStatus in
                    var environment = AuthorizationEnvironment(count: 1, items: envItemPtr)
                    return "system.privilege.admin".withCString { rightName -> OSStatus in
                        var rightItem = AuthorizationItem(
                            name: rightName, valueLength: 0, value: nil, flags: 0
                        )
                        return withUnsafeMutablePointer(to: &rightItem) { rightItemPtr -> OSStatus in
                            var rights = AuthorizationRights(count: 1, items: rightItemPtr)
                            let flags: AuthorizationFlags = [.interactionAllowed, .extendRights]
                            return AuthorizationCopyRights(authRef, &rights, &environment, flags, nil)
                        }
                    }
                }
            }
        }
        if status == errAuthorizationSuccess { return .authorized }
        if status == errAuthorizationCanceled { return .cancelled }
        return .failed
    }

    /// Convenience Bool wrapper — true only on successful admin authentication.
    static func requestAdminAuthorization(prompt: String) -> Bool {
        authorize(prompt: prompt) == .authorized
    }

    /// Modal "permission denied" alert.
    static func showDenied(appName: String) {
        // Ensure we're frontmost — an .accessory launcher's modal can otherwise
        // appear behind whatever app had focus after the auth dialog closed.
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = "Permission Denied"
        alert.informativeText =
            "“\(appName)” is protected by Plonker Blocker and can only be opened with "
          + "administrator approval.\n\nYou do not have permission to open it."
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}
