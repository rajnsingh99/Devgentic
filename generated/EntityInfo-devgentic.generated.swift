// Generated using the ObjectBox Swift Generator — https://objectbox.io
// DO NOT EDIT

// swiftlint:disable all
import ObjectBox
import Foundation

// MARK: - Entity metadata

extension ParentDocumentEntity: ObjectBox.Entity {}
extension ChildChunkEntity: ObjectBox.Entity {}

extension ParentDocumentEntity: ObjectBox.__EntityRelatable {
    internal typealias EntityType = ParentDocumentEntity

    internal var _id: EntityId<ParentDocumentEntity> {
        return EntityId<ParentDocumentEntity>(self.id.value)
    }
}

extension ParentDocumentEntity: ObjectBox.EntityInspectable {
    internal typealias EntityBindingType = ParentDocumentEntityBinding

    /// Generated metadata used by ObjectBox to persist the entity.
    internal static let entityInfo = ObjectBox.EntityInfo(name: "ParentDocumentEntity", id: 2)

    internal static let entityBinding = EntityBindingType()

    fileprivate static func buildEntity(modelBuilder: ObjectBox.ModelBuilder) throws {
        let entityBuilder = try modelBuilder.entityBuilder(for: ParentDocumentEntity.self, id: 2, uid: 2945786103589142528)
        try entityBuilder.addProperty(name: "id", type: PropertyType.long, flags: [.id], id: 1, uid: 3871524690125618176)
        try entityBuilder.addProperty(name: "sourceMessageID", type: PropertyType.string, id: 2, uid: 4208963517832046592)
        try entityBuilder.addProperty(name: "conversationID", type: PropertyType.string, id: 3, uid: 5649271038461280256)
        try entityBuilder.addProperty(name: "fullTextContent", type: PropertyType.string, id: 4, uid: 6102843719584372736)
        try entityBuilder.addProperty(name: "timestamp", type: PropertyType.date, id: 5, uid: 7531926084731928576)

        try entityBuilder.lastProperty(id: 5, uid: 7531926084731928576)
    }
}

extension ParentDocumentEntity {
    /// Generated entity property information.
    ///
    /// You may want to use this in queries to specify fetch conditions, for example:
    ///
    ///     box.query { ParentDocumentEntity.id == myId }

    internal static var id: Property<ParentDocumentEntity, Id, Id> { return Property<ParentDocumentEntity, Id, Id>(propertyId: 1, isPrimaryKey: true) }

    /// Generated entity property information.
    ///
    /// You may want to use this in queries to specify fetch conditions, for example:
    ///
    ///     box.query { ParentDocumentEntity.sourceMessageID.startsWith("X") }

    internal static var sourceMessageID: Property<ParentDocumentEntity, String, Void> { return Property<ParentDocumentEntity, String, Void>(propertyId: 2, isPrimaryKey: false) }

    /// Generated entity property information.
    ///
    /// You may want to use this in queries to specify fetch conditions, for example:
    ///
    ///     box.query { ParentDocumentEntity.conversationID.startsWith("X") }

    internal static var conversationID: Property<ParentDocumentEntity, String, Void> { return Property<ParentDocumentEntity, String, Void>(propertyId: 3, isPrimaryKey: false) }

    /// Generated entity property information.
    ///
    /// You may want to use this in queries to specify fetch conditions, for example:
    ///
    ///     box.query { ParentDocumentEntity.fullTextContent.startsWith("X") }

    internal static var fullTextContent: Property<ParentDocumentEntity, String, Void> { return Property<ParentDocumentEntity, String, Void>(propertyId: 4, isPrimaryKey: false) }

    /// Generated entity property information.
    ///
    /// You may want to use this in queries to specify fetch conditions, for example:
    ///
    ///     box.query { ParentDocumentEntity.timestamp > 1234 }

    internal static var timestamp: Property<ParentDocumentEntity, Date, Void> { return Property<ParentDocumentEntity, Date, Void>(propertyId: 5, isPrimaryKey: false) }

    fileprivate func __setId(identifier: ObjectBox.Id) {
        self.id = Id(identifier)
    }
}

extension ObjectBox.Property where E == ParentDocumentEntity {
    /// Generated entity property information.
    ///
    /// You may want to use this in queries to specify fetch conditions, for example:
    ///
    ///     box.query { .id == myId }

    internal static var id: Property<ParentDocumentEntity, Id, Id> { return Property<ParentDocumentEntity, Id, Id>(propertyId: 1, isPrimaryKey: true) }

    /// Generated entity property information.
    ///
    /// You may want to use this in queries to specify fetch conditions, for example:
    ///
    ///     box.query { .sourceMessageID.startsWith("X") }

    internal static var sourceMessageID: Property<ParentDocumentEntity, String, Void> { return Property<ParentDocumentEntity, String, Void>(propertyId: 2, isPrimaryKey: false) }

