# Stream Deck — Browser Tab Buttons

Built in Streamdeck browser shortcuts always open a new tab. This version intelligently addresses that issue with awareness of Edge profiles and which tabs are already open.
Turn any open browser tab into a Stream Deck key. Press the key, that tab comes
to the front. If the tab is closed, press twice and it opens. If the browser is
closed entirely, one press starts it.

Works with Microsoft Edge on Windows 10/11. Nothing is installed, nothing runs
in the background, and nothing changes system-wide. No admin rights needed.

**[Download the latest release](../../releases/latest)** — or clone the repo and
run `Start Here.cmd`.

---

## How it works

Stream Deck cannot talk to a browser tab. This bridges the gap using Windows UI
Automation, which Edge exposes as a normal accessibility tree: every tab shows
up as a `TabItem` whose name is the page title. The tool finds the tab by name,
selects it, and pulls its window to the front.

Each key runs a small `.vbs` launcher, which runs `Focus-EdgeTab.ps1` with the
match string for that tab. Nothing else is required — no plugin, no service.

---

## What you need

- Windows 10 or 11
- Microsoft Edge
- The Stream Deck app
- No admin rights, no downloads, no PowerShell knowledge

---

## Setup

1. Put the whole folder somewhere permanent — `C:\Scripts` works well.
   Avoid OneDrive-synced folders; sync can lock files mid-write.
2. Open the browser tabs you want buttons for.
3. Double-click **Start Here.cmd**.

*(screenshot: the folder contents with Start Here.cmd highlighted)*

If Windows shows a blue "Windows protected your PC" box, click **More info** →
**Run anyway**. That appears because the file came from the internet, not
because anything is wrong with it.

---

## Making buttons

*(screenshot: the main window with several rows ticked)*

1. Tick the **Use** box on each tab you want a button for.
   The search box at the top filters the list as you type.
2. Click **Capture URLs**. Your tabs flick past for a second while it reads each
   address, then everything goes back where it was. This is what lets a button
   reopen a tab you have closed.
3. Click **Build selected buttons**.
4. A window appears telling you where the files went. Leave it open.

### The Match? column

| Shows  | Means                                                            |
|--------|------------------------------------------------------------------|
| green `ok`   | Exactly one open tab matches. This is what you want.       |
| orange number| Several tabs match. The button takes the first one.        |
| red `none`   | Nothing open matches. The button can only open the address.|

A **yellow Match cell** means the text being matched looks like it changes on
its own — an unread count, a date, a document name. Click **Capture URLs**,
which usually fixes it automatically.

---

## Putting a button on your Stream Deck

*(screenshot: Windows Explorer showing the StreamDeck folder)*

1. Open the `TabButtons\StreamDeck` folder.
2. Double-click a `.streamDeckAction` file, or drag it onto the key you want.
3. The icon and label come with it. Done.

### Doing it by hand instead

*(screenshot: Stream Deck app with System > Open highlighted)*

1. In Stream Deck, open the **System** category on the right.
2. Drag **Open** onto an empty key.
3. Click **App / File** → **Browse**.
4. Choose a `.vbs` file from the `TabButtons` folder.
5. Drag an icon from `TabButtons\Icons` onto the key.

Do not use **Website**, **Hotkey**, or **Multi Action**. The button is a file,
so it has to be opened.

---

## How a button behaves

| Situation                        | What happens                                        |
|----------------------------------|-----------------------------------------------------|
| Tab is open                      | Jumps to it.                                        |
| Tab is closed, browser open      | Press once: browser comes forward, notification says the tab is not open. Press again within 1.5 seconds: it opens. |
| Browser is closed                | One press starts it, waits for your pinned tabs to come back, then jumps to the tab. |

The two-press rule exists on purpose. If a button's match ever goes stale, one
press would otherwise open a duplicate tab every single time.

---

## When something does not work

**The key does nothing at all.** Check that the file it points to still exists.
Moving or renaming the folder breaks imported keys, because Stream Deck stores
the full path. Re-import from `TabButtons\StreamDeck` after any move.

**The key opens the wrong tab.** Its match text matches more than one tab.
Run the tool, look at the **Match?** column, and make the match more specific.

**The key stopped working after it worked for weeks.** The tab's title changed.
Run the tool, tick that tab, click **Capture URLs**, then **Build selected
buttons**, keeping the same launcher filename.

**Nothing above helps.** Every press writes a line to a log file. Press
`Windows + R`, paste `%TEMP%\FocusEdgeTab.log`, press Enter. The last lines say
what was searched for and whether it was found.

---

## What each file does

| File | Purpose |
|------|---------|
| `Start Here.cmd` | Double-click entry point. Unblocks downloaded files, opens the tool. |
| `New-TabButton.ps1` | The window you interact with. Builds everything. |
| `Focus-EdgeTab.ps1` | The engine. Each key runs this; it finds and focuses the tab. |
| `FocusTab.vbs` | Optional template for hand-made launchers — copy and rename. |
| `TabButtons\` | Generated output. Not in the repo; it is yours and machine-specific. |

## Sharing this with someone else

Zip the whole folder minus `TabButtons` — your buttons are yours, and the paths
inside them point at your machine. They unzip it, run **Start Here.cmd**, and
build their own.

---

## Advanced

Click **Advanced...** in the main window for individual steps: create launchers
only, download icons only, export actions only, test a single row, and repair
folder paths after a move.

Match text accepts alternatives separated by `;;`. Useful when a site rewrites
its own title:

```
Mydomain Mail;;messaged you - Chat
```

That matches the mail tab whether it shows the mailbox or a chat notification.
