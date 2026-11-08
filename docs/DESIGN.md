# Duel Ladder — design notes

## 1. Research findings (Nov 2026)

**Client.** WoW Forever is product `wowf`, client 1.60.1.70862, TOC `## Interface: 16001`.
It runs the modern (12.x) engine with classic-era gameplay. That means modern APIs (`C_ChatInfo`,
`C_Timer`, `BackdropTemplate`, `Settings`, `MenuUtil`, `issecretvalue`/`canaccessvalue`) and
secret-value restrictions (health and mana are hidden from addons, per DuelElo). The max level is 60.

**Names.** Characters are "First Last". The API may append `-Realm`, which is not part of the
identity. Whispers to "First Last" cross realms (Overlord, tested 2026-11-05). `UnitName` can drop the
surname, so we prefer `GetUnitName(unit, true)` / `GetPlayerInfoByGUID`.

**Networking (Overlord 2.2.x, the reference implementation):**
- Since launch (2026-11-04) the server **refuses addon messages on custom channels** (code 7 or
  `NOT_ALLOWED_IN_CHANNEL`). A hidden channel no longer carries data.
- A custom channel's **member list** is still readable (`C_ChatInfo.GetChannelRosterInfo`), once the
  list is fetched by selecting the channel for display. Overlord uses it as a peer directory and
  whispers the members.
- GROUP/RAID/GUILD/CHANNEL share ~1 addon message/s per prefix; bursts get refused (measured
  2026-09-27). Whispers have a separate budget.
- `C_BattleNet.SendGameData` reaches Battle.net friends on Forever (project id 18), including
  cross-faction.
- Guild addon chat works, but should be used sparingly.

**Duel detection (DuelElo, Overlord):** `DUEL_REQUESTED(challenger)`, a hook on `StartDuel`,
`CHAT_MSG_SYSTEM` matched against the client's `DUEL_COUNTDOWN`, `DUEL_WINNER_KNOCKOUT` and
`DUEL_WINNER_RETREAT` strings, and `DUEL_FINISHED`, which fires for results, declines and cancels.

**Existing projects:**
- *DuelElo*: Glicko-2. Results are signed with per-character HMAC keys and verified by an external
  website (duelelo.com). Peer stats are self-reported.
- *Forever Duels*: Elo, results agreed by both sides over hidden messages, no external server.
- *Forever PvP Leaderboards*: data ships with the download from a website, faction-specific,
  diminishing returns on repeat opponents.

None of them derives ratings from a shared, verifiable match list without a server.

## 2. Architecture

```
Core/   pure Lua, no WoW API at load — unit tested under LuaJIT
  Init        constants, rules, helpers (hash, base36, names, format parsing)
  Elo         K-factors, expected score, tiers
  Ledger      match records, attestations, verification states, deterministic rating replay
  Agreement   Ranked/Casual handshake state machine
  DuelTracker duel lifecycle from game signals
  SyncProto   inventory / day-bucket / id-list encoding (anti-entropy)
  SyncEngine  per-peer sync sessions
  DB          SavedVariables layout, validation, migration
Net/    Transport (throttled send queues, receive, offline-whisper filter)
        Directory (hidden-channel member list → peers), Network (routing, gossip, vouching)
Game/   Controller (events → tracker → handshake → ledger → network/UI), Evidence (server stats)
UI/     Theme, Main window, Prompt, Result banner, Minimap button
```

## 3. Ranked flow

1. A challenges B. A sees it through the `StartDuel` hook (fallback: B's HELLO naming A as
   challenger). B sees `DUEL_REQUESTED`.
2. Both whisper `HELLO` (protocol, version, nonce, level, class). If the other side has no addon,
   nothing comes back and the duel stays casual.
3. Each side clicks Ranked or Casual, or a saved preference answers. Eligibility: same level
   bracket (10-19, 20-29 ... 50-59, 60), at most 2 levels apart, not your own alt, same protocol.
4. B (the challenged side) **locks** the mode when the countdown starts. It is ranked only if both
   consented. B sends `LOCK`, and A adopts it. If `LOCK` is lost, A stays casual.