    /// Generated entity property information.
    ///
    /// You may want to use this in queries to specify fetch conditions, for example:
    ///
    ///     box.query { .conversationID.startsWith("X") }

    internal static var conversationID: Property<ParentDocumentEntity, String, Void> { return Property<ParentDocumentEntity, String, Void>(propertyId: 3, isPrimaryKey: false) }

    /// Generated entity property information.
    ///
    /// You may want to use this in queries to specify fetch conditions, for example:
    ///
    ///     box.query { .fullTextContent.startsWith("X") }

    internal static var fullTextContent: Property<ParentDocumentEntity, String, Void> { return Property<ParentDocumentEntity, String, Void>(propertyId: 4, isPrimaryKey: false) }

    /// Generated entity property information.
    ///
    /// You may want to use this in queries to specify fetch conditions, for example:
    ///
    ///     box.query { .timestamp > 1234 }

    internal static var timestamp: Property<ParentDocumentEntity, Date, Void> { return Property<ParentDocumentEntity, Date, Void>(propertyId: 5, isPrimaryKey: false) }

}


/// Generated service type to handle persisting and reading entity data. Exposed through `ParentDocumentEntity.EntityBindingType`.
internal final class ParentDocumentEntityBinding: ObjectBox.EntityBinding, Sendable {
    internal typealias EntityType = ParentDocumentEntity
    internal typealias IdType = Id

    internal required init() {}

    internal func generatorBindingVersion() -> Int { 1 }

    internal func setEntityIdUnlessStruct(of entity: EntityType, to entityId: ObjectBox.Id) {
        entity.__setId(identifier: entityId)
    }

    internal func entityId(of entity: EntityType) -> ObjectBox.Id {
        return entity.id.value
    }

    internal func collect(fromEntity entity: EntityType, id: ObjectBox.Id,
                                  propertyCollector: ObjectBox.FlatBufferBuilder, store: ObjectBox.Store) throws {
        let propertyOffset_sourceMessageID = propertyCollector.prepare(string: UUIDConverter.convert(entity.sourceMessageID))
        let propertyOffset_conversationID = propertyCollector.prepare(string: UUIDConverter.convert(entity.conversationID))
        let propertyOffset_fullTextContent = propertyCollector.prepare(string: entity.fullTextContent)

        propertyCollector.collect(id, at: 2 + 2 * 1)
        propertyCollector.collect(entity.timestamp, at: 2 + 2 * 5)
        propertyCollector.collect(dataOffset: propertyOffset_sourceMessageID, at: 2 + 2 * 2)
        propertyCollector.collect(dataOffset: propertyOffset_conversationID, at: 2 + 2 * 3)
        propertyCollector.collect(dataOffset: propertyOffset_fullTextContent, at: 2 + 2 * 4)
    }

    internal func createEntity(entityReader: ObjectBox.FlatBufferReader, store: ObjectBox.Store) -> EntityType {
        let entity = ParentDocumentEntity()

        entity.id = entityReader.read(at: 2 + 2 * 1)
        entity.sourceMessageID = UUIDConverter.convert(entityReader.read(at: 2 + 2 * 2))
        entity.conversationID = UUIDConverter.convert(entityReader.read(at: 2 + 2 * 3))
        entity.fullTextContent = entityReader.read(at: 2 + 2 * 4)
        entity.timestamp = entityReader.read(at: 2 + 2 * 5)

        return entity
    }
}


extension ChildChunkEntity: ObjectBox.__EntityRelatable {
    internal typealias EntityType = ChildChunkEntity

    internal var _id: EntityId<ChildChunkEntity> {
        return EntityId<ChildChunkEntity>(self.id.value)
    }
}

extension ChildChunkEntity: ObjectBox.EntityInspectable {
    internal typealias EntityBindingType = ChildChunkEntityBinding

    /// Generated metadata used by ObjectBox to persist the entity.
    internal static let entityInfo = ObjectBox.EntityInfo(name: "ChildChunkEntity", id: 3)

    internal static let entityBinding = EntityBindingType()

    fileprivate static func buildEntity(modelBuilder: ObjectBox.ModelBuilder) throws {
        let entityBuilder = try modelBuilder.entityBuilder(for: ChildChunkEntity.self, id: 3, uid: 1682473059827456000)
        try entityBuilder.addProperty(name: "id", type: PropertyType.long, flags: [.id], id: 1, uid: 8274615930285143040)
        try entityBuilder.addProperty(name: "chunkText", type: PropertyType.string, id: 2, uid: 9163027485921738752)
        try entityBuilder.addProperty(name: "embedding", type: PropertyType.byteVector, id: 3, uid: 1047382956103847936)
        try entityBuilder.addProperty(name: "chunkIndex", type: PropertyType.long, id: 4, uid: 2538194607326951424)
        try entityBuilder.addToOneRelation(name: "parentDocument", targetEntityInfo: ParentDocumentEntity.entityInfo, id: 5, uid: 3692851740519263232, indexId: 1, indexUid: 4817293650284719104)

        try entityBuilder.lastProperty(id: 5, uid: 3692851740519263232)
    }
}

