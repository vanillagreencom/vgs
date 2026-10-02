#!/usr/bin/env python3
# Only the download-consent answer is variable. No user terminal or file read.
import json, pathlib, sys
p = pathlib.Path(__file__).parent.parent / 'browser-mode.json'
mode = json.loads(p.read_text()) if p.exists() else {}
sys.exit(mode.get('confirmExit', 0) if sys.argv[1:2] == ['confirm'] else 0)
