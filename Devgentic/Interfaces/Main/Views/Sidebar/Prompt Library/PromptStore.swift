//
//  PromptStore.swift
//  Devgentic
//
//  Created by Raj Singh on 27/08/25.
//

import Foundation
import CoreData
import os

protocol PromptStoreProtocol {
    func fetchPrompts() -> [DevPrompt]
    func addPrompt(from model: DevPrompt)
    func updatePrompt(from model: DevPrompt)
    func deletePrompt(withId id: UUID)
}

class PromptStore: PromptStoreProtocol {
    
    private let coreDataService: CoreDataPersistenceService
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.devgentic.app", category: "PromptStore")

    init(coreDataService: CoreDataPersistenceService = .shared) {
        self.coreDataService = coreDataService
    }

    private var viewContext: NSManagedObjectContext {
        coreDataService.viewContext
    }

    func fetchPrompts() -> [DevPrompt] {
        let request: NSFetchRequest<PromptEntity> = PromptEntity.fetchRequest()
        request.sortDescriptors = [NSSortDescriptor(key: "createdAt", ascending: false)]
        
        do {
            let entities = try viewContext.fetch(request)
            let prompts = entities.map { $0.toPromptStruct() }
            logger.info("Successfully fetched \(prompts.count) prompts from Core Data.")
            return prompts
        } catch {
            logger.error("Failed to fetch prompts from Core Data: \(error.localizedDescription)")
            return []
        }
    }
    
    func addPrompt(from model: DevPrompt) {
        let newPromptEntity = PromptEntity(context: viewContext)
        configure(entity: newPromptEntity, with: model)
        logger.info("Adding new prompt '\(model.title)' to Core Data.")
        coreDataService.saveContext()
    }
    
    func updatePrompt(from model: DevPrompt) {
        guard let promptToUpdate = getPromptEntity(withId: model.id) else {
            logger.warning("Attempted to update a prompt that does not exist in Core Data (ID: \(model.id.uuidString)). Adding it instead.")
            addPrompt(from: model)
            return
        }
        configure(entity: promptToUpdate, with: model)
        logger.info("Updating prompt '\(model.title)' in Core Data.")
        coreDataService.saveContext()
    }
    
    func deletePrompt(withId id: UUID) {
        guard let promptToDelete = getPromptEntity(withId: id) else {
            logger.warning("Attempted to delete a prompt that does not exist in Core Data (ID: \(id.uuidString)).")
            return
        }
        viewContext.delete(promptToDelete)
        logger.info("Deleting prompt with ID \(id.uuidString) from Core Data.")
        coreDataService.saveContext()
    }
    
    private func getPromptEntity(withId id: UUID) -> PromptEntity? {
        let request: NSFetchRequest<PromptEntity> = PromptEntity.fetchRequest()
        request.predicate = NSPredicate(format: "id == %@", id as CVarArg)
        request.fetchLimit = 1
        
        do {
            return try viewContext.fetch(request).first
        } catch {
            logger.error("Failed to fetch PromptEntity with ID \(id.uuidString): \(error.localizedDescription)")
            return nil
        }
    }
    
    private func configure(entity: PromptEntity, with model: DevPrompt) {
        entity.id = model.id
        entity.title = model.title
        entity.text = model.text
        entity.category = model.category
        entity.createdAt = model.createdAt
        entity.lastUsedAt = model.lastUsedAt
        entity.isUserDefined = model.isUserDefined
        entity.tags = model.tags as NSArray?
    }
}