extension ChildChunkEntity {
    /// Generated entity property information.
    ///
    /// You may want to use this in queries to specify fetch conditions, for example:
    ///
    ///     box.query { ChildChunkEntity.id == myId }

    internal static var id: Property<ChildChunkEntity, Id, Id> { return Property<ChildChunkEntity, Id, Id>(propertyId: 1, isPrimaryKey: true) }

    /// Generated entity property information.
    ///
    /// You may want to use this in queries to specify fetch conditions, for example:
    ///
    ///     box.query { ChildChunkEntity.chunkText.startsWith("X") }

    internal static var chunkText: Property<ChildChunkEntity, String, Void> { return Property<ChildChunkEntity, String, Void>(propertyId: 2, isPrimaryKey: false) }

    /// Generated entity property information.
    ///
    /// You may want to use this in queries to specify fetch conditions, for example:
    ///
    ///     box.query { ChildChunkEntity.embedding > 1234 }

    internal static var embedding: Property<ChildChunkEntity, Data, Void> { return Property<ChildChunkEntity, Data, Void>(propertyId: 3, isPrimaryKey: false) }

    /// Generated entity property information.
    ///
    /// You may want to use this in queries to specify fetch conditions, for example:
    ///
    ///     box.query { ChildChunkEntity.chunkIndex > 1234 }

    internal static var chunkIndex: Property<ChildChunkEntity, Int, Void> { return Property<ChildChunkEntity, Int, Void>(propertyId: 4, isPrimaryKey: false) }

    internal static var parentDocument: Property<ChildChunkEntity, EntityId<ParentDocumentEntity>, ParentDocumentEntity> { return Property(propertyId: 5) }

    fileprivate func __setId(identifier: ObjectBox.Id) {
        self.id = Id(identifier)
    }
}

extension ObjectBox.Property where E == ChildChunkEntity {
    /// Generated entity property information.
    ///
    /// You may want to use this in queries to specify fetch conditions, for example:
    ///
    ///     box.query { .id == myId }

    internal static var id: Property<ChildChunkEntity, Id, Id> { return Property<ChildChunkEntity, Id, Id>(propertyId: 1, isPrimaryKey: true) }

    /// Generated entity property information.
    ///
    /// You may want to use this in queries to specify fetch conditions, for example:
    ///
    ///     box.query { .chunkText.startsWith("X") }

    internal static var chunkText: Property<ChildChunkEntity, String, Void> { return Property<ChildChunkEntity, String, Void>(propertyId: 2, isPrimaryKey: false) }

    /// Generated entity property information.
    ///
    /// You may want to use this in queries to specify fetch conditions, for example:
    ///
    ///     box.query { .embedding > 1234 }

    internal static var embedding: Property<ChildChunkEntity, Data, Void> { return Property<ChildChunkEntity, Data, Void>(propertyId: 3, isPrimaryKey: false) }

    /// Generated entity property information.
    ///
    /// You may want to use this in queries to specify fetch conditions, for example:
    ///
    ///     box.query { .chunkIndex > 1234 }

    internal static var chunkIndex: Property<ChildChunkEntity, Int, Void> { return Property<ChildChunkEntity, Int, Void>(propertyId: 4, isPrimaryKey: false) }

    internal static var parentDocument: Property<ChildChunkEntity, Id, ParentDocumentEntity> { return Property<ChildChunkEntity, Id, ParentDocumentEntity>(propertyId: 5) }

}


/// Generated service type to handle persisting and reading entity data. Exposed through `ChildChunkEntity.EntityBindingType`.
internal final class ChildChunkEntityBinding: ObjectBox.EntityBinding, Sendable {
    internal typealias EntityType = ChildChunkEntity
    internal typealias IdType = Id

    internal required init() {}

    internal func generatorBindingVersion() -> Int { 1 }

    internal func setEntityIdUnlessStruct(of entity: EntityType, to entityId: ObjectBox.Id) {
        entity.__setId(identifier: entityId)
    }

    internal func entityId(of entity: EntityType) -> ObjectBox.Id {
        return entity.id.value
    }

