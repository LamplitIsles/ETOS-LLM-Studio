import Combine
import ETOSCore
import Testing
@testable import ETOS_LLM_Studio_App

@MainActor
@Suite("CFL authorization presentation")
struct CFLAuthorizationPresentationTests {
    @Test("Confirmed loss of authorization offers sign-in; network loss does not")
    func authorizationFailure() {
        let changes = PassthroughSubject<String, Never>()
        let model = CFLConversationModel(draftChanges: changes.eraseToAnyPublisher())
        #expect(!model.recordAuthorizationFailure(CFLFailure.offline))
        #expect(!model.needsSignIn)
        #expect(model.recordAuthorizationFailure(CFLFailure.accessDenied))
        #expect(model.needsSignIn)
        #expect(model.notice?.isEmpty == false)
    }
}
