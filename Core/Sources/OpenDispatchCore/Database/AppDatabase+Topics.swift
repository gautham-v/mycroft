import Foundation
import GRDB

/// Async wrappers over the topic queries for UI code.
extension AppDatabase {

    /// Topics in sidebar order.
    public func topics() async throws -> [Source] {
        try await reader.read { db in try Queries.topics(db) }
    }

    /// The topics now and again after each change to the sources table (a refresh's last-fetched stamp included),
    /// whether made here or applied from iCloud.
    public func observeTopics() -> AsyncValueObservation<[Source]> {
        ValueObservation.tracking { db in try Queries.topics(db) }.values(in: reader)
    }

    /// Apply every topic's current rules to what it already stored and group its stories, without searching. The app runs this
    /// at launch, so a topic stored by an older build, or before its rules changed, is tidied without waiting for its next
    /// refresh. Returns how many items were removed.
    @discardableResult
    public func tidyTopics(languages: TopicLanguages = .current) async throws -> Int {
        try await writer.write { db in
            var removed = 0
            for topic in try Queries.topics(db) {
                removed += try Queries.removeStaleTopicItems(db, topic: topic, languages: languages)
                try Queries.groupTopicStories(db, topic: topic)
            }
            return removed
        }
    }

    /// The topic with this keyword (ignoring case and diacritics), or nil.
    public func topic(keyword: String) async throws -> Source? {
        try await reader.read { db in try Queries.topic(db, keyword: keyword) }
    }

    /// Follow a keyword; an existing topic with the same keyword is returned unchanged. Fill it with
    /// `RefreshService.refreshSource(id:)`.
    @discardableResult
    public func createTopic(_ options: TopicOptions) async throws -> Source {
        try await writer.write { db in try Queries.createTopic(db, options: options) }
    }

    /// Change a topic's keyword and options (the title follows the keyword).
    @discardableResult
    public func updateTopic(id: Int64, options: TopicOptions) async throws -> Source {
        try await writer.write { db in try Queries.updateTopic(db, id: id, options: options) }
    }

    /// New topic order, top to bottom.
    public func reorderTopics(_ ids: [Int64]) async throws {
        try await writer.write { db in try Queries.reorderTopics(db, ids) }
    }

    /// Stop following a topic and delete its items.
    @discardableResult
    public func deleteTopic(id: Int64) async throws -> Bool {
        try await writer.write { db in try Queries.deleteTopic(db, id: id) }
    }

    /// How many rows each filter of the topic's list has (a story is one row).
    public func topicFilterCounts(topicId: Int64) async throws -> [TopicContentFilter: Int] {
        try await reader.read { db in try Queries.topicFilterCounts(db, topicId: topicId) }
    }

    /// The filter counts now and again after each change to the items (a refresh, a story grouping, a removal).
    public func observeTopicFilterCounts(topicId: Int64) -> AsyncValueObservation<[TopicContentFilter: Int]> {
        ValueObservation.tracking { db in try Queries.topicFilterCounts(db, topicId: topicId) }.values(in: reader)
    }

    /// Unread items per source id (topics included), counting each source's own items (a topic's story counts once).
    public func unreadCounts() async throws -> [Int64: Int] {
        try await reader.read { db in try Queries.unreadCounts(db) }
    }

    /// The unread counts now and again after each change to items or read marks.
    public func observeUnreadCounts() -> AsyncValueObservation<[Int64: Int]> {
        ValueObservation.tracking { db in try Queries.unreadCounts(db) }.values(in: reader)
    }
}
