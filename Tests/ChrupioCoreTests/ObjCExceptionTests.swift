import XCTest
import ChrupioObjC

final class ObjCExceptionTests: XCTestCase {
    func testExceptionBecomesAnError() {
        XCTAssertThrowsError(try OKObjC.catchException {
            NSException(name: .internalInconsistencyException, reason: "Failed to create tap, config change pending!").raise()
        }) { error in
            XCTAssertEqual(error.localizedDescription, "Failed to create tap, config change pending!")
        }
        var ran = false
        XCTAssertNoThrow(try OKObjC.catchException { ran = true })
        XCTAssertTrue(ran)
    }
}
