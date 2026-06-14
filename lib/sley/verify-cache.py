#!/usr/bin/env python3
"""Success receipt helper for `sley verify --run-required`.

The shell side owns registry discovery and command execution. This helper owns
the parts where byte framing and atomic file handling matter: key construction,
receipt validation, and receipt I/O. A receipt is only allowed to prove that a
previous command passed when this helper can account for every input in the key.
Unknown or unsupported inputs should become misses or hard errors, not hits.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import stat
import subprocess
import sys
import tempfile
import time
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

SCHEMA = 1
ALGORITHM = 1


class IdentityInputError(ValueError):
    """Raised when a registry-declared identity input cannot be evaluated."""


def sha_bytes(data: bytes) -> str:
    return "sha256:" + hashlib.sha256(data).hexdigest()


def canon(obj: Any) -> bytes:
    return json.dumps(obj, sort_keys=True, separators=(",", ":"), ensure_ascii=False).encode()


def cache_root() -> Path:
    root = os.environ.get("XDG_CACHE_HOME")
    if root:
        return Path(root) / "sley" / "verify"
    return Path.home() / ".cache" / "sley" / "verify"


def ensure_private_dir(path: Path) -> None:
    path.mkdir(parents=True, exist_ok=True)
    try:
        path.chmod(0o700)
    except OSError:
        pass


def machine_id(root: Path) -> str:
    machine_id_path = Path("/etc/machine-id")
    if machine_id_path.is_file():
        return sha_bytes(machine_id_path.read_bytes().strip())

    ident_path = root / "machine-id"
    if ident_path.is_file():
        return sha_bytes(ident_path.read_bytes().strip())

    ensure_private_dir(root)
    token = os.urandom(32).hex().encode()
    fd, tmp_name = tempfile.mkstemp(prefix=".machine-id.", dir=str(root))
    try:
        with os.fdopen(fd, "wb") as f:
            f.write(token)
            f.write(b"\n")
            f.flush()
            os.fsync(f.fileno())
        os.chmod(tmp_name, 0o600)
        try:
            # os.link gives create-if-absent semantics on Linux and macOS. A
            # plain rename would let concurrent first runs race and replace
            # each other's machine identity, making cache keys unstable.
            os.link(tmp_name, ident_path)
        except FileExistsError:
            pass
    finally:
        try:
            os.unlink(tmp_name)
        except FileNotFoundError:
            pass
    return sha_bytes(ident_path.read_bytes().strip())


def _vcs_output(binary: str, args: list[str], cwd: Path) -> str | None:
    try:
        result = subprocess.run(
            [binary, *args],
            cwd=str(cwd),
            check=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            text=True,
        )
    except (OSError, subprocess.CalledProcessError):
        return None
    return result.stdout.strip()


def git_output(args: list[str], cwd: Path) -> str | None:
    return _vcs_output("git", args, cwd)


def sl_output(args: list[str], cwd: Path) -> str | None:
    return _vcs_output("sl", args, cwd)


def repo_identity(payload: dict[str, Any], root: Path) -> dict[str, Any]:
    repo_type = payload["repo_type"]
    ident: dict[str, Any] = {
        "type": repo_type,
        "root": str(root),
    }
    if repo_type == "git":
        ident["git_dir"] = git_output(["rev-parse", "--absolute-git-dir"], root)
        ident["remote"] = git_output(["config", "--get", "remote.origin.url"], root)
    elif repo_type == "sl":
        ident["sl_store"] = str(root / ".sl") if (root / ".sl").exists() else None
    return ident


def git_base_identity(root: Path, policy: str) -> dict[str, Any]:
    upstream = git_output(
        ["rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{upstream}"], root
    )
    upstream_tip = git_output(["rev-parse", "--verify", "--quiet", "@{upstream}"], root)
    head = git_output(["rev-parse", "--verify", "--quiet", "HEAD"], root)
    merge_base = None
    if upstream_tip and head:
        merge_base = git_output(["merge-base", upstream_tip, head], root)
        if merge_base == head:
            # A branch with no semantic delta from upstream should not get a
            # stronger base identity than an actually changed branch. The
            # selected-content policy can still opt out of base identity.
            merge_base = None
    key: dict[str, Any] = {"policy": policy}
    metadata = {
        "upstream_ref": upstream,
        "upstream_tip": upstream_tip,
        "merge_base": merge_base,
    }
    if policy == "upstream-tip":
        key.update(metadata)
    elif policy == "merge-base":
        key["merge_base"] = merge_base
    elif policy == "selected-content":
        pass
    else:
        raise ValueError(f"unsupported base_policy: {policy}")
    return {"key": key, "metadata": metadata}


def sl_base_identity(root: Path, policy: str) -> dict[str, Any]:
    public_ancestor = sl_output(["log", "-r", "last(public() & ::.)", "-T", "{node}"], root)
    public_tip = sl_output(["log", "-r", "last(public())", "-T", "{node}"], root)
    # Draft node ids are conservative for v1: metadata-only amends may miss the
    # cache, but they cannot create a false hit. A future patch-id based Sapling
    # key can relax this after it is tested against stacked draft workflows.
    draft_text = sl_output(["log", "-r", "sort(draft() & ::., topo)", "-T", "{node}\\n"], root)
    draft_chain = [line for line in (draft_text or "").splitlines() if line]
    metadata = {
        "public_ancestor": public_ancestor,
        "public_tip": public_tip,
        "draft_chain": draft_chain,
    }
    key: dict[str, Any] = {"policy": policy}
    if policy == "upstream-tip":
        key.update(metadata)
    elif policy == "merge-base":
        key["public_ancestor"] = public_ancestor
        key["draft_chain"] = draft_chain
    elif policy == "selected-content":
        pass
    else:
        raise ValueError(f"unsupported base_policy: {policy}")
    return {"key": key, "metadata": metadata}


def file_record(root: Path, rel: str) -> dict[str, Any]:
    path = root / rel
    try:
        st = os.lstat(path)
    except FileNotFoundError:
        return {"path": rel, "kind": "missing"}

    mode = st.st_mode
    if stat.S_ISREG(mode):
        return {
            "path": rel,
            "kind": "file",
            "executable": bool(mode & 0o111),
            "content": sha_bytes(path.read_bytes()),
        }
    if stat.S_ISLNK(mode):
        # Hash the link itself, not the target contents. Following a symlink can
        # silently pull out-of-scope files into the key and make scope reasoning
        # depend on host-specific filesystem layout.
        return {
            "path": rel,
            "kind": "symlink",
            "target": os.readlink(path),
        }
    if stat.S_ISDIR(mode):
        return {"path": rel, "kind": "directory"}
    return {"path": rel, "kind": "unsupported", "mode": stat.S_IFMT(mode)}


def shell_args(shell_mode: str) -> list[str]:
    # Cached commands default to a non-login shell so user startup files are not
    # hidden inputs. Registry authors can opt into login shell behavior, but then
    # they own declaring startup-file/toolchain identity in the cache config.
    if shell_mode == "login":
        return ["bash", "-lc"]
    if shell_mode in ("", "default"):
        return ["bash", "-c"]
    raise ValueError(f"unsupported cache.shell: {shell_mode}")


def identity_output(command: str, root: Path, timeout: int, shell_mode: str) -> dict[str, Any]:
    try:
        result = subprocess.run(
            [*shell_args(shell_mode), command],
            cwd=str(root),
            check=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            timeout=timeout,
        )
    except (OSError, subprocess.CalledProcessError, subprocess.TimeoutExpired) as exc:
        raise IdentityInputError(f"identity command failed: {command}") from exc
    return {
        "command": command,
        "cwd": str(root),
        "shell": "bash -lc" if shell_mode == "login" else "bash -c",
        "timeout": timeout,
        # stderr is intentionally diagnostic-only. Some tools emit telemetry or
        # progress there, which would make receipts churn without improving the
        # correctness proof.
        "stdout": sha_bytes(result.stdout),
    }


def identity_env_output(name: str) -> dict[str, Any]:
    if name not in os.environ:
        raise IdentityInputError(f"identity env is not set: {name}")
    return {
        "name": name,
        # The value is key material but not audit material. Receipts should
        # prove that the same environment was used without persisting private
        # paths, modes, tokens, or other user-specific values in clear text.
        "value": sha_bytes(os.environ[name].encode()),
    }


def key_material(payload: dict[str, Any], root: Path, cache_dir: Path) -> dict[str, Any]:
    command = payload["command"]
    cache = command.get("cache") if isinstance(command.get("cache"), dict) else {}
    policy = cache.get("base_policy") or "upstream-tip"
    shell_mode = str(cache.get("shell") or "default")
    shell_args(shell_mode)
    files = sorted(f for f in payload.get("files", []) if f)
    paths = sorted(f for f in payload.get("paths", []) if f)

    identity = cache.get("identity") if isinstance(cache.get("identity"), dict) else {}
    command_identities = []
    env_identities = []
    timeout = int(cache.get("identity_timeout", 5))
    for env_name in identity.get("env", []) or []:
        env_identities.append(identity_env_output(str(env_name)))
    for identity_cmd in identity.get("commands", []) or []:
        command_identities.append(identity_output(str(identity_cmd), root, timeout, shell_mode))

    if payload["repo_type"] == "git":
        base = git_base_identity(root, str(policy))
    elif payload["repo_type"] == "sl":
        base = sl_base_identity(root, str(policy))
    else:
        raise ValueError(f"unsupported repo_type: {payload['repo_type']}")
    # Content hashing is intentionally based on the selected worktree files,
    # not the textual diff. Test runners read the filesystem, so the cache key
    # must model filesystem state rather than how the VCS happened to describe
    # the pending change.
    content_records = [file_record(root, rel) for rel in files]

    return {
        "algorithm": ALGORITHM,
        "machine": machine_id(cache_dir),
        "repo": repo_identity(payload, root),
        "vcs": payload["repo_type"],
        "base": base["key"],
        "scope": {
            "change": payload.get("scope_change"),
            "include_untracked": bool(payload.get("include_untracked")),
            "repo_wide": bool(payload.get("repo_wide")),
            "paths": paths,
            "files": files,
        },
        "content": content_records,
        "command": {
            "command": command.get("command"),
            "kind": command.get("kind") or "test",
            "tier": command.get("tier") or "fast",
            "shell": shell_mode,
            "cache": cache,
            "identity": {
                "env": env_identities,
                "commands": command_identities,
            },
            "config": command.get("source_contexts", []),
        },
        "metadata": {
            "base": base["metadata"],
        },
    }


def receipt_paths(key: str, root: Path) -> tuple[Path, Path, Path]:
    hex_key = key.removeprefix("sha256:")
    receipts = root / "receipts"
    tmp = root / "tmp"
    return receipts, tmp, receipts / f"sha256-{hex_key}.json"


def compute(payload: dict[str, Any]) -> tuple[str, dict[str, Any], Path]:
    root = Path(payload["repo_root"])
    cache_dir = cache_root()
    material = key_material(payload, root, cache_dir)
    # `metadata` is for receipts and explanation. It may include useful audit
    # context, such as the current upstream tip, that a specific base policy
    # intentionally chose not to make cache-invalidating.
    key_input = dict(material)
    key_input.pop("metadata", None)
    key = sha_bytes(canon(key_input))
    return key, material, cache_dir


def lookup(payload: dict[str, Any]) -> dict[str, Any]:
    key, material, root = compute(payload)
    receipts, _tmp, receipt = receipt_paths(key, root)
    if receipt.is_symlink() or not receipt.is_file():
        return {"status": "miss", "key": key, "receipt": str(receipt), "material": material}
    try:
        data = json.loads(receipt.read_text())
    except (OSError, json.JSONDecodeError):
        # Corrupt receipts are treated like absent receipts. The next successful
        # run will rewrite them; failing open here would be the dangerous case.
        return {"status": "miss", "key": key, "receipt": str(receipt), "material": material}
    if (
        data.get("schema") == SCHEMA
        and data.get("cache_algorithm") == ALGORITHM
        and data.get("key") == key
        and data.get("status") == "passed"
    ):
        return {"status": "hit", "key": key, "receipt": str(receipt), "material": material}
    return {"status": "miss", "key": key, "receipt": str(receipt), "material": material}


def write(payload: dict[str, Any]) -> dict[str, Any]:
    key, material, root = compute(payload)
    receipts, tmp_dir, receipt = receipt_paths(key, root)
    ensure_private_dir(root)
    ensure_private_dir(receipts)
    ensure_private_dir(tmp_dir)
    nosync = root / ".nosync"
    try:
        nosync.touch(exist_ok=True)
    except OSError:
        pass
    body = {
        "schema": SCHEMA,
        "cache_algorithm": ALGORITHM,
        "key": key,
        "status": "passed",
        "exit_code": 0,
        "completed_at": datetime.now(timezone.utc).replace(microsecond=0).isoformat(),
        "repo": material["repo"],
        "scope": material["scope"],
        "base": material["metadata"]["base"],
        # Store audit hashes instead of raw commands/config. The live registry
        # remains the source of truth for `--explain-cache`, while receipts stay
        # small and avoid persisting private command strings unnecessarily.
        "command": {
            "cmd_hash": sha_bytes(str(material["command"]["command"]).encode()),
            "kind": material["command"]["kind"],
            "tier": material["command"]["tier"],
            "shell": material["command"]["shell"],
            "cache_enabled": True,
            "cache_hash": sha_bytes(canon(material["command"]["cache"])),
        },
    }
    fd, tmp_name = tempfile.mkstemp(prefix=".receipt.", suffix=".json", dir=str(tmp_dir))
    try:
        with os.fdopen(fd, "w") as f:
            json.dump(body, f, sort_keys=True, separators=(",", ":"))
            f.write("\n")
            f.flush()
            os.fsync(f.fileno())
        os.chmod(tmp_name, 0o600)
        # Readers only accept complete JSON files. Writing in tmp/ and renaming
        # into receipts/ keeps lookup from observing partial receipt contents.
        os.replace(tmp_name, receipt)
    finally:
        try:
            os.unlink(tmp_name)
        except FileNotFoundError:
            pass
    prune(root, keep=receipt)
    return {"status": "written", "key": key, "receipt": str(receipt)}


def prune(root: Path, keep: Path | None = None) -> None:
    receipts = root / "receipts"
    if not receipts.is_dir():
        return
    cutoff = time.time() - (30 * 24 * 60 * 60)
    recent_cutoff = time.time() - 60
    for path in receipts.iterdir():
        if keep is not None and path == keep:
            continue
        if not path.name.startswith("sha256-") or not path.name.endswith(".json"):
            continue
        digest = path.name[len("sha256-") : -len(".json")]
        if len(digest) != 64 or any(ch not in "0123456789abcdef" for ch in digest):
            continue
        try:
            st = path.lstat()
        except OSError:
            continue
        if stat.S_ISLNK(st.st_mode) or not stat.S_ISREG(st.st_mode):
            continue
        # Skip very recent files so a writer from another process does not race
        # with pruning. The shell lock prevents same-key races; this protects
        # against broad cache cleanup colliding with unrelated keys.
        if st.st_mtime >= recent_cutoff or st.st_mtime >= cutoff:
            continue
        try:
            path.unlink()
        except OSError:
            pass


def stats() -> dict[str, Any]:
    root = cache_root()
    receipts = root / "receipts"
    count = 0
    bytes_total = 0
    if receipts.is_dir():
        for path in receipts.iterdir():
            if path.is_symlink() or not path.is_file():
                continue
            if not path.name.startswith("sha256-") or not path.name.endswith(".json"):
                continue
            count += 1
            try:
                bytes_total += path.stat().st_size
            except OSError:
                pass
    return {"status": "ok", "receipts": count, "bytes": bytes_total, "root": str(root)}


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("action", choices=["lookup", "write", "stats"])
    args = parser.parse_args()
    try:
        if args.action == "stats":
            result = stats()
        else:
            payload = json.load(sys.stdin)
        if args.action == "lookup":
            try:
                result = lookup(payload)
            except IdentityInputError as exc:
                # Identity inputs are optional cache inputs. If one cannot be
                # evaluated, the test command should still run; only the cache
                # proof is unavailable for this invocation.
                result = {"status": "identity-error", "error": str(exc)}
        elif args.action == "write":
            result = write(payload)
    except Exception as exc:  # noqa: BLE001 - shell caller needs one message.
        print(json.dumps({"status": "error", "error": str(exc)}, separators=(",", ":")))
        return 1
    print(json.dumps(result, separators=(",", ":")))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
