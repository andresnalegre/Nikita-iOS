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

    // read_screen is gone (the device is read by files, CLI and app RPC),
    // and writing has had its own family since reading, changing and
    // deleting were split -- this test was still asserting the old shape.
    func testFamilyMapping() {
        XCTAssertEqual(NikitaTools.family(of: "run_app"), "apps")
        XCTAssertEqual(NikitaTools.family(of: "read_file"), "files")
        XCTAssertEqual(NikitaTools.family(of: "save_file"), "files_write")
        XCTAssertEqual(NikitaTools.family(of: "delete_file"), "files_delete")
        XCTAssertEqual(NikitaTools.family(of: "forget"), "memory")
        // Never gated: the loop itself depends on the plan.
        XCTAssertEqual(NikitaTools.family(of: "update_plan"), "plan")
    }

    // The plan is what keeps a job alive between turns, so the two things
    // the loop asks it are worth pinning: how much is left, and what next.
    func testPlanTracksOpenWork() {
        let plan = NikitaPlan(filename: "nikita-test-\(UUID().uuidString).json")
        plan.apply(items: [
            ["text": "Read the config", "status": "done"],
            ["text": "Patch the handler", "status": "in_progress"],
            ["text": "Run the tests", "status": "pending"]
        ], note: "halfway")

        XCTAssertEqual(plan.openCount, 2)
        XCTAssertEqual(plan.current, "Patch the handler")
        XCTAssertEqual(plan.note, "halfway")
        XCTAssertTrue(plan.promptBlock().contains("[>] Patch the handler"))

        // Only one item may be in progress, or there is no single next step.
        plan.apply(items: [
            ["text": "A", "status": "in_progress"],
            ["text": "B", "status": "in_progress"]
        ], note: nil)
        XCTAssertEqual(plan.current, "A")
        XCTAssertEqual(
            plan.items.filter { $0.status == .inProgress }.count, 1)

        plan.apply(items: [], note: nil)
        XCTAssertEqual(plan.openCount, 0)
        XCTAssertTrue(plan.isEmpty)
    }

    // The plan's SD-card format is what lets qFlipper and iOS share one plan.
    // A round-trip must survive, and the newer-wins rule must hold both ways.
    func testPlanCardFormatRoundTrip() {
        let a = NikitaPlan(filename: "nikita-test-\(UUID().uuidString).json")
        a.apply(items: [
            ["text": "Read config", "status": "done"],
            ["text": "Patch it", "status": "in_progress"]
        ], note: "midway")
        let json = a.exportJSON()
        XCTAssertTrue(json.contains("\"touched\""))
        XCTAssertTrue(json.contains("in_progress"))

        // A fresh, empty plan adopts the exported one (it is newer).
        let b = NikitaPlan(filename: "nikita-test-\(UUID().uuidString).json")
        XCTAssertTrue(b.adoptFromJSON(json))
        XCTAssertEqual(b.openCount, 1)
        XCTAssertEqual(b.current, "Patch it")
        XCTAssertEqual(b.note, "midway")

        // Re-adopting the same (not newer) plan is a no-op.
        XCTAssertFalse(b.adoptFromJSON(json))
    }

    // An MCP tool has to be recognisable from its name alone: that is what
    // routes it past the built-in switch and the family filter.
    func testMcpToolNames() {
        XCTAssertTrue(NikitaMcp.isMcpTool("mcp__github__create_issue"))
        XCTAssertFalse(NikitaMcp.isMcpTool("save_file"))
        XCTAssertFalse(NikitaMcp.isMcpTool("update_plan"))
    }

    // A plan restored from disk is the whole point of storing it.
    func testPlanSurvivesReload() {
        let name = "nikita-test-\(UUID().uuidString).json"
        let first = NikitaPlan(filename: name)
        first.apply(items: [["text": "Finish the port", "status": "pending"]],
                    note: "picked up tomorrow")

        let second = NikitaPlan(filename: name)
        XCTAssertEqual(second.openCount, 1)
        XCTAssertEqual(second.current, "Finish the port")
        XCTAssertEqual(second.note, "picked up tomorrow")
    }
}
