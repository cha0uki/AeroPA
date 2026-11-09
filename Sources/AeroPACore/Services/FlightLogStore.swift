import Foundation
import CoreData

/// One timeline row on the Live Flight screen.
public struct TimelineEntry: Identifiable, Equatable, Codable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case phase, event, announcement, callout, sound, warning, connection
    }
    public var id = UUID()
    public var date: Date
    public var kind: Kind
    public var title: String
    public var detail: String?

    public init(date: Date = Date(), kind: Kind, title: String, detail: String? = nil) {
        self.date = date
        self.kind = kind
        self.title = title
        self.detail = detail
    }
}

public struct FlightRecordSummary: Identifiable, Equatable, Sendable {
    public var id: UUID
    public var startedAt: Date
    public var endedAt: Date?
    public var airline: String
    public var aircraft: String
    public var source: String
    public var entries: [TimelineEntry]
}

/// Core Data store for past flights. The model is built in code (no
/// .xcdatamodeld), so the store works the same in the app and in tests.
public final class FlightLogStore {
    private let container: NSPersistentContainer
    public private(set) var loadError: String?

    public static let model: NSManagedObjectModel = {
        let entity = NSEntityDescription()
        entity.name = "FlightRecord"
        entity.managedObjectClassName = NSStringFromClass(NSManagedObject.self)
        func attr(_ name: String, _ type: NSAttributeType, optional: Bool = false) -> NSAttributeDescription {
            let a = NSAttributeDescription()
            a.name = name
            a.attributeType = type
            a.isOptional = optional
            return a
        }
        entity.properties = [
            attr("id", .UUIDAttributeType),
            attr("startedAt", .dateAttributeType),
            attr("endedAt", .dateAttributeType, optional: true),
            attr("airline", .stringAttributeType),
            attr("aircraft", .stringAttributeType),
            attr("source", .stringAttributeType),
            attr("entriesJSON", .binaryDataAttributeType)
        ]
        let model = NSManagedObjectModel()
        model.entities = [entity]
        return model
    }()

    /// - Parameter inMemory: true for tests.
    public init(inMemory: Bool = false) {
        container = NSPersistentContainer(name: "AeroPAFlights", managedObjectModel: Self.model)
        if inMemory {
            let d = NSPersistentStoreDescription()
            d.type = NSInMemoryStoreType
            container.persistentStoreDescriptions = [d]
        }
        container.loadPersistentStores { [weak self] _, error in
            if let error { self?.loadError = error.localizedDescription }
        }
    }

    public func save(_ record: FlightRecordSummary) {
        let ctx = container.viewContext
        let req = NSFetchRequest<NSManagedObject>(entityName: "FlightRecord")
        req.predicate = NSPredicate(format: "id == %@", record.id as CVarArg)
        let obj = (try? ctx.fetch(req).first) ?? NSManagedObject(entity: Self.model.entitiesByName["FlightRecord"] ?? NSEntityDescription(), insertInto: ctx)
        obj.setValue(record.id, forKey: "id")
        obj.setValue(record.startedAt, forKey: "startedAt")
        obj.setValue(record.endedAt, forKey: "endedAt")
        obj.setValue(record.airline, forKey: "airline")
        obj.setValue(record.aircraft, forKey: "aircraft")
        obj.setValue(record.source, forKey: "source")
        obj.setValue((try? JSONEncoder().encode(record.entries)) ?? Data(), forKey: "entriesJSON")
        do { try ctx.save() } catch { loadError = error.localizedDescription }
    }

    public func recent(limit: Int = 20) -> [FlightRecordSummary] {
        let req = NSFetchRequest<NSManagedObject>(entityName: "FlightRecord")
        req.sortDescriptors = [NSSortDescriptor(key: "startedAt", ascending: false)]
        req.fetchLimit = limit
        let objs = (try? container.viewContext.fetch(req)) ?? []
        return objs.compactMap { o in
            guard let id = o.value(forKey: "id") as? UUID, let started = o.value(forKey: "startedAt") as? Date else { return nil }
            let data = o.value(forKey: "entriesJSON") as? Data ?? Data()
            return FlightRecordSummary(id: id, startedAt: started, endedAt: o.value(forKey: "endedAt") as? Date,
                                       airline: o.value(forKey: "airline") as? String ?? "",
                                       aircraft: o.value(forKey: "aircraft") as? String ?? "",
                                       source: o.value(forKey: "source") as? String ?? "",
                                       entries: (try? JSONDecoder().decode([TimelineEntry].self, from: data)) ?? [])
        }
    }

    public func deleteAll() {
        let ctx = container.viewContext
        let req = NSFetchRequest<NSManagedObject>(entityName: "FlightRecord")
        for o in (try? ctx.fetch(req)) ?? [] { ctx.delete(o) }
        try? ctx.save()
    }
}
