# ChatCards (v0.1 scaffold)

Card-style chat message display for Fantasy Grounds Unity, 5E ruleset.
Replaces the visible chat log with a scrolling list of custom card windows
(attack cards, damage cards, speech cards, and one-line banners) while keeping
the engine's real chat display alive but hidden, so `/log` export and other
extensions keep working.

Design documentation — reference mockup, architecture diagram, and the
decision log — lives in [`Design/`](Design/README.md).

## Architecture

- **`desktop/desktop_chatcards.xml`** — overrides CoreRPG's `chat` windowclass.
  The compiled `chatwindow` control is shrunk to 1x1 and made invisible (the
  chat entry box requires it to exist, and feeding it preserves the chat log).
  A `windowlist` named `cards` takes over the display area and accepts
  dice/number/string drops like the original chat window did.
- **`scripts/manager_chatcards.lua`** (`ChatCardsManager`) — global manager.
  Listens to `ChatManager.registerReceiveMessageCallback` and classifies every
  incoming message: dice → generic roll card, speech modes → speech card,
  everything else → banner. Also defines the `chatcards_card` OOB message that
  carries structured card data to every client.
- **`scripts/chatcards_5e.lua`** (`ChatCards5E`) — 5E hooks. Wraps
  `ActionAttack.onAttackResolve` and re-registers the `damage` result handler
  around `ActionDamageD20.onRoll` to capture structured data (`rRoll.nTotal`,
  `nDefenseVal`, `sResult`, target, modifiers) *before* it is flattened into
  chat text, then broadcasts a card OOB. The flattened `[ATTACK ...]` /
  `[DAMAGE ...]` text messages are suppressed on the card side to avoid
  duplicates (they still reach the hidden real chat log).
- **`common/windowclass_chatcards.xml`** — the three card windowclasses:
  `chatcard_action` (attack/damage/roll with header bar, portrait, body lines,
  keyword chips, result box), `chatcard_speech`, `chatcard_banner`.
- **`graphics/`** — placeholder 9-slice frames (generated flat-color art) and
  fonts. Swap the PNGs in `graphics/frames/` and the colors in
  `graphics_chatcards.xml` to restyle everything without touching code.

## Known gaps / to verify in-app (v0.1)

1. **Card window heights** — assumes list windows size to their bottom-most
   anchored control (`sizer`). If cards render collapsed or overlapping,
   heights need to be set explicitly per class.
2. **Local echo** — cards are created from the `onReceiveMessage` engine event.
   If locally-sent speech doesn't produce a card, additionally hook
   `ChatManager.registerDeliverMessageCallback` with a dedup fingerprint.
3. **Portraits** — uses the auto-registered `portrait_<identity>_chat` icon
   names (PCs only). NPC cards currently show an empty portrait frame; NPC
   token art needs a `tokencontrol` or asset-based approach.
4. **Modifier breakdown** — the mockup's "Base +14, Bless +1" detail isn't
   available at the hook point; the card shows the net modifier. Getting the
   breakdown means capturing it in `ActionAttack.applyEffectsToRollMod`.
5. **Weapon property chips** (Agile/Finesse) aren't in `rRoll`; they'd have to
   be looked up from the source actor's weapon/power node.
6. **Saves, checks, skills, heals** render as generic roll cards (no vs-DC
   box). Wire `ActionSave`/`ActionCheck` hooks the same way as attacks to
   upgrade them.
7. **Chat entry sliders** (speaker/language) and dice tower / secret rolls are
   untouched; secret rolls intentionally produce no card.

## Restyling

All art is placeholder. Regenerate or replace:
- `graphics/frames/cc_card.png` — parchment card body
- `cc_header.png` — gold name/title bar
- `cc_resultbox.png` / `cc_resultheader.png` — roll result box
- `cc_chip_red.png` / `cc_chip_gold.png` — keyword pills
- `cc_banner.png` — one-line banner bar
- `cc_portraitframe.png` — portrait border

Fonts are Noto Sans (copied from CoreRPG, SIL OFL). Sizes/colors live in
`graphics/graphics_chatcards.xml`.
