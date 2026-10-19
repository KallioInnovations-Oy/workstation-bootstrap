#!/usr/bin/python3 -I
"""Summarise LUKS2 key slots from `cryptsetup luksDump --dump-json-metadata`.

Reads the JSON on stdin and prints one line per slot:
  tpm2  <slot> <pcrs, comma separated, or "none">
  other <slot>
"tpm2" slots belong to a systemd-tpm2 token; every other slot is unlocked by a
typed secret (install passphrase or recovery key).
"""
import json
import sys

meta = json.load(sys.stdin)
tpm_slots = {}
for token in meta.get("tokens", {}).values():
    if token.get("type") != "systemd-tpm2":
        continue
    pcrs = token.get("tpm2-pcrs", [])
    for slot in token.get("keyslots", []):
        tpm_slots[str(slot)] = ",".join(str(p) for p in pcrs) or "none"

for slot in sorted(meta.get("keyslots", {}), key=int):
    if slot in tpm_slots:
        print(f"tpm2 {slot} {tpm_slots[slot]}")
    else:
        print(f"other {slot}")
