import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { chmodSync, cpSync, existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';
import test from 'node:test';

const repoRoot = fileURLToPath(new URL('../..', import.meta.url));
const ciScripts = join(repoRoot, 'ci_scripts');
const expoScheme = 'ETOSExpo Dev Archive';
const commit = 'a1b2c3d4e5f60718293a4b5c6d7e8f9012345678';
const timeout = 60_000;
const nodeVersion = '24.18.1';
const sha256 = {
  'darwin-arm64': '1d60b703fe5d7e7072489be8187f430f1a095a658c31e5e1e281331a5873fac3',
  'darwin-x64': 'f892c7895720f40d3750bde24f3554242d36f23602b5167b5b73ec4d13938aef',
};

// 必须在把 fake-bin 放进 PATH 之前解析出真实解释器，否则伪 python3 会 exec 回自身。
const realPython = (() => {
  const found = spawnSync('/bin/sh', ['-c', 'command -v python3'], { encoding: 'utf8', timeout });
  assert.equal(found.status, 0, '需要可用的 python3');
  return found.stdout.trim();
})();

// 官方 tarball 里的 node/npm 是真实可执行文件；测试用同名转发脚本代替，
// 并刻意不把 node/npm 放进 fake-bin，以此模拟没有 system Node 的冷启动镜像。
const tarballWrapper = (name: string) => `#!/bin/sh\nexec "$FAKE_TOOLS/${name}-fake" "$@"\n`;

const scripts: Record<string, string> = {
  python3: 'echo "python3 $*" >> "$CALLS"\nexec "$REAL_PYTHON3" "$@"\n',
  'node-fake': 'echo "node $*" >> "$CALLS"\nif [ "$1" = "--version" ]; then echo v24.18.1; fi\nexit 0\n',
  'npm-fake': [
    'echo "npm $* (NODE_USE_ENV_PROXY=${NODE_USE_ENV_PROXY:-unset})" >> "$CALLS"',
    '# 官方 npm 的 shebang 是 env node：PATH 上没有下载的 Node 就必须失败。',
    'resolved="$(command -v node || true)"',
    'case "$resolved" in',
    '  "$EXPECTED_NODE_BIN"/*) ;;',
    '  *) echo "npm 需要 PATH 上的 Node：${resolved:-<none>}" >&2; exit 1 ;;',
    'esac',
    'case "$1" in',
    '  --version) echo 12.0.2 ;;',
    '  ci) if [ "${FAKE_NPM_CI_FAIL:-0}" = 1 ]; then exit 1; fi ;;',
    '  install)',
    '    previous=""',
    '    for argument in "$@"; do',
    '      if [ "$previous" = "--prefix" ]; then prefix="$argument"; fi',
    '      previous="$argument"',
    '    done',
    '    if [ -z "${prefix:-}" ]; then exit 1; fi',
    '    mkdir -p "$prefix/bin"',
    '    printf \'#!/bin/sh\\nexec "$FAKE_TOOLS/npm-fake" "$@"\\n\' > "$prefix/bin/npm"',
    '    chmod +x "$prefix/bin/npm"',
    '    ;;',
    'esac',
    'exit 0',
  ].join('\n') + '\n',
  curl: [
    'echo "curl $*" >> "$CALLS"',
    'previous=""',
    'for argument in "$@"; do',
    '  if [ "$previous" = "-o" ]; then cp "$FAKE_NODE_TARBALL" "$argument"; fi',
    '  previous="$argument"',
    'done',
    'exit 0',
  ].join('\n') + '\n',
  shasum: [
    'echo "shasum $*" >> "$CALLS"',
    'line="$(cat)"',
    'hash="${line%% *}"',
    'if [ -n "${FAKE_EXPECTED_SHA:-}" ] && [ "$hash" != "$FAKE_EXPECTED_SHA" ]; then',
    '  echo "摘要与固定值不一致：$hash" >&2',
    '  exit 1',
    'fi',
    'exit "${FAKE_SHASUM_STATUS:-0}"',
  ].join('\n') + '\n',
  gem: 'echo "unexpected PATH gem $*" >> "$CALLS"\nexit 99\n',
  ruby: [
    'case "$1" in',
    '  -e)',
    '    echo "ruby check $3 $4" >> "$CALLS"',
    '    if [ "$3" = "json" ] && [ "${FAKE_MISSING_JSON:-0}" = 1 ] && [ ! -f "$FAKE_TOOLS/installed-json" ]; then exit 1; fi',
    '    if [ "$3" = "cocoapods" ] && [ "${FAKE_MISSING_POD:-0}" = 1 ] && [ ! -f "$FAKE_TOOLS/installed-pod" ]; then exit 1; fi',
    '    ;;',
    '  -S)',
    '    echo "ruby $*" >> "$CALLS"',
    '    if [ "${FAKE_GEM_STATUS:-0}" != 0 ]; then exit "$FAKE_GEM_STATUS"; fi',
    '    case "$*" in *json:*) touch "$FAKE_TOOLS/installed-json" ;; *cocoapods:*) touch "$FAKE_TOOLS/installed-pod" ;; esac',
    '    ;;',
    '  *)',
    '    runner="$1"; shift',
    '    case "$runner" in */ci_scripts/expo_pod.rb) ;; *) exit 98 ;; esac',
    '    echo "ruby pod $*" >> "$CALLS"',
    '    if [ "${FAKE_RUNNER_STATUS:-0}" != 0 ]; then exit "$FAKE_RUNNER_STATUS"; fi',
    '    case "$2" in --version) echo "$1" ;; install) exit "${FAKE_POD_INSTALL_STATUS:-0}" ;; esac',
    '    ;;',
    'esac',
    'exit 0',
  ].join('\n') + '\n',
  uname: 'echo "uname $*" >> "$CALLS"\necho "${FAKE_UNAME:-arm64}"\n',
  pod: 'echo "unexpected PATH pod $*" >> "$CALLS"\nexit 99\n',
};

type Harness = {
  root: string;
  expoPlist: string;
  swiftPlist: string;
  bin: string;
  tools: string;
  nodePath: string;
  run: (script: string, extraEnv?: Partial<NodeJS.ProcessEnv>) => { status: number | null; stdout: string; stderr: string };
  calls: () => string[];
};

function harness(fn: (harness: Harness) => void, options: { platform?: string } = {}): void {
  const platform = options.platform ?? 'darwin-arm64';
  const root = mkdtempSync(join(tmpdir(), 'etos-ci-test-'));
  const bin = join(root, 'fake-bin');
  const log = join(root, 'calls.log');
  const tools = join(root, 'derived', 'etos-expo-ci-tools');
  const nodePath = join(tools, `node-v${nodeVersion}-${platform}`);
  try {
    mkdirSync(bin, { recursive: true });
    for (const [name, content] of Object.entries(scripts)) {
      writeFileSync(join(bin, name), `#!/bin/sh\n${content}`, { mode: 0o755 });
    }

    const distribution = join(root, 'node-dist');
    const distributionPath = join(distribution, `node-v${nodeVersion}-${platform}`);
    mkdirSync(join(distributionPath, 'bin'), { recursive: true });
    writeFileSync(join(distributionPath, 'bin/node'), tarballWrapper('node'), { mode: 0o755 });
    writeFileSync(join(distributionPath, 'bin/npm'), tarballWrapper('npm'), { mode: 0o755 });
    const tarball = join(root, 'node.tar.gz');
    const packed = spawnSync('tar', ['-czf', tarball, '-C', distribution, `node-v${nodeVersion}-${platform}`], { encoding: 'utf8', timeout });
    assert.equal(packed.status, 0, packed.stderr);

    mkdirSync(join(root, 'ci_scripts'), { recursive: true });
    for (const script of ['ci_post_clone.sh', 'ci_pre_xcodebuild.sh', 'expo_pod.rb']) {
      cpSync(join(ciScripts, script), join(root, 'ci_scripts', script));
      chmodSync(join(root, 'ci_scripts', script), 0o755);
    }
    const expoPlist = join(root, 'expo-client/ios/ETOSExpo/Info.plist');
    mkdirSync(join(root, 'expo-client/ios/ETOSExpo'), { recursive: true });
    cpSync(join(repoRoot, 'expo-client/ios/ETOSExpo/Info.plist'), expoPlist);
    const swiftPlist = join(root, 'ETOS LLM Studio/Config/iOSInfo.plist');
    mkdirSync(join(root, 'ETOS LLM Studio/Config'), { recursive: true });
    cpSync(join(repoRoot, 'ETOS LLM Studio/Config/iOSInfo.plist'), swiftPlist);
    mkdirSync(join(root, 'scripts'), { recursive: true });
    writeFileSync(join(root, 'scripts/sync-extension-localizations.py'),
      'import os, sys\nopen(os.environ["CALLS"], "a").write("sync-extension-localizations " + " ".join(sys.argv[1:]) + "\\n")\n');
    cpSync(join(repoRoot, 'expo-client/ios/Podfile.lock'), join(root, 'expo-client/ios/Podfile.lock'));

    const baseEnv: NodeJS.ProcessEnv = {
      NODE_ENV: 'test',
      PATH: `${bin}:/usr/bin:/bin`,
      HOME: join(root, 'home'),
      CI_PRIMARY_REPOSITORY_PATH: root,
      CI_DERIVED_DATA_PATH: join(root, 'derived'),
      CALLS: log,
      REAL_PYTHON3: realPython,
      FAKE_TOOLS: bin,
      FAKE_NODE_TARBALL: tarball,
      FAKE_EXPECTED_SHA: sha256[platform as keyof typeof sha256],
      EXPECTED_NODE_BIN: join(nodePath, 'bin'),
    };
    fn({
      root,
      expoPlist,
      swiftPlist,
      bin,
      tools,
      nodePath,
      run: (script, extraEnv) => {
        const env = { ...baseEnv, ...extraEnv } as NodeJS.ProcessEnv;
        const result = spawnSync('/bin/sh', [join(root, 'ci_scripts', script)], { encoding: 'utf8', cwd: root, env, timeout });
        if (result.error) throw result.error;
        return { status: result.status, stdout: result.stdout, stderr: result.stderr };
      },
      calls: () => existsSync(log) ? readFileSync(log, 'utf8').trimEnd().split('\n') : [],
    });
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
}

function plistValue(path: string, key: string): string {
  const result = spawnSync(realPython,
    ['-c', 'import plistlib,sys; print(plistlib.load(open(sys.argv[1],"rb"))[sys.argv[2]])', path, key], { encoding: 'utf8', timeout });
  assert.equal(result.status, 0, result.stderr);
  return result.stdout.trim();
}

test('post-clone prepares pinned Node/npm, the lockfile and Pods for the Expo scheme only', () => harness(h => {
  const result = h.run('ci_post_clone.sh', { CI_XCODE_SCHEME: expoScheme });
  assert.equal(result.status, 0, result.stderr);
  assert.deepEqual(h.calls(), [
    'uname -m',
    'curl -fsSL -o ' + join(h.nodePath + '.tar.xz') + ` https://nodejs.org/dist/v${nodeVersion}/node-v${nodeVersion}-darwin-arm64.tar.xz`,
    'shasum -a 256 -c -',
    'npm install -g npm@12.0.2 --prefix ' + join(h.tools, 'npm-12.0.2') + ' (NODE_USE_ENV_PROXY=1)',
    'npm ci (NODE_USE_ENV_PROXY=1)',
    'ruby check json 2.7.1',
    'ruby check cocoapods 1.17.0',
    'node --version',
    'npm --version (NODE_USE_ENV_PROXY=1)',
    'ruby pod 1.17.0 --version',
    'ruby pod 1.17.0 install --deployment',
  ]);
  assert.equal(readFileSync(join(h.root, 'expo-client/ios/.xcode.env.local'), 'utf8'),
    `export NODE_BINARY=${join(h.nodePath, 'bin/node')}\n`);
}));

test('npm bootstrap runs with the downloaded Node although the image has no system Node', () => harness(h => {
  assert.equal(existsSync(join(h.bin, 'node')), false);
  assert.equal(existsSync(join(h.bin, 'npm')), false);
  const result = h.run('ci_post_clone.sh', { CI_XCODE_SCHEME: expoScheme });
  assert.equal(result.status, 0, result.stderr);
  assert.ok(h.calls().includes('npm install -g npm@12.0.2 --prefix ' + join(h.tools, 'npm-12.0.2') + ' (NODE_USE_ENV_PROXY=1)'), h.calls().join('\n'));
  assert.equal(h.calls().at(-1), 'ruby pod 1.17.0 install --deployment');
}));

test('x86_64 hosts install the darwin-x64 toolchain with its own checksum', () => harness(h => {
  const result = h.run('ci_post_clone.sh', { CI_XCODE_SCHEME: expoScheme, FAKE_UNAME: 'x86_64' });
  assert.equal(result.status, 0, result.stderr);
  assert.match(h.calls().find(line => line.startsWith('curl ')) ?? '', /node-v24\.18\.1-darwin-x64\.tar\.xz/);
  assert.equal(readFileSync(join(h.root, 'expo-client/ios/.xcode.env.local'), 'utf8'),
    `export NODE_BINARY=${join(h.root, 'derived', 'etos-expo-ci-tools', `node-v${nodeVersion}-darwin-x64`, 'bin/node')}\n`);
}, { platform: 'darwin-x64' }));

test('an unsupported host architecture stops before downloading anything', () => harness(h => {
  const result = h.run('ci_post_clone.sh', { CI_XCODE_SCHEME: expoScheme, FAKE_UNAME: 'aarch64' });
  assert.notEqual(result.status, 0);
  assert.match(result.stderr, /不受支持/);
  assert.deepEqual(h.calls(), ['uname -m', 'uname -m']);
}));

test('post-clone installs missing gems using the same Ruby before invoking CocoaPods', () => harness(h => {
  const result = h.run('ci_post_clone.sh', { CI_XCODE_SCHEME: expoScheme, FAKE_MISSING_JSON: '1', FAKE_MISSING_POD: '1' });
  assert.equal(result.status, 0, result.stderr);
  const calls = h.calls();
  const jsonInstall = calls.indexOf('ruby -S gem install --no-document --user-install json:2.7.1');
  const podCheck = calls.indexOf('ruby check cocoapods 1.17.0');
  assert.ok(jsonInstall >= 0 && podCheck > jsonInstall, calls.join('\n'));
  assert.ok(calls.includes('ruby -S gem install --no-document --user-install cocoapods:1.17.0'), calls.join('\n'));
  assert.equal(calls.at(-1), 'ruby pod 1.17.0 install --deployment');
}));

test('gem installation and CocoaPods startup failures stop before deployment', () => {
  for (const env of [{ FAKE_MISSING_JSON: '1', FAKE_GEM_STATUS: '7' },
    { FAKE_MISSING_POD: '1', FAKE_GEM_STATUS: '7' }, { FAKE_RUNNER_STATUS: '7' }]) harness(h => {
    const result = h.run('ci_post_clone.sh', { CI_XCODE_SCHEME: expoScheme, ...env });
    assert.equal(result.status, 7, h.calls().join('\n'));
    assert.ok(!h.calls().some(line => line.includes('install --deployment')), h.calls().join('\n'));
  });
});

test('legacy Swift schemes run no Expo dependency preparation', () => harness(h => {
  const result = h.run('ci_post_clone.sh', { CI_XCODE_SCHEME: 'ETOS LLM Studio Cloud' });
  assert.equal(result.status, 0, result.stderr);
  assert.deepEqual(h.calls(), []);
  assert.equal(existsSync(join(h.root, 'expo-client/ios/.xcode.env.local')), false);
}));

test('a Node tarball whose checksum differs from the pinned value stops before npm or Pods', () => harness(h => {
  const result = h.run('ci_post_clone.sh', { CI_XCODE_SCHEME: expoScheme, FAKE_EXPECTED_SHA: 'not-the-pinned-checksum' });
  assert.notEqual(result.status, 0);
  assert.deepEqual(h.calls().map(line => line.split(' ')[0]), ['uname', 'curl', 'shasum']);
  assert.equal(existsSync(join(h.root, 'expo-client/ios/.xcode.env.local')), false);
}));

test('npm and pod failures fail the preparation instead of continuing', () => harness(h => {
  const npmFailure = h.run('ci_post_clone.sh', { CI_XCODE_SCHEME: expoScheme, FAKE_NPM_CI_FAIL: '1' });
  assert.notEqual(npmFailure.status, 0);
  assert.equal(h.calls().filter(line => line.startsWith('ruby ')).length, 0, h.calls().join('\n'));
}));

test('pod install failure fails the preparation', () => harness(h => {
  const result = h.run('ci_post_clone.sh', { CI_XCODE_SCHEME: expoScheme, FAKE_POD_INSTALL_STATUS: '1' });
  assert.notEqual(result.status, 0);
  assert.equal(h.calls().at(-1), 'ruby pod 1.17.0 install --deployment');
}));

test('pre-xcodebuild stamps the Expo plist with the CI build number and commit only', () => harness(h => {
  const swiftBefore = readFileSync(h.swiftPlist, 'utf8');
  const result = h.run('ci_pre_xcodebuild.sh', {
    CI_XCODE_SCHEME: expoScheme, CI_BUILD_NUMBER: '42', CI_COMMIT: commit.slice(0, 20).toUpperCase() + commit.slice(20),
  });
  assert.equal(result.status, 0, result.stderr);
  assert.equal(plistValue(h.expoPlist, 'CFBundleVersion'), '42');
  assert.equal(plistValue(h.expoPlist, 'ETCommitHash'), commit);
  assert.equal(readFileSync(h.swiftPlist, 'utf8'), swiftBefore);
  assert.deepEqual(h.calls(), [`python3 - ${h.expoPlist} 42 ${commit}`]);
}));

test('pre-xcodebuild rejects a zero build number, a missing commit or an invalid commit', () => harness(h => {
  const before = readFileSync(h.expoPlist, 'utf8');
  for (const env of [{ CI_BUILD_NUMBER: '', CI_COMMIT: commit }, { CI_BUILD_NUMBER: 'v12', CI_COMMIT: commit },
    { CI_BUILD_NUMBER: '0', CI_COMMIT: commit }, { CI_BUILD_NUMBER: '007', CI_COMMIT: commit },
    { CI_BUILD_NUMBER: '42' }, { CI_BUILD_NUMBER: '42', CI_COMMIT: '' },
    { CI_BUILD_NUMBER: '42', CI_COMMIT: 'not-a-commit' }, { CI_BUILD_NUMBER: '42', CI_COMMIT: commit.slice(0, 39) }]) {
    const result = h.run('ci_pre_xcodebuild.sh', { CI_XCODE_SCHEME: expoScheme, ...env });
    assert.notEqual(result.status, 0, JSON.stringify(env));
    assert.equal(readFileSync(h.expoPlist, 'utf8'), before, JSON.stringify(env));
  }
  assert.deepEqual(h.calls(), []);
}));

test('pre-xcodebuild keeps the legacy Swift path and never touches the Expo plist', () => harness(h => {
  const expoBefore = readFileSync(h.expoPlist, 'utf8');
  const result = h.run('ci_pre_xcodebuild.sh', { CI_XCODE_SCHEME: 'ETOS LLM Studio App', CI_COMMIT: commit });
  assert.equal(readFileSync(h.expoPlist, 'utf8'), expoBefore);
  assert.deepEqual(h.calls(), [`python3 ${join(h.root, 'scripts/sync-extension-localizations.py')} --check`,
    'sync-extension-localizations --check']);
  // ETCommitHash 仍由 macOS 的 PlistBuddy 写入，其他平台无法验证该步骤。
  if (process.platform !== 'darwin') return;
  assert.equal(result.status, 0, result.stderr);
  assert.equal(plistValue(h.swiftPlist, 'ETCommitHash'), commit);
}));
