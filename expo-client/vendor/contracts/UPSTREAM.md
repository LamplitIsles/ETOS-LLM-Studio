Copied from LamplitIsles/lamplit-app `packages/contracts/src` at commit
`6b70e24d8732a3ac9a6f7b10fe82ab4613c84933`. Copyright and license apply as
specified in LICENSE. Kept locally because @lamplit/contracts is not published
on npm; update the snapshot as a unit with its wire compatibility tests.

Local ETOS change: `src/client.ts` omits the `openChat` stop-turn method.
The shared wire service, schemas, and test-host server retain the upstream
stop member for protocol compatibility. Reapply this client-only change when
updating the snapshot and run the wire and fixture tests.
