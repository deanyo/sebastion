# Duel Ladder — ranked duels for WoW Forever

Chess-style Elo ladder for normal Blizzard duels. Both players agree to *Ranked*, the result is
confirmed by both clients, ratings are re-derived by everyone from the shared match list, and the
leaderboard syncs peer-to-peer. No external server is involved.

- `/duel` opens the ladder: profile with rating graph, leaderboard (search and class filters),
  history, and settings with network status. Right-click the minimap button for the leaderboard.
- `/duel Name Surname` still challenges a player (Blizzard behaviour). `/ladder` is an alias.
- `/duel help` lists everything: `status`, `sync`, `probe`, `selftest`, `pairs`,
  `test win|lose|prompt`, `debug`.

Design, research and the honest security model: [docs/DESIGN.md](docs/DESIGN.md).

## Install

Copy the `Duel` folder to `World of Warcraft\_forever_\Interface\AddOns\`, or run `./deploy.sh`.

## Tests

```
pip install lupa
python tests/run.py          # unit tests: Elo, ledger, handshake, tracker, sync convergence
python tests/integration.py  # two full addon instances against a stubbed WoW API
```

## Testing with two WoW clients

1. Install on both clients. Two accounts on one Battle.net license work: `WoW1` and `WoW2` in the
   launcher.
2. Log a **level 60** character in on each, same faction, near each other. Type `/duel selftest` on
   both. It should report all checks passed.
3. Run `/duel probe` once and note whether "statistics usable" is true. That decides whether the
   ★ server-evidence badge can ever appear.
4. Client A: right-click B's portrait and choose *Duel*. The *Ranked or casual?* prompt appears on
   both. Click **Ranked** on both, then accept the duel on B.
5. The prompt switches to *Ranked duel — locked*. Fight. The banner shows VICTORY/DEFEAT with
   `1500 > 1520 +20` and changes to *Verified by both players* within a second or two.
6. `/duel` → Leaderboard → tick *Show unranked* (you need 10 games against 5 opponents to be
   listed by default). Both clients show identical numbers.
7. Edge cases to try:
   - one side clicks Casual: nothing changes
   - walk out of bounds: fled, counts half
   - cancel the duel mid-countdown: nothing recorded
   - a second and third duel against the same opponent: the prompt warns 50 % / 25 %
   - `/reload` on one side mid-duel: the result is recorded casual on that side, so the match never
     verifies
8. `/duel status` shows peers, records and send/refuse counters. Turn on `/duel debug` to watch
   messages.
