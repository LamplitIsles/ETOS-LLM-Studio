import ETOSCore
import Testing
@testable import ETOS_LLM_Studio_App

@Suite("CFL chat header status")
struct CFLHeaderStatusTests {
    @Test("Connection and active turn determine the displayed state")
    func status() {
        #expect(CFLHeaderStatus(hasOrigin: true, connection: .online, hasActiveTurn: false) == .online)
        #expect(CFLHeaderStatus(hasOrigin: true, connection: .online, hasActiveTurn: true) == .replying)
        #expect(CFLHeaderStatus(hasOrigin: true, connection: .connecting, hasActiveTurn: true) == .connecting)
        for connection in [CFLConnection.offline, .accessDenied, .protocolError] {
            #expect(CFLHeaderStatus(hasOrigin: true, connection: connection, hasActiveTurn: false) == .offline)
        }
        #expect(CFLHeaderStatus(hasOrigin: false, connection: .online, hasActiveTurn: true) == .offline)
    }
}
