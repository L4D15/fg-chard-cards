# Collaborating on ChatCards

Implementation reference for working on the extension: architecture, code
conventions, how to add a ruleset adapter, and restyling. The user-facing
summary lives in [README.md](README.md); design documentation — reference
mockup, architecture diagram, decision log — in
[`Design/`](Design/README.md); and each supported ruleset has a living
document of what's carded and how its adapter is wired in
[`Docs/`](Docs/) ([DnD5E](Docs/DnD5E.md), [Daggerheart](Docs/Daggerheart.md)).
When an adapter changes, its doc changes with it.

## Workflow

Work happens on `feature/<name>` branches merged into `develop` (merge
commits, commit messages prefixed with the branch name).

## Architecture

- **`desktop/desktop_chatcards.xml`** — overrides CoreRPG's `chat` windowclass.
  The compiled `chatwindow` control is shrunk to 1x1 and made invisible (the
  chat entry box requires it to exist, and feeding it preserves the chat log).
  A `windowlist` named `cards` takes over the display area and accepts
  dice/number/string drops like the original chat window did.
- **`extension.xml`** — declares **no** `<ruleset>` gate: the launcher only
  matches ruleset tags against the campaign's own ruleset name ("CoreRPG"
  would never match a 5E campaign), so universal extensions omit the gate
  (the Universal Module / Shops pattern). Gating happens in code instead:
  the core hooks guard their CoreRPG seams, and system adapters self-gate on
  the ruleset name.
