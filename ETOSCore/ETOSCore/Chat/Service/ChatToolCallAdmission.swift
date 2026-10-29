import Foundation

enum ChatToolCallAdmission {
    static func permits<Call>(authorized: Bool, calls: [Call]?, matches: (Call) -> Bool) -> Bool {
        authorized && (calls?.contains(where: matches) ?? false)
    }
}
