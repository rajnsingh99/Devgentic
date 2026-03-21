//
//  DownloadManager.swift
//  Devgentic
//
//  Created by Raj Singh on 19/03/26.
//
//  Central aggregation layer for tracking model downloads across
//  all backends (Ollama, MLX). Observes each service's @Published
//  download state via Combine and synthesizes unified DownloadEntry
//  objects for the sidebar and store views to consume.
//

import SwiftUI
import Combine

// MARK: - Models

enum ModelBackendType: String, Equatable, Hashable {
    case ollama = "Ollama"
    case mlx = "MLX"

    var icon: String {
        switch self {
        case .ollama: return "server.rack"
        case .mlx: return "apple.logo"
        }
    }

    var tintColor: Color {
        switch self {
        case .ollama: return .blue
        case .mlx: return .purple
        }
    }
}

enum DownloadStatus: Equatable, Hashable {
    case downloading
    case completed
    case failed(message: String?)
    case cancelled
}

struct DownloadEntry: Identifiable, Equatable {
    let id: UUID
    let backend: ModelBackendType
    let modelName: String
    let startedAt: Date
    var progress: Double
    var status: DownloadStatus

    static func == (lhs: DownloadEntry, rhs: DownloadEntry) -> Bool {
        lhs.id == rhs.id &&
        lhs.progress == rhs.progress &&
        lhs.status == rhs.status
    }
}

// MARK: - Download Manager

@MainActor
final class DownloadManager: ObservableObject {
    static let shared = DownloadManager()

    @Published var activeDownloads: [DownloadEntry] = []
    @Published var completedDownloads: [DownloadEntry] = []

    var hasActiveDownloads: Bool { !activeDownloads.isEmpty }
    var activeCount: Int { activeDownloads.count }

    private var cancellables = Set<AnyCancellable>()

    // Track current active entry IDs per backend to detect transitions
    private var ollamaActiveID: UUID?
    private var mlxActiveID: UUID?

    private init() {
        bindOllama()
        bindMLX()
    }

    // MARK: - Actions

    func cancelDownload(for entry: DownloadEntry) {
        switch entry.backend {
        case .ollama:
            OllamaService.shared.cancelPullModel()
        case .mlx:
            MLXModelService.shared.cancelDownload()
        }
    }

    func clearCompleted() {
        completedDownloads.removeAll()
    }

    func removeCompleted(_ entry: DownloadEntry) {
        completedDownloads.removeAll { $0.id == entry.id }
    }

    // MARK: - Ollama Binding

    private func bindOllama() {
        let service = OllamaService.shared

        Publishers.CombineLatest3(
            service.$isPullingModel,
            service.$pullProgress,
            service.$modelToPull
        )
        .combineLatest(service.$modelPullError)
        .receive(on: RunLoop.main)
        .sink { [weak self] combined, errorMessage in
            let (isPulling, progress, name) = combined
            self?.reconcileOllamaState(
                isPulling: isPulling,
                progress: progress,
                name: name,
                errorMessage: errorMessage
            )
        }
        .store(in: &cancellables)
    }

    private func reconcileOllamaState(isPulling: Bool, progress: Double, name: String, errorMessage: String?) {
        if isPulling && !name.isEmpty {
            if let existingIndex = activeDownloads.firstIndex(where: { $0.id == ollamaActiveID }) {
                // Update existing entry
                activeDownloads[existingIndex].progress = progress
            } else {
                // New download started
                let entry = DownloadEntry(
                    id: UUID(),
                    backend: .ollama,
                    modelName: name,
                    startedAt: Date(),
                    progress: progress,
                    status: .downloading
                )
                ollamaActiveID = entry.id
                activeDownloads.append(entry)
            }
        } else if let activeID = ollamaActiveID {
            // Download ended — move to completed
            if let index = activeDownloads.firstIndex(where: { $0.id == activeID }) {
                var entry = activeDownloads.remove(at: index)
                if let error = errorMessage, !error.isEmpty {
                    entry.status = .failed(message: error)
                } else if entry.progress < 0.99 {
                    entry.status = .cancelled
                } else {
                    entry.status = .completed
                    entry.progress = 1.0
                }
                completedDownloads.insert(entry, at: 0)
            }
            ollamaActiveID = nil
        }
    }

    // MARK: - MLX Binding

    private func bindMLX() {
        let service = MLXModelService.shared

        Publishers.CombineLatest3(
            service.$isDownloading,
            service.$downloadProgress,
            service.$currentDownloadName
        )
        .combineLatest(service.$errorMessage)
        .receive(on: RunLoop.main)
        .sink { [weak self] combined, errorMessage in
            let (isDownloading, progress, name) = combined
            self?.reconcileMLXState(
                isDownloading: isDownloading,
                progress: progress,
                name: name,
                errorMessage: errorMessage
            )
        }
        .store(in: &cancellables)
    }

    private func reconcileMLXState(isDownloading: Bool, progress: Double, name: String, errorMessage: String?) {
        if isDownloading && !name.isEmpty {
            if let existingIndex = activeDownloads.firstIndex(where: { $0.id == mlxActiveID }) {
                // Update existing entry
                activeDownloads[existingIndex].progress = progress
            } else {
                // New download started
                let entry = DownloadEntry(
                    id: UUID(),
                    backend: .mlx,
                    modelName: name,
                    startedAt: Date(),
                    progress: progress,
                    status: .downloading
                )
                mlxActiveID = entry.id
                activeDownloads.append(entry)
            }
        } else if let activeID = mlxActiveID {
            // Download ended — move to completed
            if let index = activeDownloads.firstIndex(where: { $0.id == activeID }) {
                var entry = activeDownloads.remove(at: index)
                if let error = errorMessage, !error.isEmpty {
                    entry.status = .failed(message: error)
                } else if entry.progress < 0.99 {
                    entry.status = .cancelled
                } else {
                    entry.status = .completed
                    entry.progress = 1.0
                }
                completedDownloads.insert(entry, at: 0)
            }
            mlxActiveID = nil
        }
    }
}