- **`scripts/manager_chatcards.lua`** (`ChatCardsManager`) — global manager.
  Listens to `ChatManager.registerReceiveMessageCallback`, which the engine
  fires for *every* message — delivered or locally injected via
  `Comm.addChatMessage` (`SystemMessage`, GM turn/effect copies), secret or
  not (verified in-app on FGU v5.1.13) — and classifies each one: dice →
  generic roll card, speech modes → speech card, apply results → banner,
  recognized turn/round/effect notices → banner (rewritten as a sentence, see
  `formatSystemNotice`), everything else → frameless notice. Received messages
  carry their icon in `msg.assets` (`msg.icon` doesn't survive the trip),
  which is where notice icons come from. Also defines the `chatcards_card`
  OOB message that carries structured card data to every client, and the
  adapter registration surface: `isRuleset`, `registerTagProvider`, and
  `registerRollTags` / `registerRedundantApplies` / `registerApplyBanners` /
  `registerSkipPatterns`, which extend the message-classification vocabulary
  (the defaults carry only the labels shared across the d20 family; a
  system's own terms come from its adapter — skip patterns cover system
  output with no bracketed tag to classify by, and are never applied to
  speech). Also rebuilds `/help`: the engine's reply is drawn straight into
  the hidden native control (never through Comm's receive event), so
  `/help` (plus `/commands`, in case the engine consumes `/help` first)
  answers with a system card built from three sources — an onInit-time wrap
  of `Comm.registerSlashHandler` (catches this extension and extensions
  loading after it; it cannot catch the ruleset or earlier extensions,
  whose registrations precede our onInit), plus curated static lists of
  CoreRPG's and the engine's own commands. `registerSlashHelp` adds
  anything the lists miss.
- **`scripts/chatcards_core.lua`** (`ChatCardsCore`) — CoreRPG-level hooks,
  active on every ruleset. Wraps `ActionsManager.resolveAction`: any
  dice-carrying roll whose type no adapter claimed (via
  `registerDedicatedRollTypes`) becomes a generic roll card, and diceless
  `effect` rolls report into the power card's Effect row. Captures table
  rolls (re-registers the `table` result handler and intercepts the Comm
  calls for the duration of `TableManager.onTableRoll`, so the drawn rows
  land inside the roll card instead of as follow-up chat lines). Cards power
  use by wrapping `PowerManagerCore.performDefaultPowerUse` — only the
  default output (the power name as a text message, which carries no tag
  receivers could suppress it by) is replaced by the card, so a ruleset with
  its own registered `fnUsePower` handler keeps its mechanics. Owns the
  effect-origin plumbing (CoreRPG's `onEffectRollEncode`/`Decode` hooks, the
  `onEffectAddNotify` override that adds the `[from Mage Armor]` line for
  unnamed effects) — the stamp itself (`rAction.sChatCardsPower`) is the
  adapter's job. Also holds `setPowerRecordClass` (the windowclass a power
  card's title link opens, since the power record class is a system's, not
  CoreRPG's), `setPowerRowBuilder` (how one action node splits into a power
  card's rows — 5E's cast split, Daggerheart's subroll/resource fields) and
  `registerDieStyles` (die glyph accents keyed by a one-letter type prefix
  in a card's encoded dice — Daggerheart's hope/fear dice).
- **`scripts/chatcards_5e.lua`** (`ChatCards5E`) — the 5E adapter, and the
  template for adapters to other systems. Gates itself on
  `ChatCardsManager.isRuleset("5E")` — the action-manager globals it hooks
  are same-named but incompatible on other systems (PFRPG2 and SavageWorlds
  both define their own `ActionAttack`). What it cards, through which
  seams, and its registered vocabulary live in the per-ruleset doc:
  [Docs/DnD5E.md](Docs/DnD5E.md).
- **`scripts/chatcards_dh.lua`** (`ChatCardsDH`) — the Daggerheart adapter:
  duality action/attack cards (hope/fear die tints and pills), reaction,
  damage and heal cards, effect origins; no power cards (the system has no
  power-use flow). Details, hook points and ruleset facts:
  [Docs/Daggerheart.md](Docs/Daggerheart.md).
- **Action-row results** — rolls made from a power card's rows report back
  into that card, on every client. Power cards carry a `sCardId` minted by
  the sender; each client files its copy in `ChatCardsManager`'s id
  registry (released from the card's `onClose`). A row click wraps the
  perform in `performMarkedAction`, which stamps card id + row key +
  volley id onto every roll the press creates (via wraps of
  `ActionsManager.performMultiAction` — the path `PowerManager.performAction`
  funnels all power rolls through — and `ActionsManager.performAction`;
  custom `rRoll` string fields survive the throw). A *volley* is one press:
  per-target entries of the same
  volley aggregate on the row, and the next press replaces them. Results sit
  inline after the row's description behind a middot ("Attack Mace +5 · 22"),
  bold, middot-separated between entries; outcome-carrying entries are tinted
  and marked with `cc_icon_success`/`cc_icon_failure`. The 5E resolve hooks
  read the marker back and broadcast a `chatcards_result` OOB (attack: total
  + Crit/Fumble, tinted + marked by hit/miss; save: each target's total,
  green check = saved; damage/heal: the shared plain total, mode `set` so
  per-target resolves don't repeat it; effect: a textless entry — just the
  success mark — reported from the diceless effect roll's resolution). Row
  buttons also drag like the sheet's: the marked rolls are encoded into the
  draginfo at drag start and resolve wherever the drop lands (a token to
  attack/damage/save that target, the chat for a plain roll) — a cancelled
  drag never reports. Save-vs is the
  cross-client case: the marker rides the powersave roll's desc as a
  `[CCMARK ...]` tag, which `ActionPower`'s save-vs OOB carries into each
  target's save roll (`rRoll.sSaveDesc`), so whichever client rolls the
  save reports it. Secret cards (NPC power use) keep their reach: their
  row results are delivered GM-only.
- **`common/windowclass_chatcards.xml`** — the card windowclasses:
  `chatcard_action` (attack/damage/roll with header bar, portrait, body lines,
  keyword chips, result box), `chatcard_speech`, `chatcard_story`,
  `chatcard_system` (apply banners and turn notices), `chatcard_effect`,
  `chatcard_power` (spell casts / power uses: roll-card header, action rows,
  folded description), `chatcard_link` (a dropped record link),
  `chatcard_round` (centred) and `chatcard_notice` (frameless). A windowclass's
  frame and text alignment are static, so variants of one layout are separate
  classes rather than one class with overrides.
- **`scripts/chatcard_effect.lua`** — the effect card's sentence, with the
  source, effect and target names in bold. A text widget carries a single
  font, so mixed-weight text is drawn per word by
  `ChatCardsManager.setRichText`; those widgets don't reflow, so the card
  re-renders from the sentence control's `onFirstLayout` /
  `onLayoutSizeChanged` (the only place a resolved width is available).
  Also renders the `nextrollmod` card type (Daggerheart's experiences):
  a sentence variant with a colour-tinted bonus segment (rich-text
  segments accept an `sColor` over the font's colour).
- **Result drag & drop** — damage and heal cards drag like a rolled entry in
  native chat: the 5E hooks put the roll's raw pieces on the card OOB
  (`sRollType`, `sRollDesc`, `sRollMod`; the dice with results already travel
  as `sDice`), and the action card's result area rebuilds the roll at drag
  start and encodes it with `ActionsManager.encodeActionForDrag`. The drop
  then resolves through the stock `ActionsManager.actionDrop` path — a token
  or CT entry applies the rolled damage/healing (FGU keeps preset die
  results, so nothing rerolls). The rebuilt roll is stamped
  `sChatCardsRedrop`, which survives the drag and the drop's re-resolution,
  so the damage/heal hooks apply it without carding it a second time. The
  result area shows a hand cursor while the card is draggable. Attack and
  generic roll cards carry no roll data and don't drag.
- **Link cards** — a record link dropped onto the card list broadcasts a
  `chatcard_link` to every client (class + record path + name over the card
  OOB), like dropping it into native chat: the class link icon (a
  `linkcontrol`) and the name both open the record. A host drop makes the
  campaign record public, mirroring the native share gesture; module records
  and charsheets keep their own gating.
- **Links** — character names on action, speech, power and effect cards (and
  the power name on power cards) open the record behind them:
  `ChatCardsManager` owns the machinery (per-control state, hand
  cursor + gold hover tint, `Interface.openWindow` on click), wired through
  the `cc_rich_sentence` / `cc_name_link` templates. Rich-text segments carry
  `sLinkClass`/`sLinkPath`; header names are armed with `setActorNameLink`.
  Gating: charsheet nodes link wherever they resolve; NPC/CT nodes are
  GM-only (their stat blocks are not for players). The hover/unhover colours
  are constants that must match `cc_bodybold` / `cc_name` in
  `graphics_chatcards.xml`.
- **`graphics/`** — placeholder 9-slice frames (generated flat-color art) and
  fonts. Swap the PNGs in `graphics/frames/` and the colors in
  `graphics_chatcards.xml` to restyle everything without touching code.

## Adding a ruleset adapter

`chatcards_5e.lua` is the template. An adapter for another system is one
script (declared in `extension.xml` after `ChatCardsCore`) that, in its
`onInit`:

1. **Gates itself**: `if not ChatCardsManager.isRuleset("PFRPG2") then
   return; end`. This is load-bearing — action-manager globals share names
   across systems with incompatible signatures, so feature detection alone
   would mis-hook.
2. **Claims its roll types**: `ChatCardsCore.registerDedicatedRollTypes(...)`
   for every type it cards through a dedicated hook, so the core
   `resolveAction` wrap doesn't card them again (`"table"` is already
   claimed by the core's own capture).
3. **Registers the system's vocabulary** with the manager: extra roll tags
   whose text messages should be skipped (`registerRollTags`), apply labels
   a card already reports (`registerRedundantApplies`), and apply labels
   that become banners (`registerApplyBanners`).
4. **Sets the power record class** (`ChatCardsCore.setPowerRecordClass`) if
   the system has one, so power-card titles link to it.
5. **Hooks the system's resolve points** and broadcasts cards with
   `ChatCardsManager.sendCardOOB` / `sendRollCard`, and row results with
   `sendActionResult`. Capture structured data *before* it is flattened
   into chat text; suppress the flattened text via the vocabulary above,
   not by blocking delivery (the hidden native log should stay complete).
6. **Registers tag providers** (`registerTagProvider`) for the pills on its
   cards.
7. **Documents itself** in `Docs/<Ruleset>.md`: the card mapping, hook
   points, registered vocabulary, ruleset facts learned from the pak, and
   known gaps (the existing docs give the shape). The doc lives and dies
   with the adapter — change one, change the other.

Everything a system doesn't hook still works: generic roll cards, speech,
story, system notices, table rolls and power-use cards come from the
manager and `ChatCardsCore`.

## Code conventions

- **Engine globals do not exist at script load time.** `Comm`, `DB`,
  `Interface` and friends are injected before the `onInit` phase; indexing
  them from a script's top level is a nil error that kills the whole
  script (and everything that references its global). Top-level code may
  only build plain Lua data; every engine touch belongs in `onInit` or
  later. Init order: ruleset scripts' `onInit` first, then extensions by
  loadorder.
- **FG's Lua sandbox has no `setmetatable`** (so no weak tables): any
  per-control state registered with the manager (links, rich text) MUST be
  released from the card's `onClose` via `releaseControlState`, and cards
  with a `sCardId` must call `unregisterCard`, or closed cards leak entries.
- **Widgets have no "destroy all"**: passes that rebuild widgets name them
  consecutively (`richword1`, `actrow1`, ...) so the next pass can find and
  destroy the previous one.
- **Text widgets don't reflow**: anything laid out word-by-word re-renders
  from `onFirstLayout` / `onLayoutSizeChanged`, guarded by a rendered-width
  memo so the height change a render makes doesn't bounce back as another
  render.
- **OOB payloads are flat stringified fields** — no nesting; lists travel as
  indexed fields (`sResult1`, `sResult2`, ...) or encoded strings
  (`encodeTags` / `decodeTags`, `encodeDiceResults`).
- **Hungarian-ish prefixes** follow FG ruleset style: `s` string, `n` number,
  `b` boolean, `t` table, `r` record/actor, `node` DB node, `c` control,
  `w` window or widget, `f` saved original function, `_x` file-local.
- **Colours are duplicated on purpose** between `graphics_chatcards.xml`
  (fonts) and Lua constants (widget tints, hover restore colours); comments
  at each site name their counterpart — keep them in step.
- **Wrap, don't replace**: hooks save the original function and call it
  (`_fAttackResolve = ...`), chaining in case another extension wrapped it
  first; official registration seams (result handlers, custom callbacks)
  are preferred where CoreRPG offers them.
- **Comments record constraints and reasons** (why a hook point, what an
  engine quirk forces), not narration of the code.

## Known gaps (as of v0.1 playtesting)

1. **Chat entry sliders** (speaker/language) and the dice tower are
   untouched; secret rolls intentionally produce no card for players
   (apply-result banners, e.g. "takes N damage", still show to whoever FG
   delivers them to).
2. **Engine-drawn chat output** (written straight into the native control,
   bypassing Comm's receive event) is invisible with that control hidden.
   `/help` is rebuilt from the registration wrap, and connect/disconnect
   and load announcements are reproduced from their APIs — but slash
   usage errors and unknown-command replies still answer into the void.
   There is no read/notify API on the chat control (extensions that read
   history resort to the campaign's `chatlog.html` on disk).
2. **Theming**: the placeholder art doesn't follow the loaded theme. Planned:
   reuse CoreRPG's theme-overridden assets (`chatframe_*` frames, chat
   fonts, `d4icon`..`d20icon`, the `chat` portraitset) for the outer chrome
   so dark themes and ruleset themes style the cards automatically.

Resolved during playtesting: card heights (windows size to their `sizer`
control), local echo (receive fires for own messages), duplicate attack
text (mixed-case apply messages), basic dice throws (resolveAction hook),
card background frames (windowclass-level `<frame>`), portraits
(portrait -> token/picture -> GM badge -> "?"), itemized modifier
breakdowns, weapon-property chips, dedicated save/check/skill cards.

## Restyling

All art is placeholder. Regenerate or replace:
- `graphics/frames/cc_card.png` — parchment card body
- `cc_header.png` — gold name/title bar
- `cc_resultbox.png` / `cc_resultheader.png` — roll result box
- `cc_tag_*.png` — keyword pills (one framedef per style; see
  `Design/fit_pill_art.py` for fitting exported art)
- `cc_banner.png` — one-line banner bar
- `cc_portraitframe.png` — portrait border
- `graphics/buttons/cc_send_chat.png` (+`_down`) — the "send to chat"
  sheet button (regenerate with `Design/gen_send_button.py`)

Frame offsets are in bitmap pixels and border bands draw 1:1 — see the
comments in `graphics/graphics_chatcards.xml` for the geometry each frame
must keep. Fonts are Noto Sans (copied from CoreRPG, SIL OFL); sizes and
colors live in `graphics/graphics_chatcards.xml`.
