// Models/SenderRole.swift
import Foundation

// Make Codable using String raw values
enum SenderRole: String, Codable {
    case user
    case agent
}
