import Foundation

private enum Failure: Error { case timeout, connectionLost, serverError }

@main struct ChatSingleProviderRequestChecks {
    static func main() async {
        for failure in [Failure.timeout, .connectionLost, .serverError] {
            var dispatchCount = 0
            await ChatSingleProviderRequest.run(request: "request", loadingID: UUID(), context: ()) {
                _, _, _, shouldRetry in
                dispatchCount += 1
                if await shouldRetry(failure) { dispatchCount += 1 }
            }
            precondition(dispatchCount == 1)
        }
        print("single provider request checks passed")
    }
}
