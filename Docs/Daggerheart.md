# Daggerheart adapter

Living document for what ChatCards supports on the Daggerheart ruleset and
how the adapter is wired. Adapter script: `scripts/chatcards_dh.lua`
(`ChatCardsDH`), gated on `ChatCardsManager.isRuleset("Daggerheart")`.
Written against the Daggerheart ruleset build 2026-08-09.

## What gets a card

| In game | Card | Notes |
| --- | --- | --- |
| Trait / action roll (untargeted duality) | Attack-type card | Title "Action Roll", trait on the modifier line, DC line when the roll had one, outcome Success/Failure/Critical! |
| Attack against a target | Attack-type card | Title "Attack", target line, formula "d12+d12+2 vs 14" against the defense value |
| Reaction roll | Roll card | Title "Reaction Roll", DC line, outcome Success/Failure/Partial (half save)/Critical! |
| Experience spent (next-roll modifier) | Effect-style card | "**Bodyguard** experience will apply **+1** to next roll of **Romualda**" — name bold, bonus coloured like other bonuses, actor linked; a DC-gated mod that missed reads "failed to apply" |
| Damage roll | Damage card | Weapon/action label, type pills including resources (Stress, Armor, Hope, Fear), result drags onto a token to apply |
| Healing / clearing | Heal card | Same shape; the resource pill says what is restored |
| Effect applied / expired | Effect card | Unnamed effects are named after their owning power (`[from ...]` via the `ActionPower.performAction` stamp) |
| "Send to chat" sheet button | Power card | A speech-bubble button merged into the sheet's power rows (domain-card features, class/subclass/ancestry/community features): name, description, rollable action rows reporting results back onto the card, title linking to the record (card/feature/subfeature per node kind) |
| Everything else | Core cards | Generic rolls, table rolls, speech, story, system notices — manager + `ChatCardsCore` |

**Power cards have no native trigger on this system** — nothing in
Daggerheart calls `PowerManagerCore.usePower` (abilities roll straight
from their action buttons), so there is no announcement moment to hook.
Instead the extension merges its own "send to chat" button into the
sheet's power rows (`power_item_dh` / `power_subitem_dh`, see
`common/sheet_chatcards_dh.xml` — anchored to the item window's centre,
the one reference that lines up across nesting levels and ignores the
right-chain buttons' visibility), which sends the card via
`ChatCardsDH.sendSheetPowerCard`. Row splitting reads
the action node's own fields (`subroll` on attacks — "", save, mod —
and `resource` on damage/heal), mirroring the sheet's
`power_action_mini.getActionData`, through
`ChatCardsCore.setPowerRowBuilder`.

The same file carries two more sheet adjustments: the features sublist's
right indent is zeroed so sub-row gears align with the item rows' (the
centre-anchored controls are compensated), and every other list row gets
a translucent black stripe (`cc_rowshade`, 10% opacity — restriped from
`ChatCardsDH.updateListStripes` on layout, walking the row tree
depth-first so the shade alternates over the rows as the eye reads
them, nested feature rows continuing their card's count).

## Duality rendering

The system's signature mechanic gets the card treatment:

- **Die glyphs**: the hope and fear dice are tinted gold (`FFF9B70D`) and
  indigo (`FF251566`) — the ruleset's own 3D-die body colours. Mechanism:
  `encodeDualityDice` finds the pair via `DiceManager2.collectHopeFear`
  and prefixes their types (`hd12` / `fd12`) in the card's encoded dice
  string; the action card tints any prefix registered through
  `ChatCardsCore.registerDieStyles`. Only PC duality rolls have the pair.
- **Pills**: Hope (green) / Fear (red) for which die won
  (`rRoll.sDuality`), plus Critical! on doubles (`rRoll.bCritical`), plus
  Advantage/Disadvantage from the roll flags. The outcome slot keeps the
  short Success/Failure word so it fits the result box.
- Crit detection is the ruleset's (`sResult`/`bCritical` are read, never
  recomputed): doubles for PCs, the `atkcrit` threshold on a d20 for NPCs.

## Hook points

