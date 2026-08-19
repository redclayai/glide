import AutocompleteCore
import XCTest

final class ScreenTextProvidingTests: XCTestCase {
    func testNullProviderAlwaysReturnsNil() {
        let provider: ScreenTextProviding = NullScreenTextProvider()
        XCTAssertNil(provider.latestScreenText)
    }

    func testStaticProviderDefaultsToNil() {
        let provider: ScreenTextProviding = StaticScreenTextProvider()
        XCTAssertNil(provider.latestScreenText)
    }

    func testStaticProviderReturnsConfiguredText() {
        let provider: ScreenTextProviding = StaticScreenTextProvider(latestScreenText: "subject line: schedule")
        XCTAssertEqual(provider.latestScreenText, "subject line: schedule")
    }
}
