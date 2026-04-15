//
//  CheckboxView.swift
//  Devgentic
//
//  Created by Raj Singh on 13/08/25.
//

import SwiftUI

struct CheckboxView: View {
    @Binding var isChecked: Bool
    
    private let size: CGFloat = 20
    private let cornerRadius: CGFloat = 5
    private let checkmarkLineWidth: CGFloat = 2.5
    private let animationDuration = 0.15

    var body: some View {
        ZStack {
            // The outer box
            RoundedRectangle(cornerRadius: cornerRadius)
                .strokeBorder(isChecked ? Color.accentColor : Color.secondary.opacity(0.5), lineWidth: 2)
                .background(
                    RoundedRectangle(cornerRadius: cornerRadius)
                        .fill(isChecked ? Color.accentColor : Color.clear)
                )
                .frame(width: size, height: size)

            // The checkmark, which scales in when checked
            if isChecked {
                Image(systemName: "checkmark")
                    .font(.system(size: size * 0.6, weight: .bold)) // Fixed size: user-configured checkbox size
                    .foregroundColor(.white)
                    .transition(.scale(scale: 0.5).combined(with: .opacity))
            }
        }
        .allowsHitTesting(false)
    }
}

struct CheckboxView_Previews: PreviewProvider {
    struct PreviewWrapper: View {
        @State private var isChecked = false
        @State private var isCheckedTrue = true

        var body: some View {
            VStack(spacing: 20) {
                Text("Modern Checkbox")
                    .font(.headline)
                
                HStack(spacing: 15) {
                    CheckboxView(isChecked: $isChecked)
                    Text("Unchecked")
                }
                
                HStack(spacing: 15) {
                    CheckboxView(isChecked: $isCheckedTrue)
                    Text("Checked")
                }
            }
            .padding()
            .preferredColorScheme(.dark)
            .frame(width: 200, height: 150)
        }
    }

    static var previews: some View {
        PreviewWrapper()
    }
}
