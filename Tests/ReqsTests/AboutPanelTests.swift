import AppKit
import XCTest

@testable import Reqs

final class AboutPanelTests: XCTestCase {
    func testCreditsLinkLicenseAndOwner() {
        let credits = AboutPanel.credits()
        let text = credits.string as NSString
        let license = credits.attribute(.link, at: text.range(of: "MIT License").location, effectiveRange: nil) as? URL
        let owner = credits.attribute(.link, at: text.range(of: "bearstouch").location, effectiveRange: nil) as? URL
        XCTAssertEqual(license, AboutPanel.licenseURL)
        XCTAssertEqual(owner, AboutPanel.ownerURL)
    }
}
