#!/usr/bin/env python3
"""通过 libvirt qemu guest agent 在虚拟机内执行命令（无需 SSH 凭据）。

用法:
  python3 scripts/vm-exec.py [--uri qemu:///system] <虚拟机名> '<shell 命令>' [超时秒数]

--uri 可省略，默认 qemu:///system；也可由 build-in-vm.sh 从 config/vm.env 传入，
从而避免在脚本中硬编码任何本机 libvirt 连接信息。
"""

import argparse
import base64
import json
import subprocess
import sys
import time


def agent(uri, vm, payload, timeout=30):
    proc = subprocess.run(
        ["virsh", "-c", uri, "qemu-agent-command", vm, json.dumps(payload)],
        capture_output=True,
        text=True,
        timeout=timeout,
    )
    out = proc.stdout
    pos = out.find("{")
    if pos < 0:
        raise RuntimeError(f"guest-agent 无 JSON 响应: {out!r} {proc.stderr!r}")
    return json.loads(out[pos:])["return"]


def main():
    parser = argparse.ArgumentParser(add_help=False)
    parser.add_argument("--uri", default="qemu:///system")
    parser.add_argument("vm")
    parser.add_argument("command")
    parser.add_argument("timeout", nargs="?", type=int, default=3600)
    args = parser.parse_args()

    ret = agent(args.uri, args.vm, {
        "execute": "guest-exec",
        "arguments": {
            "path": "/bin/bash",
            "arg": ["-lc", args.command],
            "capture-output": True,
        },
    })
    pid = ret["pid"]
    deadline = time.time() + args.timeout
    while time.time() < deadline:
        status = agent(args.uri, args.vm, {
            "execute": "guest-exec-status",
            "arguments": {"pid": pid},
        })
        if status.get("exited"):
            sys.stdout.write(base64.b64decode(status.get("out-data", "")).decode("utf-8", "replace"))
            sys.stderr.write(base64.b64decode(status.get("err-data", "")).decode("utf-8", "replace"))
            return status.get("exitcode", 0)
        time.sleep(0.5)
    print(f"TIMEOUT: {args.vm} 内命令超过 {args.timeout}s 未完成 (pid={pid})", file=sys.stderr)
    return 124


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Exception as exc:  # noqa: BLE001
        print(f"ERROR: {exc}", file=sys.stderr)
        sys.exit(1)
