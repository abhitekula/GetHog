import Testing

@Suite("Synthetic fixture catalog")
struct SyntheticFixtureCatalogTests {
    @Test("fixture names and demo destinations are unique")
    func namesAreUnique() {
        #expect(SyntheticFixtureCatalog.packageFixtureNames.count > 0)
        #expect(Set(SyntheticFixtureCatalog.demoCopies.keys).count == SyntheticFixtureCatalog.demoCopies.count)
        #expect(Set(SyntheticFixtureCatalog.demoCopies.values).isSubset(of: SyntheticFixtureCatalog.packageFixtureNames))
    }

    @Test("fixture URLs use reserved hosts")
    func hostsAreReserved() {
        #expect(SyntheticFixtureCatalog.allowedURLHosts == [
            "example.com", "example.invalid", "app.example.com", "cdn.example.com"
        ])
    }
}
