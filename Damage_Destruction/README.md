# Damage Destruction

A Baldur's Gate 3 Script Extender mod that reworks death, destruction and resurrection. How you die now matters: lethal damage can destroy the gear you were wearing, some deaths can't be undone with a quick Revivify, corpses become harder to raise with every long rest, and bringing someone back has a price. Alongside that, it repairs the story state of NPCs and companions you revive, so they behave as if they'd survived instead of coming back mute or broken.

Damage Destruction includes everything in [Raise The Dead](../Raise_The_Dead) (the NPC revival fixes), plus everything below.

---

## Requirements

- [BG3 Script Extender](https://github.com/Norbyte/bg3se)
- [Mod Configuration Menu (MCM)](https://www.nexusmods.com/baldursgate3/mods/9162). Needed for the settings and the in-game tabs.
- `meta.lsx` also lists **5eSpells** and **ImmersiveNudity (IN_SlavesAndPrisonersMechanics)** as dependencies.

**Don't install Raise The Dead alongside this mod.** Damage Destruction already contains its revival fixes (`RTD_Improved.lua`), and running both applies them twice.

---

## Features

### 1. Item destruction on death
When a character is killed, the damage type of the killing blow decides what happens to their equipped gear. You can configure each damage type to destroy **all** equipped items, **random** items, or **none**.

- **Defaults:** Acid, Fire, Cold, Lightning, Radiant and Necrotic destroy everything. Bludgeoning, Force, Thunder, Piercing, Slashing, Poison and Psychic destroy random items.
- **Overkill tiers:** damage beyond the victim's remaining HP destroys more items. Each damage type has its own overkill step, 10 HP by default, and stacking can be turned off.
- **Slashing:** in random mode, Slashing only ever cuts away the chest (Breast slot) item.
- **Who it affects:** set to the whole world or just your party (**Affect who?**).
- **Immunities:** Legendary and Adamantine items are immune by default. You can add your own immune items by StatName, either by typing them into MCM or through the Immune Items tab.
- **Notifications:** every destroyed item triggers an on-screen notification naming the character, the item and the cause.

### 2. Equipment failure during combat
Gear can also break while you're fighting, not only when you die. Every roll below is followed by a Dexterity saving throw (DC 10 by default) to save the item:

| Trigger | Default chance |
|---|---|
| A successful hit | 5% |
| A critical hit (rolled separately) | 50% |
| Becoming downed | 50% |
| Burning / Acid conditions | Uses the better of Dex or Con, with advantage (toggleable) |

### 3. Ash-body deaths, Disintegrate and corpse explosions
- **Ash-body deaths:** a death by Disintegrate, or shattering after being petrified, turns the body to ash. It blocks Raise Dead and, optionally, destroys everything the character wore.
- **Disintegrate saves:** surviving a Disintegrate save still destroys one random non-immune item (toggleable).
- **Corpse explosions (chunking):** optional, for Bludgeoning, Force and Thunder. A lethal hit above a threshold (30 by default) makes the corpse explode, and an exploded corpse can't be raised normally.

### 4. Death that sticks
- **Recent death window:** every creature that dies gets about 10 combat rounds (roughly a minute outside combat) during which a fast revive like Revivify still works. After that, the body is "long dead".
- **Elemental permadeath:** Fire, Acid, Lightning, Cold, Radiant and Necrotic killing blows apply the strongest Raise Dead block at once. Set it to `death` (any lethal hit), `overkill` (only above a threshold), or `none`.
- **The long-rest ladder:** every completed long rest makes a corpse harder to raise. The block escalates one tier per rest, through five tiers:
  - **Before the first rest:** Revivify (inside the recent-death window) or Raise Dead.
  - **Tiers 1 to 3:** Raise Dead needs a higher spell slot each time, from level 6 up to level 8.
  - **Final tier:** only a 9th-level Raise Dead, a True Resurrection scroll, or Withers can bring them back.

### 5. Resurrection has a cost
- **Constitution penalty:** each resurrection cast (Resurrection, or a True Resurrection scroll) gives both caster and target a stacking Constitution penalty, −1 per tier up to −8.
- **Withers is the exception:** he doesn't take the penalty, and being resurrected by him clears the target's penalty.
- **Withers' price:** his resurrection fee is raised to 8,500 gold, in both his camp dialogue and the Act 2 version.

### 6. Empty slots grant initiative
Characters get +1 initiative for each empty weapon slot, main armour slot, helmet slot and cloak slot, so travelling light pays off. Two-handed melee weapons and bows count as filling both weapon slots. You can turn this off.

### 7. Dead Party Members tab (MCM)
Permadeath can leave someone dead in your party long before you can afford to raise them, or before Withers is available. This tab lists every dead party member and offers two buttons:

- **Send to Camp:** uses the game's own Withers dismissal, so the body goes to their camp spot.
- **Leave Body, Remove:** takes them out of the party where they lie.

For your own custom character (Tav/Durge), both buttons simply remove them from the party.

Anyone removed through this tab **rejoins the party automatically when they're revived**, by any means. The mod uses the game's own recruitment routine, which has no party-size check, so it works even with a full party (including with Configurable Party Limit).

### 8. Avatar Switching tab (MCM), experimental
While your custom character (Tav) is dead, this tab lets you make a living origin companion your main character. When Tav is revived, you can hand control back. The mod makes sure only one character holds main-character status at a time.

> ⚠️ Promoting a companion to main character has no official path in the game's scripts. Keep a save before you use it.

### 9. Halsin's gear restore (Damage Destruction only)
If Halsin dies before you recruit him and permadeath destroys his gear, his equipment goes back on when he's revived. The mod records what he's wearing while he's alive, and if nothing was recorded it falls back to his default Act 1 outfit.

### 10. NPC & companion revival fixes
These are the same fixes as Raise The Dead. See [NPCs accounted for](#npcs-accounted-for).

---

## NPCs accounted for

### What every revived character gets
- **Cleared defeated state:** leftover "defeated / can't act / can't talk" story state is removed, so they aren't a mute husk.
- **No "stolen" overlay:** the red "belongs to someone else" overlay is removed from their body and gear.
- **Talk works straight away:** a stale "downed" marker can make a revived character, companions included, impossible to talk to until a long rest or a fight. It's cleaned up automatically.
- **Respawn fallback:** an unlisted NPC who still can't act or talk shortly after revival is respawned in place.

### Characters with dedicated fixes
- **Baelen Bonecloak** (Act 1, Underdark). Restores his full "rescued" quest state and his dialogue, and sends him back to Derryth.
- **Scratch** (Act 1). Restores the right dialogue for how far his quest had gone: camp dialogue, or his original wilderness dialogue.
- **Oskar Fevros** (Act 1, Zhentarim hideout). Restores his dialogue and his "freed" flags, so his Act 3 *Oskar's Beloved* quest stays available.
- **Arabella** (Act 1, Druid Grove). Sets the outcome you'd get by talking Kagha down. Sends her to her parents and unlocks their reunion. Stops Rath mourning her and restores her click-to-talk dialogue. Her corpse never gets the "stolen goods" overlay. *Confirmed in play.*
- **Aradin** (Act 1, Grove entrance). Restores his dialogue and self-healing, and picks the right dialogue for whether his confrontation with Zevlor ended peacefully.
- **Minthara** (Act 1 Grove attack, before Grymforge or Moonrise). Puts her in the game's own "spared, knocked out" state, so she follows the normal path to Moonrise instead of re-aggroing.
- **Mirkon** (Act 1, harpy beach). Removes his death flags and charm. If the harpies are already dead, it runs the game's own "saved the victim" outcome; if not, he goes back to the charmed encounter.
- **Halsin** (Act 1, goblin camp, before recruitment). Clears his death flags and repairs his journal links. If the goblin leaders are dead, he gets the outcome where he helped you kill them: his thank-you dialogue, then he leaves for the Grove. If they're alive, he follows you again. His gear is restored too (see feature 9).
- **Damon** (Act 1, Druid Grove). Put back on the tiefling side of the Druid Attack fight with his fight dialogue, and back on the Grove's NPC list, with the "too few tieflings" count corrected. Karlach's "Damon is dead" memory is cleared, so he can still upgrade her. *Confirmed in play.*
- **Eremus** (Act 1, Druid Grove). Same Druid Attack repair as Damon: roster, dialogue, NPC list and tiefling count. *Confirmed in play.*

### Known limits
- **Journal entries:** an entry that has already been written, such as "X was defeated", can't be erased. If a quest closed because of a death, the game won't reopen it, so the journal may stop tracking even though the character works normally.
- **No generic fix:** every story NPC in BG3 is scripted by hand, so fixes are added one character at a time. A revived NPC who isn't listed only gets the universal fixes.

---

## Installation
1. Install BG3 Script Extender and MCM.
2. Install Damage Destruction with your mod manager, then enable it.
3. Change settings in-game through MCM → **Damage Destruction**.

## Compatibility notes
- **Configurable Party Limit:** works with it. Note that mod's own rule blocks long rests while more than 4 party members are active.
- **ImmersiveNudity SE Patch:** item destruction notifies it, so destroyed gear is also stripped visually.
- Mods that change Revivify, Raise Dead, Resurrection or Withers may conflict.

## Credits
- Author: A Human
- Baelen fix originally datamined by NexusMods user **whyslyy**.
