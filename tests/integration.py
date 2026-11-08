"""Headless two-client integration test: loads the whole addon twice against a
stubbed WoW API and plays duels through the real event pipeline.

Usage:  python tests/integration.py
"""
import os
import re
import sys

from lupa import luajit21

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
NOW = 1793750400 + 86400 * 5
TOC = [l.strip() for l in open(os.path.join(ROOT, "Duel", "Duel.toc"), encoding="utf-8")
       if l.strip() and not l.startswith("#")]
FILES = [f.replace("\\", "/") for f in TOC]


class Client:
    def __init__(self, world, name, cls, level=60):
        self.name, self.world = name, world
        self.lua = luajit21.LuaRuntime(unpack_returned_tuples=True)
        g = self.lua.globals()
        g.ME_NAME, g.ME_CLASS, g.ME_LEVEL, g.NOW = name, cls, level, NOW
        g.SEND = self.lua.eval("function(cb) return function(p, m, t, target) cb(p, m, t, target); return 0 end end")(self._send)
        self.lua.execute(open(os.path.join(ROOT, "tests", "wowstub.lua"), encoding="utf-8").read())
        self.ns = g.LOAD_ADDON(ROOT.replace("\\", "/"), self.lua.table_from(FILES))
        g.FIRE("ADDON_LOADED", "Duel")
        g.FIRE("PLAYER_LOGIN")

    def _send(self, prefix, msg, chat_type, target):
        self.world.outbox.append((self.name, prefix, msg, chat_type, target))

    def fire(self, *args):
        self.lua.globals().FIRE(*args)

    def system(self, msg):
        self.lua.globals().SYSTEM(msg)

    def set_target(self, other):
        g = self.lua.globals()
        g.UNITS.target = self.lua.table_from({"name": other.name, "class": other.cls, "level": other.level})

    def run(self, code):
        return self.lua.execute(code)


class World:
    def __init__(self):
        self.outbox, self.clients, self.log = [], {}, []
        self.drop = None

    def add(self, name, cls, level=60):
        c = Client(self, name, cls, level)
        c.cls, c.level = cls, level
        self.clients[name] = c
        return c

    def pump(self):
        n = 0
        while self.outbox:
            sender, prefix, msg, chat_type, target = self.outbox.pop(0)
            n += 1
            self.log.append((sender, chat_type, target, msg))
            if self.drop and self.drop(sender, chat_type, target, msg):
                continue
            if chat_type == "WHISPER":
                dest = self.clients.get(target)
                if dest:
                    dest.fire("CHAT_MSG_ADDON", prefix, msg, "WHISPER", sender)
                else:
                    self.clients[sender].system("No player named '%s' is currently playing." % target)
            elif chat_type in ("GUILD", "PARTY", "RAID"):
                for name, c in self.clients.items():
                    if name != sender and getattr(c, "guild", True):
                        c.fire("CHAT_MSG_ADDON", prefix, msg, chat_type, sender)
        return n

    def advance(self, sec, step=0.25):
        t = 0
        while t < sec:
            for c in self.clients.values():
                c.lua.globals().ADVANCE(step)
            self.pump()
            t += step


passed, failed = 0, []


def test(name):
    def deco(fn):
        global passed
        try:
            fn()
            passed += 1
        except Exception as e:  # noqa: BLE001
            import traceback
            failed.append(name + "\n" + traceback.format_exc())
        return fn
    return deco


def rating(c, who):
    return c.lua.eval("function(ns, who) local p = ns.players[who]; return p and p.r end")(c.ns, who)


def status_of(c, match_id):
    return c.lua.eval("function(ns, id) local r = ns.ledger:Get(id); return r and ns.Ledger.Status(r) end")(c.ns, match_id)


def last_entry(c):
    return c.lua.eval("""function(ns) local h = ns.db.history[ns.me.name]; local e = h and h[#h]
        if not e then return nil end
        return e.result, e.mode, e.match, e.delta end""")(c.ns)


def duel(w, a, b, winner, consent_a=True, consent_b=True, how="K", drop=None):
    """a challenges b; both answer the prompt; winner decides."""
    a.set_target(b)
    b.set_target(a)
    a.lua.globals().StartDuel("target")
    b.fire("DUEL_REQUESTED", a.name)
    w.advance(1)
    a.run("ADDON_NS.agreement:Consent(%s)" % ("true" if consent_a else "false"))
    b.run("ADDON_NS.agreement:Consent(%s)" % ("true" if consent_b else "false"))
    w.advance(1)
    w.drop = drop
    for c in (a, b):
        c.system("Duel starting: 3")
    w.advance(4)
    loser = b if winner is a else a
    line = ("%s has defeated %s in a duel" % (winner.name, loser.name)) if how == "K" \
        else ("%s has fled from %s in a duel" % (loser.name, winner.name))
    for c in (a, b):
        c.system(line)
        c.fire("DUEL_FINISHED")
    w.advance(3)
    w.drop = None


@test("ranked duel: both verify, ratings move by 20, leaderboards agree")
def _():
    w = World()
    a = w.add("Alice Stone", "MAGE")
    b = w.add("Bob Marsh", "ROGUE")
    duel(w, a, b, winner=a)
    ra, mode, mid, delta = last_entry(a)
    assert ra == "W" and mode == "R", (ra, mode)
    assert status_of(a, mid) == "verified" and status_of(b, mid) == "verified"
    for c in (a, b):
        assert rating(c, "Alice Stone") == 1520, rating(c, "Alice Stone")
        assert rating(c, "Bob Marsh") == 1480


