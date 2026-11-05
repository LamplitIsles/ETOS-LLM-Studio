# 参考案例：从真机数值异常追到共享 host、CFL 与 Core

这是 2026-11-05 交接时的**历史证据和可复用接缝**，不是“以后都是相同根因”的规则。已确认源代码在受控条件下能制造正文倒退与消息换序；未完成相同实机原始帧到修复后设备体验的闭环。接手先核对当前实现是否仍有这些路径。

## 真机日志先缩小了什么

诊断构建 build_id 前缀 5fa4fb550e8d，源码为 ETOS 3b1749a3 加当时 dirty；用户确认密集回复触发大幅跳动，单条相对正常。授权日志只有数值，没有聊天正文、真实消息 ID 或入站帧。

在同一次试验的 174–185.3 秒：

- 34 次 state，原始消息数量始终 90；22 次有效投影/列表事务。
- 新行增加后撤回、随后恢复；183.364 秒行集合和可见值比较相同，但次序变化。
- viewport 375×647、offset=0、insets=0，无键盘、拖动、惯性或显式滚底事件；该窗口 reply=0。
- 一条旧行高度不变，y 为 335.5 → -13 → 142；邻行高度为 95 → 348.5 → 193.5，155 点回缩与旧行反向移动相符，最后两帧间无新投影。
- 事务返回早于实际几何变化，不能用 await 结束代替 UIKit 上屏完成。

因此先追“投影为什么撤回/换序”，而不是先调键盘或动画。两阶段行高、idle 抖动、离底滚动仍分别未归因。这是一份用户确认 trial，多行几何反向候选不是多个独立 trial。

当前源码中仪表使用前缀 [DEBUG-TIMELINE-5401]；事件包括 state、projection-enqueue/result/superseded、adapter-offer、transaction-start/commit/end、frame、composer-height/focus、keyboard、scroll-bottom-request/apply。临时行 token 只在单次运行内有意义。**现有日志没有原始消息来源或前缀变化字段**，不能直接证明实机走了下述帧顺序。

## A. 真实共享 host 为什么会晚发旧内容

### 来源与接缝

- App 仓库 packages/contracts/src/server.ts：createChatHost、drainTimeline；同包 client.ts：openChat。
- CFL 的 apps/partner/runtime/chat.ts 导入 @lamplit/contracts/server；共享代码在 CFL 进程内执行。
- 取证 App HEAD d1ed336aafe63d60de7ba277d0c09e49bf112ff0；CFL 当时 pin App 163d28f8ad01c6a7bc9f0e2ab688840583e5c940。两 revision 的 server.ts Git 内容 SHA256 均为 292aa3c43ae4d6cb356429f94d2cbe8a44770e99055b33b99987ee3f1221a51c；只证明该文件相同，不证明部署或完整产物一致。

### 可重复的门控

使用真实 createChatHost/openChat、内存 backend/socket；给 backend.read 加 gate：

1. 初始消息 a=short，streaming，activeTurnId=turn。
2. 先更新可读权威值 a=short-old，再通知对应 item；等通知后的首个 read 真正挂起。
3. 挂起期间改为 short-old-newer，通知新 item，然后释放 read。
4. 记录 host 实际发出的 snapshot 和后续帧。

同进程 3/3：

```text
view:short
view:short-old-newer
item:short-old
item:short-old-newer
```

真实 Core 逐帧重放相同合成输出，3/3 正文长 → 短 → 长。host 捕获 batch 后 await refresh，再发送原 batch；refresh 已得到新值，旧 batch 却仍可晚发。WebSocket 保持发送顺序，并没有网络乱序。

probe 的 old 通知前，fake current **必须已为 old**；仅通知一个权威状态尚不可读的 item 会引入生产不具备的前提。所有正文保持前缀增长、同 ID、streaming，避免靠 complete → streaming 的非必要切换制造红例。

## B. Core 双底稿的独立对照

真实 CFLChatClient 收到 timeline item 时修改 latestMessages/olderMessages，但当时不改 chord.value；之后每次 Chord view 更新又从该底稿重建 latest。

```text
初始 Chord view：a=short/streaming
timeline item：  a=short-long/streaming
只改 activeTurnId 的 view update
Core：          a=short/streaming
```

3/3 倒退；item-only 保留长正文，view-only 从未先增长。这与 A 的“新 view 被旧 item 覆盖”方向不同，分别报告。历史 probe 中人为省略后续新 item 的对照也明确标为人为省略，不能当实际 host 完整序列。

## C. 从旧快照/新指针，到两条消息换序

### 来源与最小前提

CFL 取证 HEAD 65febb05170b665283f56d16127cc11d1640dab5。真实 createCodexChatBackend 的 page() 先 await partner.snapshot，再 await chatReceipt/媒体；read() 最后读取 streamingReply，过滤与当前指针不匹配的快照内 streaming 项。Partner 完成消息时会合入完成项并清空 stream。

