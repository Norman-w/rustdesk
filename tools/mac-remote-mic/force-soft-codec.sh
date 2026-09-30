#!/bin/sh
# ===== 分区：导入/依赖 =====
# Forces soft encode defaults so adhoc VideoToolbox H265 does not black-screen.
# Patches user + root RustDesk2.toml when run as root / via admin osascript.

# ===== 分区：常量/配置 =====
set -eu

USER_NAME="${SUDO_USER:-${USER:-norman}}"
USER_HOME="$(/usr/bin/dscl . -read "/Users/$USER_NAME" NFSHomeDirectory 2>/dev/null | /usr/bin/awk '{print $2}')"
[ -n "$USER_HOME" ] || USER_HOME="/Users/$USER_NAME"

# ===== 分区：业务逻辑 =====
/usr/bin/python3 - "$USER_HOME" <<'PY'
from pathlib import Path
import sys

opts = {
    "enable-hwcodec": "N",
    "codec-preference": "vp8",
    "av1-test": "N",
    "enable-file-transfer": "Y",
    "approve-mode": "password",
}

def patch(path: Path) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    text = path.read_text() if path.exists() else "[options]\n"
    lines = text.splitlines()
    out = []
    in_opt = False
    seen = set()
    for line in lines:
        if line.strip() == "[options]":
            in_opt = True
            out.append(line)
            continue
        if in_opt and line.startswith("["):
            for k, v in opts.items():
                if k not in seen:
                    out.append(f"{k} = '{v}'")
            in_opt = False
            out.append(line)
            continue
        if in_opt:
            matched = False
            for k, v in opts.items():
                s = line.strip()
                if s.startswith(k + " ") or s.startswith(k + "="):
                    out.append(f"{k} = '{v}'")
                    seen.add(k)
                    matched = True
                    break
            if not matched:
                out.append(line)
        else:
            out.append(line)
    if "[options]" not in text:
        out.append("[options]")
        in_opt = True
    if in_opt:
        for k, v in opts.items():
            if k not in seen:
                out.append(f"{k} = '{v}'")
    path.write_text("\n".join(out) + "\n")
    print(f"patched {path}")

user_home = Path(sys.argv[1])
paths = [
    user_home / "Library/Preferences/com.carriez.RustDesk/RustDesk2.toml",
]
if Path("/var/root").exists():
    paths.append(Path("/var/root/Library/Preferences/com.carriez.RustDesk/RustDesk2.toml"))
for p in paths:
    try:
        patch(p)
    except PermissionError as exc:
        print(f"skip {p}: {exc}")
PY
