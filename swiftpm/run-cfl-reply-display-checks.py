#!/usr/bin/env python3
"""Run the source-line display checks on Linux using the existing Swift build cache."""
from pathlib import Path
import os
import subprocess
import sys

if sys.platform != "linux":
    sys.exit("This runner uses the existing Linux SwiftPM build products.")

root = Path(__file__).resolve().parent.parent
os.chdir(root)
build = ["swift", "build", "--disable-automatic-resolution"]
subprocess.run(build + ["--target", "Markdown", "--jobs", "1"], check=True)
products = Path(subprocess.check_output(build + ["--show-bin-path"], text=True).strip())
binary = root / ".build/etos-tools/cfl-reply-display-check"
binary.parent.mkdir(parents=True, exist_ok=True)
subprocess.run([
    "swiftc", "-I", str(products),
    "-I", ".build/checkouts/swift-cmark/src/include",
    "-I", ".build/checkouts/swift-cmark/extensions/include",
    "-I", ".build/checkouts/swift-markdown/Sources/CAtomic/include",
    "-module-cache-path", ".build/out/ModuleCache.noindex",
    "ETOS LLM Studio/ETOS LLM Studio iOS App/Views/CFLReplyPresentation.swift",
    "swiftpm/RuntimeTests/CFLReplyDisplayChecks.swift",
    *[str(products / (name + ".o")) for name in
      ("Markdown", "CAtomic", "cmark-gfm", "cmark-gfm-extensions")],
    "-o", str(binary),
], check=True)
subprocess.run([str(binary)], check=True)
