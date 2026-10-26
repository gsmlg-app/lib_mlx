#!/usr/bin/env python3
"""Recover the pinned E2B snapshot. All downloaded bytes are verified before use."""
import argparse
import hashlib
import json
from pathlib import Path
import shutil
import subprocess


def verify(path, entry):
    if not path.is_file() or path.stat().st_size != entry["size"]:
        return False
    digest = hashlib.sha256() if "sha256" in entry else hashlib.sha1()
    if "git_blob_sha1" in entry:
        digest.update(f"blob {entry['size']}\0".encode())
    with path.open("rb") as source:
        for block in iter(lambda: source.read(8 * 1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest() == entry.get("sha256", entry.get("git_blob_sha1"))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("destination", type=Path)
    parser.add_argument("--verify-only", action="store_true")
    args = parser.parse_args()
    lock_path = Path(__file__).with_name("model-lock.json")
    lock = json.loads(lock_path.read_text())
    args.destination.mkdir(parents=True, exist_ok=True)
    for entry in lock["files"]:
        target = args.destination / entry["path"]
        if verify(target, entry):
            print(f"verified {entry['path']}", flush=True)
            continue
        if args.verify_only:
            raise SystemExit(f"Missing or corrupt asset: {target}")
        partial = target.with_suffix(target.suffix + ".partial")
        url = (f"https://huggingface.co/{lock['repository']}/resolve/"
               f"{lock['revision']}/{entry['path']}")
        print(f"fetching {entry['path']} ({entry['size']} bytes)", flush=True)
        subprocess.run(["curl", "--fail", "--location", "--retry", "2",
                        "--continue-at", "-", "--output", str(partial), url],
                       check=True)
        if not verify(partial, entry):
            raise SystemExit(f"Integrity check failed: {partial}; remove it to retry")
        partial.replace(target)
    shutil.copyfile(lock_path, args.destination / "lib_mlx-model.json")
    print(f"Verified {lock['repository']}@{lock['revision']} in {args.destination}")


if __name__ == "__main__":
    main()
