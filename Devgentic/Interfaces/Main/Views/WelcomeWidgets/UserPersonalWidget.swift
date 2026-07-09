//
//  UserPersonalWidget.swift
//  Devgentic
//
//  Personal-profile summary as a registered welcome widget.
//

import SwiftUI

/// Personal profile summary card, gated behind the Core-Intelligence
/// "user personal" feature flag.
struct UserPersonalWidget: WelcomeWidget {
    let id = "user_personal"
    let priority = 20

    func isVisible() -> Bool {
        UserDefaults.standard.bool(forKey: AppSettings.ciFeatureUserPersonalKey)
    }

    func makeBody() -> AnyView {
        AnyView(UserPersonalWelcomeCard())
    }
}
