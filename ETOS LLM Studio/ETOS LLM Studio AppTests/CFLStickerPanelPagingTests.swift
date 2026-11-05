import Testing
@testable import ETOS_LLM_Studio_App

@Suite("表情面板缓存分页")
struct CFLStickerPanelPagingTests {
    private struct Item: Identifiable, Equatable {
        let id: String
        let name: String
    }

    @Test("刷新第一页保留有效的后续页并更新变化的项目")
    func retainsTailWhenBoundaryIsUnchanged() {
        let old = [Item(id: "a", name: "A"), Item(id: "b", name: "旧名字"), Item(id: "c", name: "C")]
        let page = [Item(id: "b", name: "新名字"), Item(id: "d", name: "D")]
        let result = CFLStickerPanelPaging.refresh(existing: old, firstIDs: ["a", "b"],
            firstCursor: "page-two", cursor: nil, page: page, nextCursor: "page-two")
        #expect(result.items == [page[0], page[1], old[2]])
        #expect(result.cursor == nil)
    }

    @Test("分页边界变化时不拼接已经失效的旧页")
    func dropsTailWhenBoundaryChanges() {
        let old = [Item(id: "a", name: "A"), Item(id: "b", name: "B")]
        let page = [Item(id: "a", name: "新 A")]
        let result = CFLStickerPanelPaging.refresh(existing: old, firstIDs: ["a"],
            firstCursor: "old", cursor: nil, page: page, nextCursor: "new")
        #expect(result.items == page)
        #expect(result.cursor == "new")
    }

    @Test("新第一页包含旧后续页时不重复显示")
    func avoidsDuplicates() {
        let old = [Item(id: "a", name: "A"), Item(id: "b", name: "旧 B")]
        let page = [Item(id: "a", name: "A"), Item(id: "b", name: "新 B")]
        let result = CFLStickerPanelPaging.refresh(existing: old, firstIDs: ["a"],
            firstCursor: "next", cursor: nil, page: page, nextCursor: "next")
        #expect(result.items == page)
        #expect(result.cursor == "next")
    }
}
