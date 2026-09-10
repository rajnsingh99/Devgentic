// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2026 Raj Singh
////
////  SetupCompleteScreen.swift
////  Devgentic
////
////  Created by Raj Singh on 19/05/25.
////
//
//// SetupCompleteScreen.swift
//// This view might not be strictly necessary if onComplete directly transitions
//// to the MainUI, but can be used for a brief confirmation.
//// The current AgentOnboardingViewModel calls onComplete directly.
//// If you want a screen like this, you'd add a .complete step to the ViewModel
//// and transition to this view before calling onComplete.
//
//import SwiftUI
//
//struct SetupCompleteScreen: View {
//    var onFinish: () -> Void // Action to proceed to main app
//
//    var body: some View {
//        VStack(spacing: 25) {
//            Spacer()
//
//            Image(systemName: "checkmark.circle.fill")
//                .resizable()
//                .scaledToFit()
//                .frame(width: 80, height: 80)
//                .foregroundColor(.green)
//
//            Text("Setup Complete!")
//                .font(.largeTitle)
//                .fontWeight(.bold)
//
//            Text("Your Devgentic AI Agent is now configured and ready to use.")
//                .font(.title3)
//                .multilineTextAlignment(.center)
//                .foregroundColor(.secondary)
//                .padding(.horizontal, 40)
//            
//            Spacer()
//
//            Button(action: onFinish) {
//                Text("Continue to App")
//                    .fontWeight(.semibold)
//                    .frame(minWidth: 0, maxWidth: 200)
//                    .padding()
//                    .foregroundColor(.white)
//                    .background(Color.accentColor)
//                    .cornerRadius(10)
//            }
//            .buttonStyle(.plain)
//            .keyboardShortcut(.defaultAction)
//            .padding(.bottom, 30)
//            
//            Spacer()
//        }
//        .padding()
//    }
//}
//
//// Preview
//struct SetupCompleteScreen_Previews: PreviewProvider {
//    static var previews: some View {
//        SetupCompleteScreen(onFinish: { print("Finished onboarding!") })
//            .frame(width: 500, height: 400)
//    }
//}
