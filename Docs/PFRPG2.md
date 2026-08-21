# Pathfinder 2 (PFRPG2) adapter

Living document for what ChatCards supports on the PFRPG2 ruleset and how
the adapter is wired. Adapter script: `scripts/chatcards_pf2.lua`
(`ChatCardsPF2`), gated on `ChatCardsManager.isRuleset("PFRPG2")` — SFRPG2
(Starfinder 2E) layers on the same codebase and passes the gate too, but is
untested. Written against the PFRPG2 ruleset build shipped 2026-08.

## What gets a card

| In game | Card | Notes |
| --- | --- | --- |
| Attack roll / combat maneuver | Attack card | Title "Melee/Ranged Attack" or "Combat Maneuver", weapon on the modifier line, target line, four-degree outcome (Critical Hit!/Hit/Miss/Critical Miss). No "vs AC" figure: the defense value is host-side knowledge the resolve never re-exposes |
| Miss-chance flat check (concealed/hidden) | Roll card | "Miss Chance", DC line, Hit/Miss/Critical Hit! parsed from the original's message |
| Damage / healing roll | Damage / heal card | Weapon or spell label, type pills from the clauses (Piercing, Fire, Spell, ...), Critical! pill on crit damage; result drags onto a token to apply (`sRollClauses` re-encodes the clauses for the drop's mod phase) |
| Applied damage / healing | System banner | "Grig takes 12 damage (resisted)" — from the host's `messageDamage` wrap, replacing PFRPG2's unbracketed "Damage [12] -> [to Grig]" texts (skip patterns drop those). Notifications ([RESISTED], [SHIELD BROKEN], ...) become the parenthesis |
| Saving throw | Roll card + outcome | Roll card from the target's client ("Fortitude Save", "vs: Fireball" line, DC hidden as in the ruleset); the final degree (hidden DCs, SAVERESULT steps, evasion) resolves host-side in `applySave`, which broadcasts "Elara saves [23] vs Fireball: Success" on a system card |
| Skill / ability check | Roll card | "Skill Check" / "Ability Check", proficiency-rank pill ([Trained] ... from the desc), Assurance/Assist pills, outcome parsed from the delivered message so SKILLRESULT step effects are honoured. Skill DCs stay hidden (the ruleset hides them too); ability checks show theirs |
| Activity check (Trip, Demoralize, vsdc actions) | Action card from the host | The unbracketed roll message is swallowed at the source; the host's `applyVsDC` — the only place that knows the DC — sends the card with kept die, total, target, skill pill, traits and the four-degree outcome |
| Persistent-damage flat check | Roll card | "Flat Check", DC line, effect label on the modifier line, outcome; the effect-removal notice passes through untouched. Friendly-faction checks show to the table, like the original |
| Recovery check (dying) | Roll card | "Recovery Check", DC 10+dying, outcome, and the actual change ("Dying 2 » 1 (stable, wounded +1)") read before/after the original applies it |
| Spell cast | Power card | The full cast's "[CAST]" message is skipped; the card carries name, foldable description, and rollable Attack/Save/Damage/Heal/Effect rows (see below). NPC-hidden casters stay GM-only |
| Untargeted save-vs roll | System card | "Fireball: Fortitude save DC 20" — replaces the "[SAVE VS]" message the SAVE tag skips |
| Effect applied / expired | Effect card | Unnamed effects are named after their owning spell (`[from ...]` via the `SpellManager.getSpellAction` stamp) |
| Everything else | Core cards | Generic rolls (init, concentration, tray dice), table rolls, speech, story, system notices — manager + `ChatCardsCore` |

## Power cards and action rows

**PFRPG2 never touches `PowerManagerCore` / `PowerActionManagerCore`** —
every sheet action button funnels through
`SpellManager.onSpellAction(draginfo, nodeAction, sSubRoll)`, and a full
cast inserts a diceless `"cast"` roll. So:

- The announce moment is the `"cast"` result handler (re-registered): the
  original prints its "[CAST] ..." message (skipped via the CAST roll tag)
  and the power card replaces it. The action node rides the roll
  (`rRoll.sActionNodeName`); its owning spell is the grandparent. A cast
  against several targets resolves once per target — only `nOrder == 1`
  sends the card. Unresolvable node (chat-dragged cast) falls back to a
  name-only power card.
- The rows drive `SpellManager.onSpellAction` through the core's
  **row-handler seam** (`ChatCardsCore.setPowerRowHandlers` — added for
  this adapter; the defaults still go through PowerActionManagerCore for
  5E/Daggerheart). Icons map to PFRPG2's own action-button art, texts come
  from the same `SpellManager.getAction*Text` views the sheet shows.
- Row split (`setPowerRowBuilder`): a cast action contributes Attack
  (`atk`) and Save (`save`) sub-roll rows — the same sub-rolls the sheet's
  buttons pass — and rows whose half the spell lacks are dropped (empty
  detail text). Other action types keep the default one row per action.
- Row results: attack entries report per target from the resolve (total +
  Crit/Fumble, tinted); damage/heal report the shared total (`set`);
  effect rows get the core's success mark. Save rows report per target
  from the host's `applySave` — the marker crosses clients riding the
  save-vs desc (`ChatCardsManager.registerMarkDescRollTypes` — a manager
  seam added for this adapter, since PFRPG2's save-vs travels through
  `ActionSpell`'s OOB as `castsave`/`spellsave`, not 5E's `powersave`).
- The power name links to the `spelldesc` record class.

## Four degrees of success

`GameSystem.getd20CheckResult(die, total, DC)`: ±10 steps the result a
degree, nat 20/1 steps it up/down. Where each roll type learns its degree:

| Roll | Degree decided | Card strategy |
| --- | --- | --- |
| attack / grapple / critconfirm | rolling client (`onAttack`, `rRoll.sResult` crit/hit/miss/fumble) | outcome on the attack card |
| skill / ability | rolling client, appended to the message (incl. SKILLRESULT steps) | parsed from the captured message |
| save | HOST (`applySave`: hidden DC, SAVERESULT, evasion) | outcome card from the `applySave` wrap |
| vsdc | HOST (`applyVsDC`) | whole card from the `applyVsDC` wrap |
| flatcheck / recovery | rolling client | recomputed with the same inputs |

## Hook points

| Seam | What it captures |
| --- | --- |
| `ActionAttack.onAttackResolve` (wrap) | `sResult`, `sAbilityTitle`, `traits`, `nCrit`; called package-qualified with `(rSource, rTarget, rRoll, rMessage, rRoll, nMissChance)` |
| Result handlers `damage`/`heal` (re-registered around `ActionDamage.onDamage` / `ActionHeal.onHeal`) | Card before resolution so the roll precedes its apply banner; clauses are a real table by then (CoreRPG `setupModRoll` decoded them) |
| Result handler `save` (re-registered) | Roll card BEFORE `ActionSave.onSave` (which chains to the host's applySave — outcome must land second); own `decodeR2K` first so the kept die shows |
| `ActionSave.applySave` (wrap, host) | Final `rAction.sSaveResult`; native "... Save [23] ->" messages dropped from the capture (activity result texts pass); save-row result reporting via the desc-riding marker |
| Result handlers `skill`/`ability` (re-registered) | Message capture (pass-through) to parse the final degree |
| Result handler `vsdc` (re-registered) + `ActionVsDC.applyVsDC` (wrap, host) | Roll message (unbracketed) swallowed at source; host wrap drops its own output (matched by desc head) and sends the card |
| Result handlers `flatcheck`/`recovery`/`misschance` (re-registered) | Flat-check line swallowed (dice-bearing only — the effect-ends notice passes); recovery reads `hp.dying` before/after |
| Result handlers `cast`/`castsave`/`spellsave` (re-registered) | Power card on full cast; untargeted save-vs announcement card |
| `SpellManager.getSpellAction` (wrap) | Effect-origin stamp (`rAction.sChatCardsPower`) from the action node's grandparent; also covers `EffectManagerPFRPG2`'s call sites |
| `ActionDamage.messageDamage` (wrap, host) | Apply banners; `bNotApplied` (shared/linked-PC copies) and untargeted results skipped |

Function-replacement note: reassigning `ActionSave.applySave` (etc.) also
redirects the ruleset's own *unqualified* internal calls — a script's
environment table IS its exposed package, so lookups resolve through it at
call time.

## Message vocabulary registered

- **Roll tags**: `CAST`, `ABILITY`, `CM`, `RECOVERY`, `FLAT` (the
  classifier reads the first uppercase word, so "[FLAT CHECK]" and
  "[SAVE VS]" match FLAT and the default SAVE) — on top of the manager's
  d20-family defaults.
- **Skip patterns**: `^Attack[%s%(%[]` (applyAttack's unbracketed "Attack
  (M) (Rapier) [22] -> ..." — the attack card already shows the outcome),
  and the damage-apply family (`^Damage`, `^Heal`, `^Temporary hit
  points`, `^Fast healing`, `^Regeneration`, `^Shared `) replaced by the
  messageDamage banners.
- **Message capture** (`runWithMessageCapture`): where PFRPG2 prints
  output with no bracketed tag at all, the Comm delivery calls are
  intercepted for the duration of the original handler — the same
  technique as the core's table-roll capture.

## Tags (pills)

| Provider | Pills |
| --- | --- |
| `attack` | Attack (red), Critical!, Fortune/Misfortune, Spell, Keen, MAP #2/#3 (red), weapon traits (Agile, Finesse, ...) |
| `damage` | Damage (red), Critical!, clause types incl. the implicit "spell" type |
| `heal` | Healing / Temporary HP / Shield Repair (green) from `rRoll.healtype` |
| `vsdc` | Skill rolled (Athletics, ...), action traits |
| `roll` (saves/checks/generic) | Fortune/Misfortune (kept-die `g`/`r` prefix from `decodeR2K`), proficiency rank, Assurance, Assist, Basic (save), save traits from the save-vs desc (minus the duplicate "basic") |

## Ruleset facts worth remembering (from the pak)

- `rRoll.sResult` on attacks is crit/hit/miss/fumble; saves/checks carry
  the long-form strings ("CRITICAL SUCCESS", ...) in messages and
  `sSaveResult`.
- Fortune/misfortune = roll-twice effects (`ATKR2KH`/`SAVER2KL`/...);
  `encodeR2K` adds the second d20, `decodeR2K` keeps one, marks it
  `g`/`r` and REMOVES the other die (unlike 5E, which keeps it flagged
  dropped).
- Save-vs travels: castsave/spellsave roll (DC in `nMod`, desc "[FORT DC
  20] [TRAITS ...]") → `notifyApplySave` OOB (desc only) → target's
  `performVsRoll` (`rRoll.sSaveDesc`) → target's save roll → host
  `applySave`. PC rolls against hidden DCs ride PCROLL effects instead
  and resolve purely host-side.
- Damage clauses ride the throw as `sClauseData` and are decoded by
  CoreRPG's `setupModRoll` (which also rebuilds `tEffectFilter` and
  `tNotifications`), so a card result dragged onto a token replays
  through the normal path — same mechanism as Daggerheart.
- Assurance (`SKILL_ASSURANCE` modifier key) replaces the die with a flat
  10 inside the result handler; the card encodes dice after the original,
  so it shows the 10.
- Hero-point awards arrive as plain messages with the `heropoints` icon
  and fall through to notice cards unchanged.

## Known gaps

- SFRPG2 passes the gate but is untested (scene attacks, Suppressed).
- The attack card shows no "vs AC" figure (host-side knowledge).
- Skill-check cards omit the DC even for the GM (the ruleset hides it in
  chat for both sides).
- Recovery cards only appear for PCs with dying ≥ 1, like the button.
- Shield-repair apply messages (`notifyApplyShieldRepair`) keep their raw
  text.
- PFRPG2-Legacy is not covered (different architecture).
