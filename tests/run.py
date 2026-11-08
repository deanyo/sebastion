"""Run the Lua test suite under LuaJIT (Lua 5.1 semantics, like WoW).

Usage:  python tests/run.py          (needs: pip install lupa)
"""
import glob
import os
import sys

from lupa import luajit21

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def main():
    lua = luajit21.LuaRuntime(unpack_returned_tuples=True)
    lua.globals().ROOT = ROOT.replace("\\", "/")
    harness = os.path.join(ROOT, "tests", "harness.lua")
    lua.execute(open(harness, encoding="utf-8").read())
    specs = sorted(glob.glob(os.path.join(ROOT, "tests", "*_spec.lua")))
    if len(sys.argv) > 1:
        specs = [s for s in specs if any(a in s for a in sys.argv[1:])]
    for spec in specs:
        lua.globals().run_spec(os.path.basename(spec), open(spec, encoding="utf-8").read())
    passed, failed, report = lua.globals().summary()
    print(report)
    sys.exit(1 if failed > 0 else 0)


if __name__ == "__main__":
    main()
