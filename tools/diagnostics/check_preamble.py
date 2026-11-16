"""Extract cgo preambles from the generated Go files and syntax-check them with
clang, the same class of error the release build keeps catching.

Point CLANG at a compiler (NDK clang on CI, the local NDK on a dev box). A
missing compiler is a failure, not a skip: the gate's whole value is that it
runs before the release build, and silently skipping it is how a broken
preamble ships green. Set THRONE_SKIP_PREAMBLE_CHECK=1 to skip on purpose.
"""
import os
import re
import shutil
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
PATCH = ROOT / "buildScript" / "core-patch" / "core" / "mobile"
TMP = ROOT / "build" / "preamble_check"
WINDOWS_NDK_CLANG = (
    "C:/Users/ljlgg/AppData/Local/Android/Sdk/ndk/27.0.12077973/"
    "toolchains/llvm/prebuilt/windows-x86_64/bin/clang.exe"
)


def _ndk_clang_from_env() -> list[str]:
    """The clang under an SDK/NDK pointed at by the environment, if any.

    CI exports CLANG directly; a dev box usually only has ANDROID_HOME. Probing the SDK
    keeps the gate working there instead of falling through to "no clang". Only the C
    driver counts: a `clang*` glob also matches clang++, which then treats the generated
    .c as C++ and fails on -Wdeprecated.
    """
    found: list[str] = []
    patterns = ("toolchains/llvm/prebuilt/*/bin/clang", "toolchains/llvm/prebuilt/*/bin/clang.exe")
    roots = [os.environ.get("ANDROID_NDK_HOME"), os.environ.get("ANDROID_NDK_ROOT")]
    android_home = os.environ.get("ANDROID_HOME") or os.environ.get("ANDROID_SDK_ROOT")
    if android_home:
        ndk_root = Path(android_home) / "ndk"
        if ndk_root.is_dir():
            roots.extend(str(p) for p in sorted(ndk_root.iterdir(), reverse=True))
    for root in roots:
        if not root:
            continue
        for pattern in patterns:
            found.extend(str(p) for p in Path(root).glob(pattern))
    return found


def find_clang() -> str | None:
    candidates = [os.environ.get("CLANG"), shutil.which("clang")]
    candidates.extend(_ndk_clang_from_env())
    candidates.append(WINDOWS_NDK_CLANG)
    for candidate in candidates:
        if candidate and Path(candidate).is_file():
            return candidate
    return None


def main() -> int:
    clang = find_clang()
    if clang is None:
        if os.environ.get("THRONE_SKIP_PREAMBLE_CHECK") == "1":
            print("notice: no clang available; skipping (THRONE_SKIP_PREAMBLE_CHECK=1)")
            return 0
        print(
            "FAIL: no clang available, so the cgo preambles were not checked. "
            "Set CLANG to the NDK clang (CI does), or set THRONE_SKIP_PREAMBLE_CHECK=1 "
            "to skip deliberately."
        )
        return 1

    # An NDK clang needs an Android target; a host clang must not be given one
    # (it has no matching sysroot).
    target = ["--target=aarch64-linux-android21"] if "ndk" in clang.lower() else []
    TMP.mkdir(parents=True, exist_ok=True)
    ok = True
    for go_file in sorted(PATCH.glob("*.go")):
        src = go_file.read_text(encoding="utf-8")
        # the cgo preamble is the first /* ... */ block after the package clause
        m = re.search(r"package mobile\s*\n\n/\*(.*?)\*/", src, re.S)
        if not m:
            print(f"{go_file.name}: no cgo preamble, skip")
            continue
        c_body = re.sub(r"^\s*#cgo.*$", "", m.group(1), flags=re.M)
        out_c = TMP / (go_file.stem + "_preamble.c")
        out_c.write_bytes(c_body.encode("utf-8"))
        cmd = [clang, "-fsyntax-only", "-I", str(PATCH),
               "-I", str(PATCH / "dartbridge" / "include"),
               *target, "-std=c11", "-Werror", str(out_c)]
        r = subprocess.run(cmd, capture_output=True, text=True)
        print(f"{go_file.name}: {'OK' if r.returncode == 0 else 'FAIL'}")
        if r.returncode != 0:
            ok = False
            for line in (r.stderr or "").splitlines():
                if "error" in line:
                    print("   ", line)
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
