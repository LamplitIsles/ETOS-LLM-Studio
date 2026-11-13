import { spawnSync } from 'node:child_process';
import { existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, statSync, unlinkSync, writeFileSync } from 'node:fs';
import { homedir, tmpdir } from 'node:os';
import { join } from 'node:path';

export type Run = (command: string, args: string[], cwd: string, env: NodeJS.ProcessEnv, capture?: boolean) => string;
export const run: Run = (command, args, cwd, env, capture = false) => {
  const result = spawnSync(command, args, { cwd, env, encoding: 'utf8', stdio: capture ? ['ignore', 'pipe', 'inherit'] : 'inherit' });
  if (result.error) throw result.error;
  if (result.status !== 0) throw new Error(`${command} failed (${result.signal ?? result.status})`);
  return result.stdout ?? '';
};

type Device = {
  identifier?: string;
  hardwareProperties?: { deviceType?: string; udid?: string };
  deviceProperties?: { developerModeStatus?: string; name?: string };
  connectionProperties?: { pairingState?: string };
};

export function selectDevice(devices: Device[], requested?: string): string {
  const eligible = devices.filter(d => d.identifier && d.hardwareProperties?.deviceType === 'iPhone' &&
    d.deviceProperties?.developerModeStatus === 'enabled' && d.connectionProperties?.pairingState === 'paired' &&
    (!requested || d.identifier === requested));
  if (!eligible.length) throw new Error('没有找到符合条件的 iPhone：需要已配对并开启开发者模式。');
  if (eligible.length > 1) throw new Error(`找到多台符合条件的 iPhone，请用 --device 指定 identifier：${eligible.map(d => `${d.deviceProperties?.name ?? 'iPhone'} (${d.identifier})`).join(', ')}`);
  return eligible[0].identifier!;
}

export type Configuration = 'Debug' | 'Release';

// 与 expo-client/ios 中共享的 Xcode Cloud 开发壳归档 scheme 保持同一个名字。
export const DEV_ARCHIVE_SCHEME = 'ETOSExpo Dev Archive';

// Prebuild 由 app.json 的 name 派生 Xcode 产物名（PRODUCT_NAME / FULL_PRODUCT_NAME），
// 而工程目录与 target 仍叫 ETOSExpo；因此构建产物是 ETOSChat.app。
export const APP_PRODUCT = 'ETOSChat';

