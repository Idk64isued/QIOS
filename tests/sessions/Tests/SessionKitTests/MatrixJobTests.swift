import Foundation
import Testing

@testable import SessionKit

/// `sessions matrix`'s job lines: a base, or create's flags, then an optional check after --.
struct MatrixJobTests {
    @Test func readsBasesPreparationsAndChecks() throws {
        let jobs = try MatrixJob.parse(
            """
            # comment
            a  /bases/x
            b  --id n81ap-9B176 --ipsw /i.ipsw --jailbreak   # trailing comment
            c  /bases/y -- rotation --overlay /o

            """
        )
        #expect(
            jobs == [
                MatrixJob(name: "a", base: "/bases/x", create: [], check: []),
                MatrixJob(
                    name: "b",
                    base: nil,
                    create: ["--id", "n81ap-9B176", "--ipsw", "/i.ipsw", "--jailbreak"],
                    check: []
                ),
                MatrixJob(name: "c", base: "/bases/y", create: [], check: ["rotation", "--overlay", "/o"])
            ]
        )
    }

    @Test func refusesAJobItCannotRun() {
        #expect(throws: MatrixJob.Invalid.self) { try MatrixJob.parse("a --jailbreak") }
        #expect(throws: MatrixJob.Invalid.self) { try MatrixJob.parse("a") }
        #expect(throws: MatrixJob.Invalid.self) { try MatrixJob.parse("a /x /y") }
    }
}
