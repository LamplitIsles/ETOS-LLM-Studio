import Foundation
import Testing
@testable import ETOSCore

struct SyncPackageDownloadProgressTests {
    @Test("下载进度会限制在总大小范围内")
    func testDownloadProgressClampsValues() {
        let progress = SyncPackageDownloadProgress(bytesReceived: 2048, totalBytes: 1024)

        #expect(progress.bytesReceived == 1024)
        #expect(progress.totalBytes == 1024)
        #expect(progress.fractionCompleted == 1)
    }

}
