import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { mkdtempSync, readFileSync, rmSync, writeFileSync, existsSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import test from 'node:test';
import { ios, selectDevice, type Configuration, type Run } from '../scripts/ios.ts';

const phone = (identifier: string) => ({ identifier, hardwareProperties: { deviceType: 'iPhone', udid: 'fake-udid' },
  deviceProperties: { developerModeStatus: 'enabled', name: identifier },
  connectionProperties: { pairingState: 'paired', tunnelState: 'disconnected' } });

test('selects paired iPhone with developer mode; multiple require an identifier', () => {
  const invalid = [ { ...phone('ipad'), hardwareProperties: { deviceType: 'iPad' } },
    { ...phone('unpaired'), connectionProperties: { pairingState: 'unpaired' } },
    { ...phone('disabled'), deviceProperties: { developerModeStatus: 'disabled' } } ];
  assert.equal(selectDevice([...invalid, phone('one')]), 'one');
  assert.throws(() => selectDevice(invalid), /没有找到/);
  assert.throws(() => selectDevice([phone('one'), phone('two')]), /--device/);
  assert.equal(selectDevice([phone('one'), phone('two')], 'two'), 'two');
  assert.throws(() => selectDevice([phone('one')], 'missing'), /没有找到/);
});

function fixture(fn: (f: { root: string; calls: { command: string; args: string[]; cwd: string; env: NodeJS.ProcessEnv }[];
  execute: (action: 'prepare' | 'build' | 'install' | 'acknowledge', run?: Run, configuration?: Configuration) => void; fake: Run }) => void) {
  const root = mkdtempSync(join(tmpdir(), 'etos-ios-test-'));
  const calls: { command: string; args: string[]; cwd: string; env: NodeJS.ProcessEnv }[] = [];
  const fake: Run = (command, args, cwd, env) => {
    calls.push({ command, args, cwd, env });
    if (command === 'gem') return '/fake/user-gems\n';
    if (command === 'python3') {
      assert.deepEqual(JSON.parse(readFileSync(args[args.indexOf('--device-file') + 1], 'utf8')), { udid: 'fake-udid' });
    }
    if (args[0] === 'devicectl' && args[1] === 'list') {
      writeFileSync(args[args.indexOf('--json-output') + 1], JSON.stringify({ result: { devices: [phone('one')] } }));
    }
    return '';
  };
  try { fn({ root, calls, fake, execute: (action, runner = fake, configuration = 'Debug') => ios(action, { root, env: { NODE_ENV: 'test', SKIP_BUNDLING: '1', ETOS_DERIVED_DATA: root, ETOS_DEVELOPMENT_TEAM: 'CUSTOM' }, run: runner, configuration }) }); }
  finally { rmSync(root, { recursive: true, force: true }); }
}

test('prepare explicitly generates without cleaning then uses existing user CocoaPods', () => fixture(({ root, calls, execute }) => {
  execute('prepare');
  assert.deepEqual(calls.map(c => [c.command, c.args, c.cwd]), [
    [join(root, 'node_modules/.bin/expo'), ['prebuild', '--platform', 'ios', '--no-install', '--no-clean'], root],
    ['gem', ['environment', 'user_gemhome'], root],
    ['/fake/user-gems/bin/pod', ['install'], join(root, 'ios')],
  ]);
}));

test('unsigned build and install sign the existing Debug app without compiling', () => fixture(({ root, calls, execute }) => {
  execute('build');
  assert.equal(calls.length, 1);
  const unsigned = calls[0];
  assert.equal(unsigned.command, 'xcodebuild');
  assert.deepEqual(unsigned.args, ['-workspace', 'ios/ETOSExpo.xcworkspace', '-scheme', 'ETOSExpo', '-configuration', 'Debug', '-destination', 'generic/platform=iOS', '-derivedDataPath', root, '-disableAutomaticPackageResolution', '-jobs', '2', 'ARCHS=arm64', 'CODE_SIGNING_ALLOWED=NO', 'build']);
  assert.equal(unsigned.env.DEVELOPER_DIR, '/Applications/Xcode.app/Contents/Developer');
  assert.equal(unsigned.env.NODE_ENV, 'test');
  assert.equal(unsigned.env.SKIP_BUNDLING, '1');
  calls.length = 0;
  execute('install');
  assert.deepEqual(calls.map(c => c.command), ['xcrun', 'python3', 'xcrun']);
  assert.equal(calls[1].args[0], join(root, 'scripts/ios-sign.py'));
  assert.equal(calls[1].args[calls[1].args.indexOf('--app') + 1], join(root, 'Build/Products/Debug-iphoneos/ETOSExpo.app'));
  assert.equal(calls[1].args[calls[1].args.indexOf('--team') + 1], 'CUSTOM');
  assert.deepEqual(calls[2].args, ['devicectl', 'device', 'install', 'app', '--device', 'one', join(root, 'Build/Products/Debug-iphoneos/ETOSExpo.app'), '--timeout', '120']);
  assert.equal(existsSync(join(root, '.ios-install-unknown.json')), false);
}));

test('signing failure never dispatches install or creates unknown marker', () => fixture(({ root, calls, execute, fake }) => {
  const failing: Run = (cmd, args, cwd, env, capture) => {
    if (cmd === 'python3') throw new Error('sign failed');
    return fake(cmd, args, cwd, env, capture);
  };
  assert.throws(() => execute('install', failing), /sign failed/);
  assert.equal(calls.filter(c => c.args[1] === 'device').length, 0);
  assert.equal(existsSync(join(root, '.ios-install-unknown.json')), false);
}));

test('uncertain install persists and blocks replay until explicit acknowledgement', () => fixture(({ root, calls, execute, fake }) => {
  const failing: Run = (cmd, args, cwd, env, capture) => {
    if (args[0] === 'devicectl' && args[1] === 'device') throw new Error('connection lost');
    return fake(cmd, args, cwd, env, capture);
  };
  assert.throws(() => execute('install', failing), /安装结果不明/);
  assert.deepEqual(JSON.parse(readFileSync(join(root, '.ios-install-unknown.json'), 'utf8')).status, 'unknown');
  const count = calls.length;
  assert.throws(() => execute('install'), /不会自动重试/);
  assert.equal(calls.length, count);
  execute('acknowledge');
  assert.equal(calls.length, count);
  execute('install');
  assert.equal(calls.at(-1)?.args[1], 'device');
}));

test('Release build and install use Release output and production bundling environment', () => fixture(({ root, calls, execute }) => {
  execute('build', undefined, 'Release');
  assert.equal(calls.length, 1);
  assert.equal(calls[0].args[calls[0].args.indexOf('-configuration') + 1], 'Release');
  assert.ok(calls[0].args.includes('CODE_SIGNING_ALLOWED=NO'));
  assert.equal(calls[0].env.NODE_ENV, 'production');
  assert.equal(calls[0].env.SKIP_BUNDLING, undefined);
  calls.length = 0;
  execute('install', undefined, 'Release');
  assert.deepEqual(calls.map(c => c.command), ['xcrun', 'python3', 'xcrun']);
  assert.equal(calls[1].args[calls[1].args.indexOf('--app') + 1], join(root, 'Build/Products/Release-iphoneos/ETOSExpo.app'));
  assert.equal(calls[1].env.NODE_ENV, 'test');
  assert.equal(calls[2].args.at(-3), join(root, 'Build/Products/Release-iphoneos/ETOSExpo.app'));
}));

test('unknown install blocks the other configuration in both directions', () => {
  for (const [first, second] of [['Debug', 'Release'], ['Release', 'Debug']] as const) {
    fixture(({ calls, execute, fake }) => {
      const failing: Run = (cmd, args, cwd, env, capture) => {
        if (args[0] === 'devicectl' && args[1] === 'device') throw new Error('connection lost');
        return fake(cmd, args, cwd, env, capture);
      };
      assert.throws(() => execute('install', failing, first), /安装结果不明/);
      const count = calls.length;
      assert.throws(() => execute('install', undefined, second), /不会自动重试/);
      assert.equal(calls.length, count);
    });
  }
});

test('CLI rejects invalid configurations and ambiguous arguments before any action', () => {
  const cli = fileURLToPath(new URL('../scripts/ios-cli.ts', import.meta.url));
  for (const args of [ ['build', '--configuration', 'Production'], ['build', '--configuration'],
    ['prepare', '--configuration', 'Release'], ['install', '--configuration', 'Release', '--configuration', 'Debug'],
    ['install', '--device', 'one', '--configuration', 'Release'] ]) {
    const result = spawnSync(process.execPath, ['--experimental-strip-types', cli, ...args], { encoding: 'utf8', env: { NODE_ENV: 'test' } });
    assert.equal(result.status, 1, JSON.stringify(args));
    assert.match(result.stderr, /配置必须是|用法/);
  }
});

test('missing hardware UDID prevents signing and install', () => fixture(({ root, calls, execute, fake }) => {
  const withoutUdid: Run = (cmd, args, cwd, env, capture) => {
    if (cmd === 'xcrun' && args[1] === 'list') {
      writeFileSync(args[args.indexOf('--json-output') + 1], JSON.stringify({ result: { devices: [{ ...phone('one'), hardwareProperties: { deviceType: 'iPhone' } }] } }));
      return '';
    }
    return fake(cmd, args, cwd, env, capture);
  };
  assert.throws(() => execute('install', withoutUdid), /缺少 UDID/);
  assert.equal(calls.length, 0);
  assert.equal(existsSync(join(root, '.ios-install-unknown.json')), false);
}));
