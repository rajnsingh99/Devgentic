//
//  AttachedFileSD.swift
//  Devgentic
//
//  Created by Raj Singh on 03/04/26.
//  SwiftData models replacing AttachedTextFileEntity and AttachedImageFileEntity (CoreData).
//

import Foundation
import SwiftData

@Model
final class AttachedTextFileSD {
    @Attribute(.unique) var id: UUID
    var name: String
    var url: String
    var fileExtension: String
    var content: String
    var size: Int64

    func toStruct() -> AttachedTextFile {
        AttachedTextFile(id: id, name: name, url: URL(string: url)!,
                         fileExtension: fileExtension, content: content, size: size)
    }

    static func from(_ file: AttachedTextFile) -> AttachedTextFileSD {
        AttachedTextFileSD(id: file.id, name: file.name, url: file.url.absoluteString,
                           fileExtension: file.fileExtension, content: file.content, size: file.size)
    }

    init(id: UUID, name: String, url: String, fileExtension: String, content: String, size: Int64) {
        self.id = id; self.name = name; self.url = url
        self.fileExtension = fileExtension; self.content = content; self.size = size
    }
}

@Model
final class AttachedImageFileSD {
    @Attribute(.unique) var id: UUID
    var name: String
    var url: String
    var fileExtension: String
    /// The transcript's durable copy of the image — `AttachedImageCardView` renders
    /// from these bytes because the source `url` goes stale (moved/deleted files,
    /// sandbox scope not surviving relaunch). `.externalStorage` keeps the blob out
    /// of the SQLite row (sidecar file, managed by the store) so fetching messages
    /// doesn't drag megabytes of pixels through the row cache. Storage-option-only
    /// change: lightweight migration; existing inline blobs remain readable.
    @Attribute(.externalStorage) var binaryData: Data
    var size: Int64

    func toStruct() -> AttachedImageFile {
        AttachedImageFile(id: id, name: name, url: URL(string: url)!,
                          fileExtension: fileExtension, binaryData: binaryData, size: size)
    }

    static func from(_ file: AttachedImageFile) -> AttachedImageFileSD {
        AttachedImageFileSD(id: file.id, name: file.name, url: file.url.absoluteString,
                            fileExtension: file.fileExtension, binaryData: file.binaryData, size: file.size)
    }

    init(id: UUID, name: String, url: String, fileExtension: String, binaryData: Data, size: Int64) {
        self.id = id; self.name = name; self.url = url
        self.fileExtension = fileExtension; self.binaryData = binaryData; self.size = size
    }
}
