import Foundation
import Testing
@testable import SwiftTerminal

@Test("The model library is a private SQLite database that retains API keys locally")
func modelProfileStorePersistsProfilesInSQLite() throws {
    let sandbox = makeSandbox("ModelLibrary")
    defer { try? FileManager.default.removeItem(at: sandbox) }
    let store = ModelProfileStore(directory: sandbox)
    let profile = ModelProfile(
        name: "DeepSeek",
        baseURL: "https://api.deepseek.com",
        model: "deepseek-flash",
        apiKey: "sk-test-only-not-a-real-secret"
    )

    try store.saveAll([profile], activeID: profile.id)

    let databaseURL = sandbox.appendingPathComponent("model-library.sqlite3")
    let database = try Data(contentsOf: databaseURL)
    #expect(database.starts(with: Data("SQLite format 3\0".utf8)))
    #expect(database.range(of: Data(profile.apiKey.utf8)) != nil)
    #expect(try store.loadAll() == [profile])
    #expect(store.active(from: [profile]).id == profile.id)
    #expect(filePermissions(at: sandbox) == 0o700)
    #expect(filePermissions(at: databaseURL) == 0o600)
}

@Test("Existing JSON model libraries migrate into SQLite and are removed")
func modelProfileStoreMigratesLegacyJSONLibrary() throws {
    let sandbox = makeSandbox("ModelMigration")
    defer { try? FileManager.default.removeItem(at: sandbox) }
    try FileManager.default.createDirectory(at: sandbox, withIntermediateDirectories: true)
    let id = UUID(uuidString: "F2A18AC2-62F4-48B3-9207-2F8CBEA0A201")!
    let profile = ModelProfile(
        id: id,
        name: "DeepSeek",
        baseURL: "https://api.deepseek.com",
        model: "deepseek-flash",
        apiKey: "sk-legacy-fixture-not-real"
    )
    let legacyProfiles = sandbox.appendingPathComponent("model-profiles.json")
    try JSONEncoder().encode([profile]).write(to: legacyProfiles)
    try Data(id.uuidString.utf8).write(to: sandbox.appendingPathComponent("active-model-id"))
    let store = ModelProfileStore(directory: sandbox)

    let loaded = try store.loadAll()

    #expect(loaded == [profile])
    #expect(store.active(from: loaded).id == id)
    #expect(!FileManager.default.fileExists(atPath: legacyProfiles.path))
    #expect(FileManager.default.fileExists(atPath: sandbox.appendingPathComponent("model-library.sqlite3").path))
}

@Test("The previous single-profile JSON format migrates to SQLite")
func modelProfileStoreMigratesLegacySingleProfile() throws {
    let sandbox = makeSandbox("SingleProfileMigration")
    defer { try? FileManager.default.removeItem(at: sandbox) }
    try FileManager.default.createDirectory(at: sandbox, withIntermediateDirectories: true)
    let id = UUID()
    let legacy = #"{"id":"\#(id.uuidString)","name":"Legacy","baseURL":"https://example.com/v1","model":"model","apiKey":"sk-legacy-fixture-not-real"}"#
    let oldFile = sandbox.appendingPathComponent("model-profile.json")
    try Data(legacy.utf8).write(to: oldFile)
    let store = ModelProfileStore(directory: sandbox)

    let profiles = try store.loadAll()

    #expect(profiles.count == 1)
    #expect(profiles[0].id == id)
    #expect(profiles[0].apiKey == "sk-legacy-fixture-not-real")
    #expect(!FileManager.default.fileExists(atPath: oldFile.path))
}

@Test("Removing a profile removes its API key from the local database")
func modelProfileStoreReplacesDeletedProfiles() throws {
    let sandbox = makeSandbox("ProfileDelete")
    defer { try? FileManager.default.removeItem(at: sandbox) }
    let store = ModelProfileStore(directory: sandbox)
    let retained = ModelProfile(name: "One", model: "one", apiKey: "first-test-secret")
    let removed = ModelProfile(name: "Two", model: "two", apiKey: "second-test-secret")

    try store.saveAll([retained, removed], activeID: retained.id)
    try store.saveAll([retained], activeID: retained.id)

    #expect(try store.loadAll() == [retained])
    let database = try Data(contentsOf: sandbox.appendingPathComponent("model-library.sqlite3"))
    #expect(database.range(of: Data(removed.apiKey.utf8)) == nil)
}

@Test("Command parameters are shell-escaped as individual arguments")
func commandTemplateResolverQuotesSpacesAndSingleQuotes() throws {
    let parameter = CommandParameter(name: "主机", prompt: "主机名", defaultValue: "")
    let result = CommandTemplateResolver.resolve(
        template: "ssh {{主机}}",
        parameters: [parameter],
        values: [parameter.id: "ops's laptop"]
    )

    let command = try #require(try? result.get())
    #expect(command == "ssh 'ops'\\''s laptop'")
}

@Test("Command templates reject placeholders with no parameter definition")
func commandTemplateResolverRejectsUnknownPlaceholder() {
    let result = CommandTemplateResolver.resolve(template: "echo {{missing}}", parameters: [], values: [:])
    #expect(throws: CommandTemplateResolver.ResolutionError.self) { try result.get() }
}

private func makeSandbox(_ name: String) -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("SwiftTerminal\(name)Tests-\(UUID().uuidString)", isDirectory: true)
}

private func filePermissions(at url: URL) -> Int? {
    (try? FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber)?.intValue
}
