# AH History

Never wonder again what you bought at the Auction House. AH History records every purchase you make and adds a **History** tab to the Blizzard Auction House, plus a **Previously bought** view in the Buy tab that shows which of your usual items are listed right now.

## Features

### History tab
- A new **History** tab next to Buy, Sell and Auctions
- Every item appears only once: buying it again moves it to the top and increases its counter
- Filter by character or show all characters of your account
- Search by item name
- Sidebar with item categories (like the Buy tab) and a time range filter (24 hours, 7 days, 30 days, all time)
- Click an item to search for it in the Buy tab, shift-click to link it in chat
- Right-click to remove an item from the list, or clear the whole list

### Previously bought (Buy tab)
- A **Previously bought** entry at the top of the Buy tab categories
- Shows all items you have bought before that are currently listed, with current prices
- Subentries per character and per category, just like Blizzard's own categories
- Available items are listed first

### Buy tab search results
- Items you have bought before are grouped at the top of your search results
- Optional colored highlight for those rows, with a color picker

### Tooltips
- Every item tooltip shows how often you bought the item and the total quantity, e.g. `AH: bought 12x, 2,400 total`

## Options

Open **Esc > Options > AddOns > AH History** or type `/ahhistory options`.

- Show purchase counter in item tooltips
- Maximum list entries (500 to 10,000, default 5,000)
- Show category and time filters in the History tab
- Show only the current character by default
- Group previously bought items first in the Buy tab
- Results to load for grouping (default 500, higher values can slow down the Auction House)
- Highlight previously bought items, with color picker
- Show categories under "Previously bought"

Purchase counters are kept permanently. Clearing or limiting the list never resets them.

## Good to know

- Purchases are recorded from the moment the addon is installed. There is no way to import older purchases.
- Buyouts are tracked, regular bids are not.
- AH History extends the Blizzard Auction House. If you use TradeSkillMaster, switch to the default Blizzard UI to see the History tab. Purchases made through TSM are still recorded.
- Data is stored account-wide in `WTF/Account/<ACCOUNT>/SavedVariables/AHHistory.lua` and survives addon updates.

## Commands

| Command | Description |
|---|---|
| `/ahhistory` | Shows the number of stored items |
| `/ahhistory options` | Opens the options |
| `/ahhistory color` | Opens the highlight color picker |
| `/ahhistory debug` | Toggles debug output in chat (resets on reload) |
| `/ahhistory tintcheck` | Diagnostic info for the Buy tab highlight |
| `/ahhistory catcheck` | Diagnostic info for the Buy tab categories |

## Bug reports

Please open an issue on GitHub or leave a comment on CurseForge. If something in the Auction House does not work, the output of `/ahhistory debug`, `/ahhistory tintcheck` or `/ahhistory catcheck` (a screenshot of the chat is fine) helps a lot.

## License

MIT, see [LICENSE](LICENSE).
