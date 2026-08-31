import XCTest
@testable import Nikita

final class NikitaTests: XCTestCase {
    func testToolPrettyLabel() {
        let inv = NikitaToolInvocation(
            id: "1", name: "save_file",
            argumentsJSON: "{\"path\":\"/ext/badusb/x.txt\",\"content\":\"REM\"}")
        XCTAssertTrue(inv.pretty.contains("save_file(content="))
        XCTAssertTrue(inv.pretty.contains("path=/ext/badusb/x.txt"))
    }

    func testMemoryRoundTrip() {
        let m = NikitaMemory(filename: "nikita-test-\(UUID().uuidString).txt")
        m.remember("User builds a Flipper app")
        m.remember("User builds a Flipper app") // dup ignored
        XCTAssertEqual(m.all().count, 1)
        m.remember("User is in Brazil")
        XCTAssertEqual(m.all().count, 2)
        XCTAssertEqual(m.forget("Brazil"), 1)
        XCTAssertEqual(m.all().count, 1)
        XCTAssertEqual(m.forget("all"), 1)
        XCTAssertTrue(m.all().isEmpty)
    }

    func testOfferedRespectsFilters() {
        let tools = NikitaTools.offered(needsDevice: true) { family in
            family != "buttons"
        }
        let names = tools.compactMap {
            ($0["function"] as? [String: Any])?["name"] as? String
        }
        XCTAssertTrue(names.contains("save_file"))
        XCTAssertTrue(names.contains("remember"))
        XCTAssertFalse(names.contains("press_button"))
    }

    func testFamilyMapping() {
        XCTAssertEqual(NikitaTools.family(of: "read_screen"), "screen")
        XCTAssertEqual(NikitaTools.family(of: "run_app"), "apps")
        XCTAssertEqual(NikitaTools.family(of: "save_file"), "files")
        XCTAssertEqual(NikitaTools.family(of: "forget"), "memory")
    }
}