| Seam | What it captures |
| --- | --- |
| `ActionAttack.onAttackResolve` (wrap) | Both duality roll shapes ride the `attack` type: targeted = vs `nDefenseVal` (`sResult` hit/miss/crit), untargeted = vs DC `nTarget` (`sResult` success/failure/crit). `sDuality`, `bCritical`, `sLabel` are set by then |
| Result handler `save` (re-registered around `ActionSave.onSave`) | Reactions resolve AND apply inside `onSave` (`applySave` sets `sResult`, including `half_success`), so the card is sent after it returns |
| Result handlers `damage` / `heal` (re-registered around `ActionDamageD20.onRoll`) | Same CoreRPG seam as 5E — Daggerheart wires damage and heal through `registerStandardDamageHealHandlers`. Card before resolution, so the roll precedes its apply banner |
| `ActionPower.performAction` (wrap) | Effect-origin stamp. The wrap receives the *action node*; its owning power is the grandparent (power → actions list → action) |
| `ActionMod.onModResolve` (wrap) | Next-roll modifiers. `ActionMod.onRoll` runs outside `ActionsManager.resolveAction` (no generic card fires); this seam runs right after `checkModResult` decided whether `rRoll.nTotal` reached the modifier stack (`sResult` "fail" = DC-gated miss). The stack change is local to the rolling client; the card broadcasts like the message it replaces |

## Message vocabulary registered

- **Roll tags**: `ACTION`, `REACTION`, `MOD` — Daggerheart overrides
  CoreRPG's tag strings (`action_attack_tag` = ACTION, `action_save_tag`
  = REACTION), so its roll texts don't match the d20-family defaults;
  `MOD` drops the "[MOD] Bodyguard [ADDED TO MODIFIER STACK]" message the
  experience card replaces.
- **Skip pattern**: `^Reaction%s` — reaction *results* are plain
  "Reaction [12][vs. DC 14] -> [for X]" lines with no bracketed tag, so
  they can't ride the roll-tag vocabulary. Skip patterns are never
  applied to speech-mode messages.
- **Apply banners**: Regeneration ("recovers N hit points") — plus
  defaults Damage, Heal.

## Ruleset facts worth remembering (from the pak)

- Trait rolls are built with `rAction.type = "attack"` (`char_main.lua`,
  experience entries too) — there is no separate check action type.
- `rRoll.sDuality` is decided in `DiceManager2.decodeDice` during
  `setupDHRollResolve`, comparing the hope and fear die values; equal
  values set `bCritical` instead.
- Damage/heal clause data (`rRoll.clauses`, carrying `dmgtype`) rides the
  throw as `rRoll.sClauseData` (`UtilityManager.encodeTableToString`) and
  is consumed at mod time. The cards re-encode it (`sRollClauses`) so
  drag-to-apply can restore it — the drop's mod phase decodes it exactly
  as for a fresh roll.
- `DataCommon.rolls_resources` = hp, stress, armor, hope, fear; damage
  and heal clauses can name resources as their type, which is where the
  resource pills come from.
- Domain **card** records carry no rules text of their own — the text and
  the actions live on their `.features` children (each opening the
  "subfeature" class from the sheet). The sheet row's name link opens
  "card" for `cardlist` entries and "feature" otherwise, which is where
  the power card's title-link class comes from.
- Damage converts to HP marks via thresholds
  (`ActionDamage.collectConvertedDamage`: minor 1 / major 2 / severe 3,
  massive 4 with the homebrew option) — the card shows the rolled total,
  the apply banner what landed.
- Rerolls (`reroll*` types, `RerollManager.onReRoll`) strip the prefix
  and re-enter the real resolution *mutating `rRoll.sType` in place*, so
  by the time the core's dedicated-type check runs, the type is the real
  one — rerolled attacks card correctly with no special handling.
  Rerolled damage/heal go through `ActionDamage.onDamage` /
  `ActionHealD20.onHeal` directly (not the result handlers), so they do
  NOT produce a fresh card.

## Known gaps

- **Hope/Fear resource changes are invisible on cards.** "[GAINS 1
  HOPE]" / "[GM GAINS 1 FEAR]" ride the roll message (suppressed by the
  ACTION tag) or the attack apply message (suppressed as a redundant
  apply), so the adjustment happens mechanically but no card says so —
  the Hope/Fear pill only implies it. Candidate fix: read
  `rRoll.aMessages` in `onAttackResolve` and surface them on the card.
- Untargeted Fear spend/gain messages (`applyFearAndMessage`: "[FEAR]
  Spends 2") fall through to a plain system card, not a phrased banner.
- Countdowns and dice trackers get no dedicated cards.
- A power card sent for a domain **card** row (the card node itself, not
  one of its features) shows name only: the card record carries no text or
  actions of its own — send the feature rows for the full experience.
  Aggregating a card's features onto one power card is a candidate
  improvement.
- Rerolled damage/heal update the applied result but not the card (see
  above).
- Colossus segment subtargets (`sSubtargetPath` thresholds) untested.
