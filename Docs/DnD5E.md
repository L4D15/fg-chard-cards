# 5E (D&D 5th Edition) adapter

Living document for what ChatCards supports on the 5E ruleset and how the
adapter is wired. Adapter script: `scripts/chatcards_5e.lua`
(`ChatCards5E`), gated on `ChatCardsManager.isRuleset("5E")`.

## What gets a card

| In game | Card | Notes |
| --- | --- | --- |
| Attack roll | Attack card | Title "Melee/Ranged Attack", target + AC line, formula "1d20+7 vs 15", itemized modifiers, outcome (Success/Failure/Critical!/Fumble) |
| Damage / healing roll | Damage / heal card | Weapon or spell label, damage-type pill, shared total; result drags onto a token to apply, like native chat |
| Saving throw | Roll card | "Saving Throw", DC line, itemized modifiers (SAVE effects), Success/Failure vs DC |
| Ability / skill check | Roll card | "Ability Check" / "Skill Check", canonical skill spelling, CHECK+SKILL effect breakdown |
| Spell cast / power use | Power card | Header like a roll card, power name links to the record, foldable description, rollable action rows (see below) |
| Effect applied / expired | Effect card | Sentence with bold linked names; unnamed effects ("AC: 3") are named after their originating power ("[from Mage Armor]") |
| Everything else | Core cards | Generic rolls, table rolls, speech, story, system notices — handled by the manager and `ChatCardsCore`, not this adapter |

## Hook points

| Seam | What it captures |
| --- | --- |
| `ActionAttack.onAttackResolve` (wrap) | `rRoll.nTotal`, `nDefenseVal`, `sResult` (hit/miss/crit/fumble), target — before flattening into chat text |
| `ActionSave.onSaveResolve` (wrap) | DC (`rRoll.nTarget`), ability, AUTOFAIL |
| Result handlers `check` / `skill` (re-registered around `ActionCheck.onRoll`) | Ability/skill names for the breakdown queries |
| Result handlers `damage` / `heal` (re-registered around `ActionDamageD20.onRoll`) | Card goes out BEFORE resolution so the roll precedes its "takes N damage" banner; healing shares the damage handler in the ruleset |
| `PowerManager.performAction` (wrap) | Full casts (subtype "") announce as a power card; effect actions get the power's name stamped (`rAction.sChatCardsPower`) for the notice's `[from ...]` line |
| Core seams (not in this file) | The sheet's "use" button cards through `ChatCardsCore`'s `performDefaultPowerUse` wrap; effect-origin encode/decode and table capture live in the core too |

## Power cards and action rows

The 5E-specific richness sits on the power card:

- Rows are built from the power's actions through the same
  `PowerActionManagerCore` handlers as the sheet's Actions tab. A compound
  `cast` action splits into Attack and Save rows (the sheet's full view
  does the same); damage, heal and effect actions get one row each. Rows
  appear only where the power node resolves *and* is owned — the caster's
  client and the GM.
- Rolls made from a row report back into the card on every client (the
  volley system — see COLLABORATING.md "Action-row results"). The resolve
  hooks in this adapter broadcast the entries: attack = total +
  Crit/Fumble tinted by hit/miss, save = each target's total (green =
  saved) — the cross-client case, riding the powersave desc — damage/heal
  = the shared total (mode `set`), effect = a bare success mark.
- Secret cards (NPC power use) keep their reach: rows report GM-only.
- The power name links to 5E's `power` windowclass
  (`ChatCardsCore.setPowerRecordClass("power")` — defined by 5E's
  `record_power.xml`, not CoreRPG).

## Tags (pills)

| Provider | Pills |
| --- | --- |
| `attack` | Attack (red), Critical!, Advantage/Disadvantage, weapon properties (Finesse, Light, ... — looked up on the actor's weapon entry by the roll's label) |
| `damage` | Damage (red), damage type from the desc's `[TYPE: ...]`, weapon properties |
| `heal` | Healing or Temporary HP (green), from `rRoll.healtype` |
| `roll` (saves/checks/generic) | Advantage/Disadvantage — from the roll flags, falling back to the kept die's `g`/`r` prefix |

## Itemized modifier breakdowns

Attack, save and check cards itemize their modifiers ("Rapier +5 · Bless
+1d4"): each active effect with matching components becomes its own
segment via `EffectQueryManager.getEffectsDataByTag` (ATK/@ATK for
attacks, SAVE/CHECK/SKILL for the rest), and the roll's own bonus is
whatever remains of `rRoll.nMod` after the listed flat modifiers are
subtracted. The ruleset's effect filters are tables and don't survive the
dice throw, so they are rebuilt from the string fields that do (`sSave`,
`sAbility`, `sSkill`).

## Message vocabulary registered

- **Roll tags** (text messages skipped because a card carries the roll):
  `DEATH`, `CAST`, `CONCENTRATION`, `RECHARGE`, `RECOVERY`, `POWERSAVE` —
  on top of the manager's d20-family defaults (ATTACK, DAMAGE, HEAL, SAVE,
  CHECK, SKILL, INIT, TABLE).
- **Redundant applies** (result already on a card): `Concentration`,
  `System Shock` — plus defaults Attack, Save.
- **Apply banners**: Temporary hit points ("gains N temporary hit
  points"), Fast healing / Regeneration / Recovery ("recovers N hit
  points") — plus defaults Damage, Heal.

## Known gaps

- Chat entry sliders (speaker/language) and the dice tower are untouched;
  secret rolls intentionally produce no card for players.
- Cards reveal true names of unidentified NPCs (see the note in
  `ChatCardsManager.getActorName`).