@test("casual when one side declines ranked")
def _():
    w = World()
    a = w.add("Alice Stone", "MAGE")
    b = w.add("Bob Marsh", "ROGUE")
    duel(w, a, b, winner=b, consent_b=False)
    for c in (a, b):
        r, mode, mid, _ = last_entry(c)
        assert mode == "C" and mid is None, (c.name, mode)
        assert rating(c, "Bob Marsh") is None


@test("opponent without the addon: casual, no handshake noise in chat")
def _():
    w = World()
    a = w.add("Alice Stone", "MAGE")
    ghost = type("G", (), {"name": "Carl Nomod", "cls": "WARRIOR", "level": 60})()
    a.set_target(ghost)
    a.lua.globals().StartDuel("target")
    w.advance(1)
    a.system("Duel starting: 3")
    w.advance(4)
    a.system("Carl Nomod has defeated Alice Stone in a duel")
    a.fire("DUEL_FINISHED")
    w.advance(2)
    r, mode, mid, _ = last_entry(a)
    assert r == "L" and mode == "C", (r, mode)
    printed = list(a.lua.globals().PRINTED.values())
    assert not any("No player named" in str(p) for p in printed)


@test("lost LOCK message: challenger casual, match never verifies, no rating change")
def _():
    w = World()
    a = w.add("Alice Stone", "MAGE")
    b = w.add("Bob Marsh", "ROGUE")
    duel(w, a, b, winner=a, drop=lambda s, t, tg, m: m.startswith("L~"))
    w.advance(5)
    _, mode_a, _, _ = last_entry(a)
    _, mode_b, mid_b, _ = last_entry(b)
    assert mode_a == "C" and mode_b == "R"
    assert status_of(b, mid_b) != "verified"
    assert rating(b, "Alice Stone") is None


@test("cancelled duel records nothing")
def _():
    w = World()
    a = w.add("Alice Stone", "MAGE")
    b = w.add("Bob Marsh", "ROGUE")
    a.set_target(b); b.set_target(a)
    a.lua.globals().StartDuel("target")
    b.fire("DUEL_REQUESTED", a.name)
    w.advance(1)
    for c in (a, b):
        c.system("Duel starting: 3")
    w.advance(5)
    for c in (a, b):
        c.fire("DUEL_FINISHED")
    w.advance(6)
    assert last_entry(a) is None and last_entry(b) is None


@test("third client learns the verified result through guild sync")
def _():
    w = World()
    a = w.add("Alice Stone", "MAGE")
    b = w.add("Bob Marsh", "ROGUE")
    c = w.add("Carl Third", "PRIEST")
    for x in (a, b, c):
        x.lua.globals().IsInGuild = x.lua.eval("function() return true end")
    duel(w, a, b, winner=b)
    w.advance(700, step=1)   # guild inventory announcements + sync sessions
    assert rating(c, "Bob Marsh") == 1520, rating(c, "Bob Marsh")
    _, _, mid, _ = last_entry(a)
    # Carl heard the match second-hand, then asked the participants directly.
    direct = c.lua.eval("function(ns, id) return ns.Ledger.DirectCount(ns.ledger:Get(id)) end")(c.ns, mid)
    assert direct == 2, direct


@test("forged relayed match is denied by its participant")
def _():
    w = World()
    a = w.add("Alice Stone", "MAGE")
    m = w.add("Mallory Evil", "ROGUE")
    c = w.add("Carl Third", "PRIEST")
    w.advance(5)
    forged = c.lua.eval("""function(ns)
        local r = ns.Ledger.Validate({ id = ns.Util.Id("fake"), ts = GetServerTime(), a = "Alice Stone",
            b = "Mallory Evil", w = "b", how = "K", la = 60, lb = 60, ca = "MAGE", cb = "ROGUE" })
        r.cf = { a = 1, b = 1 }
        return ns.Ledger.Encode(r), r.id end""")
    line, fid = forged(c.ns)
    # Mallory relays a forged "Mallory beat Alice" to Carl (claims both confirmed).
    c.fire("CHAT_MSG_ADDON", "DuelLadder", line, "WHISPER", "Zed Relay")
    assert status_of(c, fid) == "verified"
    w.advance(30)
    assert status_of(c, fid) == "disputed", status_of(c, fid)
    assert rating(c, "Mallory Evil") is None


@test("/duel (secure StartDuel) reaches our commands; /duel Name still challenges")
def _():
    w = World()
    a = w.add("Alice Stone", "MAGE")
    g = a.lua.globals()
    g.StartDuel("")
    assert a.lua.eval("DuelLadderFrame and DuelLadderFrame:IsShown()")
    g.StartDuel("selftest")
    printed = " ".join(str(p) for p in g.PRINTED.values())
    assert "all" in printed and "checks passed" in printed, printed
    assert a.lua.eval("ADDON_NS.tracker.state") == "idle"
    g.StartDuel("Bob Marsh")
    assert a.lua.eval("ADDON_NS.tracker.state") == "requested"
    g.SlashCmdList.DUELLADDER("status")
    assert "verified" in " ".join(str(p) for p in g.PRINTED.values())


@test("repeat duels vs the same mate shrink and stop")
def _():
    w = World()
    a = w.add("Alice Stone", "MAGE")
    b = w.add("Bob Marsh", "ROGUE")
    deltas = []
    for _ in range(5):
        duel(w, a, b, winner=a)
        w.advance(5)
        deltas.append(a.lua.eval("function(ns, id) local d = ns.deltas[id]; return d and d.weight end")(a.ns, last_entry(a)[2]))
    assert deltas == [1, 0.5, 0.25, 0, 0], deltas


if __name__ == "__main__":
    for f in failed:
        print("FAIL", f)
    print("%d passed, %d failed" % (passed, len(failed)))
    sys.exit(1 if failed else 0)
