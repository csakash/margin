# SPEC: Every keyboard shortcut works in Margin (0.2.2)

Problem: Margin's panel is a non-activating NSPanel, so Margin is never the active app. AppKit offers key equivalents to the main menu only for the active app, so ⌘C, ⌘V, ⌘X, ⌘A, ⌘Z and ⌘N did nothing. Undo and redo also changed text without a text-did-change notification, so they were never saved.

Change:
1. `FloatingPanel.sendEvent`: for ⌘ keys while Margin is inactive, try the panel's views, then find the matching main-menu item. Targeted items get their action sent; target-less ones walk the panel's responder chain. Undo and redo go to the undo manager.
2. Menus gain Hide Others ⌥⌘H, Close ⌘W (folds), All Notes ⌘O, Paste and Match Style ⌥⇧⌘V, Delete, Find… ⌘F, Find Next ⌘G, Find Previous ⇧⌘G, Format (Bold ⌘B, Italic ⌘I, Inline Code ⌘E, Body ⌘0, H1–H3 ⌘1–⌘3, Numbered ⇧⌘7, Bullet ⇧⌘8, To-do ⇧⌘9, Quote ⇧⌘., Code Block ⌥⌘C) and Window (Minimise ⌘M).
3. The editor saves after undo and redo.

Done when every listed shortcut acts on the panel while another app is active, and undo/redo results are on disk.
