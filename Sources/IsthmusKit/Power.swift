import Foundation
import IOKit.pwr_mgt

/// Keeps the display awake while a game runs. Controller input doesn't
/// reset macOS's idle timer, so without this the screen sleeps mid-game.
public final class PowerAssertion: @unchecked Sendable {
    private var id: IOPMAssertionID = 0
    private var held = false
    private let lock = NSLock()

    public init(reason: String) {
        held = IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
                                           IOPMAssertionLevel(kIOPMAssertionLevelOn), reason as CFString, &id) == kIOReturnSuccess
    }

    public func release() {
        lock.lock(); defer { lock.unlock() }
        if held { IOPMAssertionRelease(id); held = false }
    }

    deinit { release() }
}
