@testable import AppBundle
import XCTest

final class MacAppTest: XCTestCase {
    func testRegistrationRetriesAreBoundedAndBackOff() {
        XCTAssertEqual(MacApp.registrationRetryDelays, [
            .milliseconds(10),
            .milliseconds(25),
            .milliseconds(50),
            .milliseconds(100),
        ])
    }
}
