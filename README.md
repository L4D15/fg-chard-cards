# ChatCards (v0.1 scaffold)

Card-style chat message display for Fantasy Grounds Unity. Declares no
`<ruleset>` gate — the launcher only matches ruleset tags against the
campaign's own ruleset name, so "CoreRPG" would never match a 5E campaign;
universal extensions omit the gate instead. The manager and the CoreRPG-level
hooks (`ChatCardsCore`) are system-agnostic, and a per-system adapter script
adds the structured capture (5E included; on CoreRPG-based systems without an
adapter, rolls still get generic roll cards).
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
  `registerRollTags` / `registerRedundantApplies` / `registerApplyBanners`,
  which extend the message-classification vocabulary (the defaults carry only
  the labels shared across the d20 family; a system's own terms come from its
  adapter).
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
  adapter's job. Also holds `setPowerRecordClass`: the windowclass a power
  card's title link opens, since the power record class is a system's, not
  CoreRPG's.
- **`scripts/chatcards_5e.lua`** (`ChatCards5E`) — the 5E adapter, and the
  template for adapters to other systems. Gates itself on
  `ChatCardsManager.isRuleset("5E")` — the action-manager globals it hooks
  are same-named but incompatible on other systems (PFRPG2 and SavageWorlds
  both define their own `ActionAttack`). Registers its dedicated roll types
  (attack/damage/heal/save/check/skill), the 5E message vocabulary, the
  power record class, and its tag providers. Wraps
  `ActionAttack.onAttackResolve` / `ActionSave.onSaveResolve` and
  re-registers the `check`/`skill`/`damage`/`heal` result handlers to capture
  structured data (`rRoll.nTotal`, `nDefenseVal`, `sResult`, target,
  modifiers) *before* it is flattened into chat text, then broadcasts a card
  OOB. The flattened `[ATTACK ...]` / `[DAMAGE ...]` text messages are
  suppressed on the card side to avoid duplicates (they still reach the
  hidden real chat log). Also stamps effect actions with their originating
  power's name (wrapping `PowerManager.performAction`, which is also where a
  full cast announces itself as a power card — its `[CAST]` text was already
  skipped as a roll tag). Power cards (`chatcard_power`: the roll cards' header — portrait, actor
  name, player name — with the power's name in the title slot, its
  description folded behind a "Show description" toggle at the bottom,
  and the power's actions between them as a vertical row list — button,
  description, results inline after it — driven through the same
  `PowerActionManagerCore` handlers as the sheet's Actions tab (a compound
  `cast` action splits into Attack and Save rows the way the sheet's full
  view does), shown only where the power node resolves and is owned, i.e.
  the caster and the GM;
  the power name is also a link that opens the record wherever the node
  resolves, with a hand cursor and a colour shift on hover — the same link
  treatment character names get on every card, see below) are sent from two
  paths: full casts here, and the sheet's "use" button in `ChatCardsCore`
  (the `performDefaultPowerUse` wrap).
- **Action-row results** — rolls made from a power card's rows report back
  into that card, on every client. Power cards carry a `sCardId` minted by
  the sender; each client files its copy in `ChatCardsManager`'s id
  registry (released from the card's `onClose`). A row click wraps the
  perform in `performMarkedAction`, which stamps card id + row key +
  volley id onto every roll the press creates (via wraps of
  `ActionsManager.performMultiAction` — the path `PowerManager.performAction`
  funnels all power rolls through — and `ActionsManager.performAction`;
  custom `rRoll` string fields survive the throw). A *volley* is one press: per-target entries of the same
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
  `ChatCardsManager` owns the machinery (weak-keyed per-control state, hand
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

## Known gaps (confirmed in-app through v0.1 playtesting)

1. **Modifier breakdown** — the mockup's "Base +14, Bless +1" detail isn't
   available at the hook point; the card shows the net modifier. Getting the
   breakdown means capturing it in `ActionAttack.applyEffectsToRollMod`.
2. **Weapon property chips** (Agile/Finesse) aren't in `rRoll`; they'd have to
   be looked up from the source actor's weapon/power node.
3. **Saves, checks, skills, heals** render as generic roll cards (no vs-DC
   box). Wire `ActionSave`/`ActionCheck` hooks the same way as attacks to
   upgrade them.
4. **Chat entry sliders** (speaker/language) and dice tower / secret rolls are
   untouched; secret rolls intentionally produce no card (though apply-result
   banners, e.g. "takes N damage", do show to whoever FG delivers them to).

Resolved during playtesting: card heights (windows size to their `sizer`
control), local echo (receive fires for own messages), duplicate attack
text (mixed-case apply messages), basic dice throws (resolveAction hook),
card background frames (windowclass-level `<frame>`), portraits
(portrait -> token/picture -> GM badge -> "?").

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
