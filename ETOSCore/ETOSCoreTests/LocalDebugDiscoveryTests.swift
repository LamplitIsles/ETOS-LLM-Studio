import Foundation
import Network
import Testing
@testable import ETOSCore

@MainActor
@Suite("调试发现与捕获确认代次")
struct LocalDebugDiscoveryTests {
    @Test("停止扫描后迟到的状态、失败和结果不能恢复列表")
    func stoppedGenerationIsRejected() {
        let discovery = LocalDebugServerDiscovery(), candidate = fixture()
        let token = discovery.generation
        discovery.handleBrowserState(.ready, generation: token)
        discovery.handleBrowseResults([candidate], generation: token)
        #expect(discovery.isSearching && discovery.discoveredServers == [candidate])
        discovery.stop()
        discovery.handleBrowseResults([candidate], generation: token)
        discovery.handleBrowserState(.ready, generation: token)
        discovery.handleBrowserState(.failed(.posix(.ENETDOWN)), generation: token)
        #expect(!discovery.isSearching && discovery.discoveredServers.isEmpty && discovery.errorMessage == nil)
    }

    @Test("扫描失败后拒绝同代次已排队的结果，并保留失败说明")
    func failedGenerationIsInvalidated() {
        let discovery = LocalDebugServerDiscovery(), token = discovery.generation
        discovery.handleBrowserState(.failed(.posix(.ENETDOWN)), generation: token)
        let failure = discovery.errorMessage
        discovery.handleBrowserState(.ready, generation: token)
        discovery.handleBrowseResults([fixture()], generation: token)
        #expect(failure != nil && discovery.errorMessage == failure)
        #expect(!discovery.isSearching && discovery.discoveredServers.isEmpty)
    }

    @Test("旧扫描失败不能取消新代次的状态与结果")
    func olderFailureCannotCancelNewGeneration() {
        let discovery = LocalDebugServerDiscovery(), old = discovery.generation
        discovery.stop()
        let current = discovery.generation, candidate = fixture()
        discovery.handleBrowserState(.ready, generation: current)
        discovery.handleBrowseResults([candidate], generation: current)
        discovery.handleBrowserState(.failed(.posix(.ENETDOWN)), generation: old)
        discovery.handleBrowserState(.cancelled, generation: old)
        #expect(discovery.isSearching && discovery.errorMessage == nil && discovery.discoveredServers == [candidate])
        discovery.stop()
    }

    private func fixture() -> LocalDebugDiscoveredServer {
        LocalDebugDiscoveredServer(id: "fixture", name: "调试服务", host: "debug.test", port: 7654, lastSeenAt: Date(timeIntervalSince1970: 0))
    }
}
