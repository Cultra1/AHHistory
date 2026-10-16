# AH History

## v1.0.3

- Fixed: Lua error in `ScrollBox.lua` when opening the Auction House.

## v1.0.2

- Fixed: the History tab overlapped with tabs of other addons such as Auctioneer.
- Clicking an item in the History tab now opens it directly in the Buy tab's purchase view. Alt-click searches by name as before.
- If equipment has no listings at the item level you bought, all available versions are shown instead.
- Fixed: "Back" in the purchase view now returns to the History tab, and the History tab can be clicked while the purchase view is open.
- The addon now has its own icon and is listed under "Auctions" in the AddOns list.
- New diagnostic command `/ahhistory tabcheck`

## v1.0.1

- Updated for the current WoW patch.

## v1.0.0

First public release.

- History tab in the Auction House with your purchased items, per character or account-wide
- Duplicates are merged: buying an item again moves it to the top and increases its counter
- Search, category sidebar and time range filter in the History tab
- Purchase counter and total quantity in every item tooltip
- "Previously bought" entry in the Buy tab categories, with characters and categories as subentries
- Previously bought items are grouped at the top of Buy tab results and highlighted in a color of your choice
- Options under Esc > Options > AddOns > AH History
