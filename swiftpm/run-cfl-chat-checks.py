#!/usr/bin/env python3
"""Run the CFL fixture checks in the explicitly approved, test-owned directory."""
import os
from pathlib import Path
import shutil
import subprocess
import sys

root = Path('/tmp/etos-cfl-4960-check')
root.mkdir(mode=0o700)  # Fail if anything already exists; never remove someone else's files.
try:
    executable = root / 'cfl-check'
    sources = [
        'ETOSCore/ETOSCore/CFLChat/ChordState.swift',
        'ETOSCore/ETOSCore/CFLChat/CFLChatModels.swift',
        'ETOSCore/ETOSCore/CFLChat/CFLChatTransport.swift',
        'ETOSCore/ETOSCore/CFLChat/CFLChatClient.swift',
        'swiftpm/RuntimeTests/CFLChatChecks.swift',
    ]
    environment = dict(os.environ, ETOS_CFL_TEST_ROOT=str(root), TMPDIR=str(root))
    subprocess.run(['swiftc', '-module-cache-path', str(root / 'module-cache'), *sources, '-o', str(executable)], check=True, env=environment)
    subprocess.run([str(executable)], check=True, env=environment)
finally:
    shutil.rmtree(root)