    internal func collect(fromEntity entity: EntityType, id: ObjectBox.Id,
                                  propertyCollector: ObjectBox.FlatBufferBuilder, store: ObjectBox.Store) throws {
        let propertyOffset_chunkText = propertyCollector.prepare(string: entity.chunkText)
        let propertyOffset_embedding = propertyCollector.prepare(bytes: FloatArrayConverter.convert(entity.embedding))

        propertyCollector.collect(id, at: 2 + 2 * 1)
        propertyCollector.collect(entity.chunkIndex, at: 2 + 2 * 4)
        try propertyCollector.collect(entity.parentDocument, at: 2 + 2 * 5, store: store)
        propertyCollector.collect(dataOffset: propertyOffset_chunkText, at: 2 + 2 * 2)
        propertyCollector.collect(dataOffset: propertyOffset_embedding, at: 2 + 2 * 3)
    }

    internal func postPut(fromEntity entity: EntityType, id: ObjectBox.Id, store: ObjectBox.Store) throws {
        if entityId(of: entity) == 0 {
            entity.parentDocument.attach(to: store.box(for: ParentDocumentEntity.self))
        }
    }

    internal func setToOneRelation(_ propertyId: obx_schema_id, of entity: EntityType, to entityId: ObjectBox.Id?) {
        switch propertyId {
            case 5:
                entity.parentDocument.targetId = (entityId != nil) ? EntityId<ParentDocumentEntity>(entityId!) : nil
            default:
                fatalError("Attempt to change nonexistent ToOne relation with ID \(propertyId)")
        }
    }

    internal func createEntity(entityReader: ObjectBox.FlatBufferReader, store: ObjectBox.Store) -> EntityType {
        let entity = ChildChunkEntity()

        entity.id = entityReader.read(at: 2 + 2 * 1)
        entity.chunkText = entityReader.read(at: 2 + 2 * 2)
        entity.embedding = FloatArrayConverter.convert(entityReader.read(at: 2 + 2 * 3))
        entity.chunkIndex = entityReader.read(at: 2 + 2 * 4)

        entity.parentDocument = entityReader.read(at: 2 + 2 * 5, store: store)

        return entity
    }
}


/// Helper function that allows calling Enum(rawValue: value) with a nil value, which will return nil.
fileprivate func optConstruct<T: RawRepresentable>(_ type: T.Type, rawValue: T.RawValue?) -> T? {
    guard let rawValue = rawValue else { return nil }
    return T(rawValue: rawValue)
}

// MARK: - Store setup

fileprivate func cModel() throws -> OpaquePointer {
    let modelBuilder = try ObjectBox.ModelBuilder()
    try ParentDocumentEntity.buildEntity(modelBuilder: modelBuilder)
    try ChildChunkEntity.buildEntity(modelBuilder: modelBuilder)
    modelBuilder.lastEntity(id: 3, uid: 1682473059827456000)
    modelBuilder.lastIndex(id: 1, uid: 4817293650284719104)
    return modelBuilder.finish()
}

extension ObjectBox.Store {
    /// A store with a fully configured model. Created by the code generator with your model's metadata in place.
    ///
    /// # In-memory database
    /// To use a file-less in-memory database, instead of a directory path pass `memory:`
    /// together with an identifier string:
    /// ```swift
    /// let inMemoryStore = try Store(directoryPath: "memory:test-db")
    /// ```
    ///
    /// - Parameters:
    ///   - directoryPath: The directory path in which ObjectBox places its database files for this store,
    ///     or to use an in-memory database `memory:<identifier>`.
    ///   - maxDbSizeInKByte: Limit of on-disk space for the database files. Default is `1024 * 1024` (1 GiB).
    ///   - fileMode: UNIX-style bit mask used for the database files; default is `0o644`.
    ///     Note: directories become searchable if the "read" or "write" permission is set (e.g. 0640 becomes 0750).
    ///   - maxReaders: The maximum number of readers.
    ///     "Readers" are a finite resource for which we need to define a maximum number upfront.
    ///     The default value is enough for most apps and usually you can ignore it completely.
    ///     However, if you get the maxReadersExceeded error, you should verify your
    ///     threading. For each thread, ObjectBox uses multiple readers. Their number (per thread) depends
    ///     on number of types, relations, and usage patterns. Thus, if you are working with many threads
    ///     (e.g. in a server-like scenario), it can make sense to increase the maximum number of readers.
    ///     Note: The internal default is currently around 120. So when hitting this limit, try values around 200-500.
    ///   - readOnly: Opens the database in read-only mode, i.e. not allowing write transactions.
    ///
    /// - important: This initializer is created by the code generator. If you only see the internal `init(model:...)`
    ///              initializer, trigger code generation by building your project.
    internal convenience init(directoryPath: String, maxDbSizeInKByte: UInt64 = 1024 * 1024,
                            fileMode: UInt32 = 0o644, maxReaders: UInt32 = 0, readOnly: Bool = false) throws {
        try self.init(
            model: try cModel(),
            directory: directoryPath,
            maxDbSizeInKByte: maxDbSizeInKByte,
            fileMode: fileMode,
            maxReaders: maxReaders,
            readOnly: readOnly)
    }
}

// swiftlint:enable all
