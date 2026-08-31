import XCTest

@testable import Core

// The device reports its firmware over BLE as one string:
//
//     "<commit> <version> <branch-number> <build-date>"
//
// Everything the update card decides -- which channel you are on, whether an
// update exists, whether the running build even matches the selected channel --
// is read out of the second field. These pin that reading down.
class InstalledFirmwareTests: XCTestCase {
    private func information(softwareRevision: String) -> Flipper.DeviceInformation {
        .init(
            manufacturerName: "Flipper Devices Inc.",
            serialNumber: "",
            firmwareRevision: "",
            softwareRevision: softwareRevision,
            protobufRevision: .init(major: 0, minor: 29))
    }

    private func version(_ softwareRevision: String) -> Update.Version? {
        information(softwareRevision: softwareRevision).firmwareVersion
    }

    // MARK: Nikita

    func testNikitaReleaseIsARelease() {
        let version = version("14188f18 nkt-001 0 31-08-2026")
        XCTAssertEqual(version?.channel, .release)
        XCTAssertEqual(version?.name, "nkt-001")
    }

    func testNikitaReleaseCandidate() {
        let version = version("14188f18 nkt-042-rc 0 31-08-2026")
        XCTAssertEqual(version?.channel, .candidate)
        XCTAssertEqual(version?.name, "nkt-042-rc")
    }

    // Official dev builds all report the version "dev", so the app shows the
    // commit for them. A Nikita dev build is tagged, so it shows the tag --
    // showing the commit there would hide the only useful identifier.
    func testNikitaDevelopmentShowsTheTagNotTheCommit() {
        let version = version("14188f18 nkt-007-dev 0 31-08-2026")
        XCTAssertEqual(version?.channel, .development)
        XCTAssertEqual(version?.name, "nkt-007-dev")
    }

    // A locally built Nikita reports "v8": it came from no release channel, so
    // custom is the truth. This is the build the device on the bench runs.
    func testLocallyBuiltNikitaIsCustom() {
        let version = version("14188f18 v8 0 31-08-2026")
        XCTAssertEqual(version?.channel, .custom)
        XCTAssertEqual(version?.name, "v8")
    }

    // Shapes that merely start with the prefix are not Nikita releases, and
    // must not be promoted onto a real channel.
    func testNearMissesAreNotNikitaReleases() {
        XCTAssertEqual(version("abc nkt- 0 01-01-2026")?.channel, .custom)
        XCTAssertEqual(version("abc nkt-abc 0 01-01-2026")?.channel, .custom)
        XCTAssertEqual(version("abc nkt-001-foo 0 01-01-2026")?.channel, .custom)
        XCTAssertEqual(version("abc nikita 0 01-01-2026")?.channel, .custom)
    }

    // MARK: The official firmware must read exactly as it did before

    func testOfficialRelease() {
        let version = version("abcdef12 1.4.3 0 01-01-2026")
        XCTAssertEqual(version?.channel, .release)
        XCTAssertEqual(version?.name, "1.4.3")
    }

    func testOfficialReleaseCandidate() {
        XCTAssertEqual(version("abcdef12 1.4.3-rc 0 01-01-2026")?.channel, .candidate)
    }

    func testOfficialDevelopmentShowsTheCommit() {
        let version = version("abcdef12 dev 0 01-01-2026")
        XCTAssertEqual(version?.channel, .development)
        XCTAssertEqual(version?.name, "abcdef12")
    }

    func testOtherForksStayCustom() {
        XCTAssertEqual(version("abcdef12 unlshd-084 0 01-01-2026")?.channel, .custom)
        XCTAssertEqual(version("abcdef12 mntm-012 0 01-01-2026")?.channel, .custom)
    }

    func testTruncatedRevisionHasNoVersion() {
        XCTAssertNil(version("abcdef12"))
        XCTAssertNil(version(""))
    }
}
