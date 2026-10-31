# CFL protocol fixture provenance

`cfl-chord-js.json` was emitted in memory by Lamplit App commit
`b446bebc6308205fb5c7165a69d6bb7a804fe233`: its `fixtureBackend`,
`createChatHost`, and installed `@earendil-works/chord` 1.0.0. It contains
one singleton subscription followed by fake submit and stop, with no real data.
At that commit, `tests/fixture.ts` is covered by the repository's Apache-2.0
`LICENSE`, and `packages/contracts/package.json` declares `@lamplit/contracts`
0.1.0 as Apache-2.0. The installed Chord 1.0.0 `package.json` declares MIT
and names Earendil Works as author; that installed package has no LICENSE file.

`chord-delta-js.json` contains batches encoded by that installed Chord version's
`encoder`; the expected values were produced by its `apply`. It exercises root
replacement, append/truncate, path definitions and references, splice,
permutation, and deletion. These fixtures establish compatibility with the
referenced implementation; they are not evidence of a live CFL connection.
