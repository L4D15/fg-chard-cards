# ChatCards — Design Documentation

Living documentation for how the extension works and the decisions behind it.
Add a dated entry to the decision log whenever we settle something new.

## Goal

Replace Fantasy Grounds Unity's plain chat log with rich, card-style messages
in the spirit of D&D Beyond's roll cards. Target ruleset: **5E**.

## Reference mockup

![Chat cards mockup](mockup-chat-cards.png)

`mockup-chat-cards.png` (2026-07-28) is the visual north star. It defines:

- **Action cards** (attack / damage): portrait top-left; gold header bar with
  the actor name (left, dark) and the action title "Melee Strike: Shortsword"
  (right, white); italic subtitle line with the controlling user
  ("Gamemaster" / player nickname); body lines `Target: Ireena Kolyana (AC 15)`
  and `Modifiers: Base +14, Bless +1`; keyword chips bottom-left (red for the
  action type — Attack — gold for weapon properties — Agile, Finesse); a
  result box on the right with a gold strip showing the formula
  (`d20+15 vs 15`), the big total (`22`/`7`/`18`), and the outcome label
  (green *Success*, red *Failure*, tan *Damage*).
- **Speech cards**: portrait, gold name bar, italic nickname subtitle, framed
  cream text panel with the spoken line.
- **Banners**: single-line gold bars for system events — `Turn: Ireena
  Kolyana`, `Ireena Kolyana takes 7 damage` (with the number bolded).
- **Palette**: parchment card bodies on the chat frame, gold (#B99C5B-ish)
  bars and banners, cream text panels, red accent chips, white result boxes.

## How the extension works

```
                        sending client                     every client
                  ┌──────────────────────────┐      ┌────────────────────────┐
 5E action roll ─►│ ActionAttack.onAttack-   │      │ chatcards_card OOB     │
                  │ Resolve wrap / "damage"  ├─OOB─►│ handler → action card  │
                  │ handler wrap: capture    │      │ in the cards list      │
                  │ structured rRoll data    │      └────────────────────────┘
                  └────────────┬─────────────┘
                               │ original text message (unchanged)
                               ▼
                  hidden engine chatwindow  ◄─── keeps /log, entry box,
                  (1x1, invisible)               other extensions working
                               │
 speech/banners ─► ChatManager receive callback ─► speech card / banner
                   ([ATTACK]/[DAMAGE] text skipped to avoid duplicates)
```

Three layers:

1. **Display** (`desktop/desktop_chatcards.xml`): overrides CoreRPG's `chat`
   windowclass. Our `windowlist name="cards"` replaces the visible log and
   accepts the same dice/number/string drops. Card windowclasses live in
   `common/windowclass_chatcards.xml`; chips and portraits are templates in
   `common/template_chatcards.xml`.
2. **Message classification** (`scripts/manager_chatcards.lua`,
   `ChatCardsManager`): every received chat message becomes a card — dice
   messages → generic roll card, speech modes → speech card, anything else →
   banner. Exposes `addCard`/`sendCardOOB`/`buildDiceFormula` helpers.
3. **Ruleset data capture** (`scripts/chatcards_5e.lua`, `ChatCards5E`):
   wraps 5E resolution functions to grab data that no longer exists once the
   message text is flattened (target AC, hit/miss/crit, net modifier), and
   broadcasts it as an OOB message so all clients render identical cards.

## Decision log

### 2026-07-28 — Replace the chat display, don't restyle it
FGU's `chatwindow` control is compiled into the client; per-message layout
(portrait placement, single font per message, no sub-frames) is not moddable.
The mockup is impossible inside it. **Decision:** hide the engine control at
1×1 (it must exist — the chat entry targets it — and feeding it preserves
`/log` export and third-party extension compatibility) and render our own
windowlist. Cost we accept: we re-implement scrollback trimming, autoscroll,
and drop handling ourselves.

### 2026-07-28 — Capture structured data at action resolution, not from text
Parsing `[ATTACK (M)] Shortsword [HIT]` strings would break with localization
and ruleset updates, and the modifier breakdown/AC aren't in the text anyway.
**Decision:** hook `ActionAttack.onAttackResolve(rSource, rTarget, rRoll,
rMessage)` (called through the `ActionAttack` table, so table-replacement
works) and re-register the `"damage"` result handler around
`ActionDamageD20.onRoll` (CoreRPG captured the original reference at init, so
re-registration is required, not table replacement). `rRoll` carries `nTotal`,
`nDefenseVal`, `sResult`, `nMod`, `aDice`.

### 2026-07-28 — Broadcast cards as OOB messages
Custom fields on chat messages don't survive network delivery, and resolution
runs only on the rolling client. **Decision:** card payloads travel as a
`chatcards_card` OOB message (`Comm.deliverOOBMessage`) delivered to every
client, GM included. All OOB values are stringified in transit — card scripts
treat every field as a string. The original flattened text message still goes
to the hidden chat log; the receive callback skips `[ATTACK`/`[DAMAGE` texts
so cards aren't duplicated.

### 2026-07-28 — One `chatcard_action` class for attack/damage/roll
Attack, damage, and generic rolls share ~90% of their layout (header, body
lines, chips, result box). **Decision:** one windowclass configured by
`setData` (`sCardType` picks chip/outcome styling) instead of three near-copies.

### 2026-07-28 — Placeholder art, real fonts
All frames are generated flat-color 9-slice PNGs (regenerate with
`Design/gen_frames.py`) matching the mockup palette, so the
whole look can be replaced by swapping PNGs without code changes. Fonts are
Noto Sans TTFs copied from the user's CoreRPG (SIL OFL), with card-specific
sizes/colors defined in `graphics/graphics_chatcards.xml`.

### 2026-07-28 — Secret rolls produce no card
Dice-tower and GM-hidden rolls would leak information if broadcast.
**Decision:** `bSecret`/`secret` rolls are skipped entirely on the card layer;
they still behave normally in the hidden engine log.

## Open questions (to resolve during in-app testing)

- Do list windows auto-size to their bottom-most anchored control (`sizer`),
  or do card classes need explicit heights?
- Does `onReceiveMessage` fire for locally-sent messages (local echo), or do
  we need a deliver-side callback with dedup?
- NPC portraits: `portrait_<identity>_chat` icons only exist for PCs — use a
  `tokencontrol` with the CT token for NPCs?
- Where to capture the itemized modifier breakdown ("Base +14, Bless +1") —
  likely `ActionAttack.applyEffectsToRollMod`.
- Weapon property chips (Agile/Finesse) need a lookup on the source actor's
  weapon/power node; not present in `rRoll`.