5. The winner line arrives. Each side builds the same record. The match id is the hash of both names
   and both nonces. Each side stores its **own attestation** and whispers it to the other.
6. With both attestations the record is **verified**. Every client re-derives ratings from all
   verified records, so the banner shows a projected change that becomes final.
7. The verified record spreads by gossip and anti-entropy sync to guild, party, directory peers and
   Battle.net friends.

## 4. Rating

Every level bracket (10-19, 20-29, 30-39, 40-49, 50-59, 60) is an independent ladder with its own
ratings, history and leaderboard. A match counts in the bracket both players share.

Elo, start 1500. K is 40 for the first 10 counted games, 24 after that, 16 at 2000+. Deltas are
integers. Ratings are **never read from the network**: each client replays verified records in
(timestamp, id) order. When two attestations differ by a second, the timestamp converges on the
earliest.

Elo was chosen over Glicko-2 for transparency and simple deterministic replay of a list that grows
out of order. Glicko-2's rating periods do not map cleanly onto P2P gossip.

Tiers: Provisional (<10 counted games), Bronze <1400, Silver, Gold 1550, Platinum 1700,
Diamond 1850, Grandmaster 2000. The leaderboard lists ranked players: 10+ counted games against
5+ different opponents.

## 5. Competitive integrity — what is and is not guaranteed

| Threat | Mitigation | Strength |
|---|---|---|
| Fake result about *you* | Needs your client's attestation, and the server authenticates whisper senders | strong |
| Duplicate / replayed results | Deterministic match ids, idempotent merge | strong |
| Forged rating values | Ratings are derived, never transmitted | strong |
| Win trading with a mate | 24 h weights 100/50/25/0 %, 6 counted per pair per week, lopsided-pair freeze (6+ games in 30 d, ≥85 % one way), fled = 50 % | limits gains, cannot stop it |
| Low-level / fresh alts | Separate ladder per level bracket (an alt only affects its own bracket), ±2 levels, no ranked below 10. Established vs provisional = half gains. Own characters excluded | good |
| Relayed forgeries (modified client invents matches) | Per-source cap on unverified records. Participants are asked directly (`CQ`). A participant online at the claimed time denies it. "Unvouched" markers and an optional filter | partial |
| Conflicting versions | A participant's differing version disputes the match. A third party's is ignored | good |
| Corrupted SavedVariables | Every record and entry validated on load, invalid ones dropped and counted | good |
| Version mismatch | Protocol number in HELLO and inventory. Mismatch means casual only, with an update notice | good |
| Desync / lost messages | Day-bucketed anti-entropy with retries, sessions time out and restart | good |

**Limits.** This is an addon-only system, so a modified client can still lie about matches it
relays, and it can win-trade within the caps. A forgery placed at a time when the named
participants were offline cannot be denied. It stays marked as unvouched. A player who loses
SavedVariables (crash before logout, a second PC) can only vouch for what their client still holds.

**Server evidence.** If the client exposes duel statistics (319 "Duels won" / 320 "Duels lost"),
Duel reads the opponent's server-side counters before and after the fight through the achievement
comparison API. The result is local evidence (★ in History). `/duel probe` shows whether the
client supports it.

**Possible next step.** Per-character signing keys, pinned on first direct contact, would make
relayed forgeries cryptographically detectable.

## 6. Wire protocol (prefix `DuelLadder`, protocol 1)

```
H~proto~version~nonce~role~level~class~rating~games      hello (whisper)
R~theirNonce~1|0~reason                                  consent
L~theirNonce~R|C                                         lock (challenged → challenger)
M~id~ts36~a~b~w~how~la~lb~ca~cb~fa~fb                    record / attestation
SI~proto~count~root36~version                            inventory
SD | SB~day:n:h,... | SBE | SL~day | SLI~day~id+flag,... | SLE~day | SG~id,...   sync
CQ~id:ts36,...   CA~id:1|0|?,...   DN~id~name             vouching
```
Every message is ≤ 255 bytes.
