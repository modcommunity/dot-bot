# History: bugs worth recognising again

## Building it (2026-10-11)

- **A sound made on the same timestamp as a brain's last think was never heard.** `sounds_since(time)` compared `at > since`; the duel's opponent fired after the bot had thought on that tick, at the same time, and every one of its shots was missed. Seen as a bot with its back to a shooter dying without turning round, which made one preset lose 95 duels in 100. Sounds carry a sequence number, and a brain remembers the last one it heard.
- **A config value waiting for the cvars was wiped by the preset it came with.** `bind_cvars` applied a waiting `bot_difficulty` first, which wrote every setting's cvar, and then read `bot_reaction` back as the preset's value. All waiting values are read before any is applied.
- **A bot pre-aimed the body of the target it had just killed for four seconds.** A dead contact was skipped like any other, so the target looked lost and the bot searched for it. Found by looking at the first render, not by any check; a target killed in view is forgotten now, and a sound or a lost target the bot is not going after holds it only for a glance.
- **The duel first said the preset that mattered most was prediction.** A bot trailing a strafing target by 0.15 s of its motion missed a 0.3 m chest at 15 m every time, so medium lost every duel and hard won every one. Tracking lag is 0.08 s at no prediction now, and everybody carries at least half of a target's motion by eye.
