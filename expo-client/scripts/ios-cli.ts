import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { ios, run } from './ios.ts';

const [action, ...args] = process.argv.slice(2);
try {
  if (!['prepare', 'build', 'install', 'acknowledge', 'archive'].includes(action)) throw new Error('无效的操作。');
  let configuration: 'Debug' | 'Release' = 'Debug';
  let device: string | undefined;
  if (args[0] === '--configuration') {
    if ((action !== 'build' && action !== 'install') || (args[1] !== 'Debug' && args[1] !== 'Release')) {
      throw new Error('构建配置必须是 Debug 或 Release。');
    }
    configuration = args[1];
    args.splice(0, 2);
  }
  if (action === 'install' && args[0] === '--device' && args.length === 2 && args[1] && !args[1].startsWith('--')) {
    device = args[1];
    args.splice(0, 2);
  }
  if (args.length) throw new Error('用法：ios:prepare | ios:build[:release] | ios:install[:release] [-- --device <identifier>] | ios:install:ack | ios:archive');
  ios(action as 'prepare' | 'build' | 'install' | 'acknowledge' | 'archive', {
    root: resolve(dirname(fileURLToPath(import.meta.url)), '..'), env: process.env, run, device, configuration,
  });
} catch (error) {
  console.error(error instanceof Error ? error.message : error);
  process.exitCode = 1;
}
