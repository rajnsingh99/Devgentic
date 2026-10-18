// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  UIConstants.swift
//  Devgentic
//
//  Created by Raj Singh.
//

import Foundation

// MARK: - Z-Index Layers

/// Centralized z-index values for overlay layering in the chat area.
/// Higher values render on top. Used by ChatHistoryView and its overlays.
enum ViewZIndex {
    /// Base content layer (messages, lists).
    static let base: Double = 0
    /// Scroll-to-bottom floating action button.
    static let fab: Double = 5
    /// Speech control island (above FAB).
    static let speechControl: Double = 6
    /// Search bar overlay (above all content).
    static let searchBar: Double = 10
    /// Modal/alert level (reserved for future use).
    static let modal: Double = 100
}

// MARK: - Layout Constants

/// Standardized layout values for the single-window interface.
enum ViewLayout {
    /// Maximum content width for all container views and DynamicIslandBar.
    /// Tuned to ~880 (down from 1000) so long-form chat lines stay in a more readable
    /// measure; the transcript, composer, and DynamicIslandBar all share this value so
    /// they remain width-aligned.
    static let maxContentWidth: CGFloat = 1000
    /// Standard padding for ScrollView content in container views.
    static let containerPadding: CGFloat = 24
    /// Standard sidebar row padding.
    static let sidebarRowHorizontalPadding: CGFloat = 8
    static let sidebarRowVerticalPadding: CGFloat = 8
}

// MARK: - Observable Pattern Guide
//
// All view models and services have been migrated to @Observable.
// No ObservableObject remains in the UI layer.
//
// Canonical patterns for consuming state in views:
//
// 1. @Observable singletons:
//    `private var service = XService.shared`  (or computed property)
//    Use `@Bindable` if Bindings are needed: `@Bindable private var x = X.shared`
//
// 2. @Observable injected via Environment:
//    `@Environment(XService.self) private var service`
//
// 3. @Observable view-local:
//    `@State private var viewModel = XViewModel()`
//
// Bridging @Observable → legacy ObservableObject services (OllamaService, PromptService):
//    Use `withObservationTracking { _ = svc.prop } onChange: { ... }`
//    Or keep a targeted Combine `$property.sink` with `@ObservationIgnored var cancellables`