只需 a 用户、b 尾部 streaming 助手。三消息版本曾包含后续已完成 c，进一步删除 c 后仍红，因此无需假设特殊的并发后续消息。

### 最小 fake Partner 结构

把此结构接到真实 createCodexChatBackend；gate、hold、held 和 release 是测试自有控制状态，不是产品接口：

```ts
let complete = false;
const partner = {
  async sharedRecovery() { return []; },
  async sharedImageLimits() { return false; },
  async snapshot() {
    return structuredClone({
      sessionId: "fixture-session", name: "Mica",
      cancellable: ["turn"], context: null, lifecycle: { latest: null },
      hasMore: false, before: null,
      messages: [{ id: "a", input: "A", sequence: 1, created: 1,
        turnId: "turn", inputImages: [], delivery: "submitted" }],
      results: [{ id: "result", turnId: "turn", anchorSequence: 1,
        anchorCreated: 1, sourceIds: ["a"], chatStatus: "running",
        timeline: [
          { kind: "user", sourceIds: ["a"], position: 0 },
          { kind: "text", itemId: "b", text: "B", position: 1,
            textState: complete ? "complete" : "streaming" }
        ] }]
    });
  },
  async chatReceipt() {
    if (hold) { held = true; await gate; }
    return { state: "submitted" };
  },
  streamingReply() {
    return complete ? undefined : { id: "b", turnId: "turn", text: "B" };
  },
  replyCompletion() { return undefined; }
};
```

第一次 read 得 [a,b]。第二次等旧 snapshot 已返回、chatReceipt 真正挂起后，设 complete=true 并释放 gate；第三次正常 read。另用独立 fake 做“不在挂起期间完成”的对照。

真实 backend 3/3：

```text
完成发生在读取期间：[a,b] -> [a] -> [a,b]
不发生完成的对照：  [a,b] -> [a,b] -> [a,b]
```

把这三份真实 backend 返回值封装成合成 Chord snapshot/view 更新，真实 Core 3/3：

```text
[a,b] -> [b,a] -> [a,b]
```

Core 将旧 latest 中缺席的 b 移入 older，再拼新 latest 中的 a。首到中间各消息值不变，只有次序变；最后 b 正常变 complete。普通前缀滑出窗口的对照不换序，所以不能直接删除所有缺席项。

**证据级别：**C 的投影来自真实 backend + fake Partner，但协议帧是手工封装；没有通过真实 native、Partner 或 host 捕获这组三帧。A 则重放了真实 host 原始合成帧。它们都没有证明手机出现相同入站序列。

## 在另一台机器重建验证

先按当前代码重新建立以上正式 fixture。历史 .scratch/timeline-layout 探针没有进 Git，不把它当技能依赖；三仓交接分享中保存了门控、输出和当时执行命令：

- [总览 #5416](https://dev.flicknote.app/s/UuqQl4yn0Elt0nQT.md)
- [共享 host #5413](https://dev.flicknote.app/s/EZSDTExa3Sm1aGQ9.md)
- [CFL #5414](https://dev.flicknote.app/s/JH-9l-4Ox8bCTxff.md)
- [ETOS #5415](https://dev.flicknote.app/s/oMGCd9drR7SfMHl1.md)

Core 隔离编译曾用真实的 ChordState.swift、CFLChatModels.swift、CFLChatTransport.swift、CFLAuthorization.swift、CFLChatClient.swift 加 fake；Swift 6.4.1 复用既有 ~/.cache/clang/ModuleCache，临时可执行自动清理。接手先检查现有 runner：当时 run-cfl-chat-checks.py 会创建独立 module cache 且漏掉授权源码，因此未直接使用。缓存或 runner 后来可能已改，按现状判断。

历史 CFL 生成包缺依赖时，诊断 resolve hook 显式借用 App 已安装同版本 typebox/Chord；这是来源清楚的本地诊断，不是正式 pin 构建通过。正式联调仍需匹配已发布归档 revision/摘要和当前 committed HEAD。

## 尚未闭环的层与保留的源码

原始长短长 probe 的字符串没有换行，证明 Core 正文倒退；还需带换行的真实 Core → Model → Projection → adapter 回归。单独手造行相等、合成测试正常或产品编译成功均不能代替此链路及真机观察。

ETOS 取证基线 3b1749a3818cb5087c173d52d5aedcf2153bde96；既有重构和临时仪表随后分别提交为 7e7c1778、b33de41a，五份最终源码与取证工作树逐字节相同。这只保存了诊断状态，没有实现上述数据层修复。新 iOS 测试当时未运行，Mac 产品编译通过也不是测试通过。

临时仪表仍应在原体验验证后移除；若数据倒退/换序消失而几何反向变化仍在，继续独立定位行高、实际队列完成、滚动和 idle 行为。不要从这次发现推出以后所有闪烁都是后端问题。
