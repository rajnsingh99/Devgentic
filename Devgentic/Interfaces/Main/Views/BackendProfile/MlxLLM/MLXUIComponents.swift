//
//  MLXUIComponents.swift
//  Devgentic
//
//  Created by Raj Singh on 04/02/26.
//

import SwiftUI

/// A visual badge representing a specific model capability (e.g. "Reasoning", "Vision").
struct CapabilityBadge: View {
    let capability: MLXModelCapability
    
    var color: Color {
        switch capability {
        case .reasoning: return .purple
        case .toolUse: return .orange
        case .vision: return .blue
        case .coding: return .green
        case .textGeneration: return .gray
        }
    }
    
    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: capability.icon)
            Text(capability.rawValue)
        }
        .font(.caption2.weight(.medium))
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(color.opacity(0.1))
        .foregroundColor(color)
        .cornerRadius(4)
        .overlay(
            RoundedRectangle(cornerRadius: 4)
                .stroke(color.opacity(0.3), lineWidth: 1)
        )
    }
}