export function ios(action: 'prepare' | 'build' | 'install' | 'acknowledge' | 'archive', options: {
  root: string; env: NodeJS.ProcessEnv; run: Run; device?: string; configuration?: Configuration;
}): void {
  const { root, run, device, configuration = 'Debug' } = options;
  if (configuration !== 'Debug' && configuration !== 'Release') throw new Error('构建配置必须是 Debug 或 Release。');
  const env: NodeJS.ProcessEnv = { ...options.env, DEVELOPER_DIR: '/Applications/Xcode.app/Contents/Developer' };
  const marker = join(root, '.ios-install-unknown.json');
  if (action === 'acknowledge') {
    if (!existsSync(marker)) throw new Error('没有待确认的安装记录。');
    unlinkSync(marker);
    console.log('已确认安装结果；如需重新安装，请另行运行对应的安装命令。');
    return;
  }
  if (action === 'prepare') {
    run(join(root, 'node_modules/.bin/expo'), ['prebuild', '--platform', 'ios', '--no-install', '--no-clean'], root, env);
    const lock = readFileSync(join(root, 'ios/Podfile.lock'), 'utf8');
    const podVersion = /^COCOAPODS: (\S+)\s*$/m.exec(lock)?.[1];
    if (!podVersion) throw new Error('无法从 Podfile.lock 读取 CocoaPods 版本。');
    run(join(root, '../ci_scripts/expo_pod.sh'), ['local', join(root, '.expo/etos-ruby-tools'), podVersion, 'install'], join(root, 'ios'), env);
    return;
  }
  if (action === 'install' && existsSync(marker)) {
    throw new Error(`上次安装结果不明（${marker}）。请先检查设备上的 App，再运行 npm run ios:install:ack 确认；不会自动重试。`);
  }
  const derived = env.ETOS_DERIVED_DATA || join(homedir(), 'Library/Developer/Xcode/DerivedData/ETOS_LLM_Studio-gbdwtrcvmcilytfthkwwgrxdjqbe');
  if (!existsSync(derived) || !statSync(derived).isDirectory()) throw new Error(`DerivedData 目录不存在：${derived}；请指定已有目录 ETOS_DERIVED_DATA。`);
  const app = join(derived, `Build/Products/${configuration}-iphoneos/${APP_PRODUCT}.app`);
  const buildEnv: NodeJS.ProcessEnv = { ...env };
  if (configuration === 'Release') {
    buildEnv.NODE_ENV = 'production';
    delete buildEnv.SKIP_BUNDLING;
  }
  const buildArgs = ['-workspace', 'ios/ETOSExpo.xcworkspace', '-scheme', 'ETOSExpo', '-configuration', configuration,
    '-destination', 'generic/platform=iOS', '-derivedDataPath', derived, '-disableAutomaticPackageResolution', '-jobs', '2', 'ARCHS=arm64'];
  if (action === 'archive') {
    // 复现 Cloud 的开发壳归档：使用根级 ETOSExpo.xcworkspace（cloud 交付的真实入口）、
    // 共享开发归档 scheme、Debug 编译与未签名；不安装也不上传。
    const archivePath = join(root, 'build', 'ETOSExpo-dev.xcarchive');
    rmSync(archivePath, { recursive: true, force: true });
    mkdirSync(join(root, 'build'), { recursive: true });
    run('xcodebuild', ['-workspace', '../ETOSExpo.xcworkspace', '-scheme', DEV_ARCHIVE_SCHEME, '-configuration', 'Debug',
      '-destination', 'generic/platform=iOS', '-derivedDataPath', derived, '-archivePath', archivePath,
      '-disableAutomaticPackageResolution', '-jobs', '2', 'ARCHS=arm64', 'CODE_SIGNING_ALLOWED=NO', 'archive'], root, env);
    console.log(`未签名开发归档已生成：${archivePath}`);
    return;
  }
  if (action === 'build') {
    run('xcodebuild', [...buildArgs, 'CODE_SIGNING_ALLOWED=NO', 'build'], root, buildEnv);
    return;
  }
  console.log('正在查找已配对并开启开发者模式的 iPhone。');
  const temp = mkdtempSync(join(tmpdir(), 'etos-expo-devices-'));
  let selected: string;
  try {
    const output = join(temp, 'devices.json');
    run('xcrun', ['devicectl', 'list', 'devices', '--quiet', '--json-output', output], root, env);
    const data = JSON.parse(readFileSync(output, 'utf8'));
    if (!Array.isArray(data?.result?.devices)) throw new Error('设备列表格式无效。');
    selected = selectDevice(data.result.devices, device);
    const selectedDevice = data.result.devices.find((d: Device) => d.identifier === selected);
    const udid = selectedDevice?.hardwareProperties?.udid;
    if (typeof udid !== 'string' || !udid.trim()) throw new Error('所选 iPhone 缺少 UDID，无法匹配开发描述文件。');
    const deviceFile = join(temp, 'selected.json');
    writeFileSync(deviceFile, JSON.stringify({ udid }), { mode: 0o600 });
    run('python3', [join(root, 'scripts/ios-sign.py'), '--app', app, '--device-file', deviceFile,
      '--team', env.ETOS_DEVELOPMENT_TEAM || 'RL5WAW5828', '--entitlements', join(root, 'ios/ETOSExpo/ETOSExpo.entitlements')], root, env);
  } finally {
    rmSync(temp, { recursive: true, force: true });
  }
  // Write before dispatch: a crash or lost response must not cause an automatic replay.
  writeFileSync(marker, JSON.stringify({ status: 'unknown', device: selected, app, at: new Date().toISOString() }) + '\n', { flag: 'wx' });
  try {
    run('xcrun', ['devicectl', 'device', 'install', 'app', '--device', selected, app, '--timeout', '120'], root, env);
  } catch (error) {
    throw new Error(`安装结果不明，请检查设备并运行 npm run ios:install:ack 确认。${String(error)}`);
  }
  unlinkSync(marker);
  console.log('安装完成；App 未启动。');
}
