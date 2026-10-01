# clipbridge

Read your Mac clipboard from SSH sessions. Copy an image or text on the Mac, and on the remote box
`xclip -o`, `xsel -b -o` and `pbpaste` return it. That includes Claude Code: Ctrl+V in a remote Claude
Code session attaches the image you just copied (or pastes the text).

It's one-way, Mac → remote. Nothing is pushed: the remote pulls on demand through your existing SSH
connection, and only when a program asks for the clipboard.

```
Mac: ClipBridge.app (menu bar)                         remote (Ubuntu)
  127.0.0.1:7788  <── ssh RemoteForward 127.0.0.1:<port> ──  ~/.local/bin/{xclip,xsel,pbpaste}
                                                             → clipbridge-shim (python3)
```

## Install

On the Mac (needs Xcode / Swift 6):

```sh
bin/clipbridge install          # builds ~/Applications/ClipBridge.app, starts it at login, links the CLI
clipbridge add <ssh-alias>      # sets up one host
clipbridge doctor <ssh-alias>   # checks everything end to end (copy an image or text first)
```

`add` does, for that one host:
- appends a marked `# clipbridge begin/end <alias>` block to `~/.ssh/config` (a backup is written next
  to it first). The block adds a RemoteForward on a random per-host port, plus `ControlMaster auto`,
  `ControlPath ~/.ssh/cm/%C`, `ControlPersist 10m` and keep-alives, so all sessions to the host share
  one connection and one forward
- copies `clipbridge-shim` to the remote `~/.local/bin`, with `xclip`, `xsel` and `pbpaste` symlinked to
  it, and writes the remote `~/.config/clipbridge/config.json` (0600)
- adds a marked block to the remote `~/.zshrc` (or `~/.bashrc`) that puts `~/.local/bin` first on PATH

It refuses to run if your ssh config already sets ControlMaster/ControlPath/ControlPersist/RemoteForward,
or if the remote `~/.local/bin` already has an `xclip`, `xsel` or `pbpaste` that isn't ours.

Open a **new** ssh session after `add`. A connection opened before it has no forward.

Other commands:

```sh
clipbridge pause | resume       # stop / start serving (same as the menu item)
clipbridge status
clipbridge remove <ssh-alias>   # undoes add, locally and on the remote
```

## What works

| On the remote | Gets |
|---|---|
| Claude Code Ctrl+V | the image (or the text if there's no image) |
| `xclip -selection clipboard -o` (`-t text/plain`, `UTF8_STRING`, …) | text |
| `xclip -selection clipboard -t image/png -o` (any `image/*`) | the image as PNG |
| `xclip -selection clipboard -t TARGETS -o` | the available types |
| `xsel -b -o`, `xsel --clipboard --output` | text |
| `pbpaste` | text |

Everything else runs the real tool if one is installed, or exits 1 if not:
- writes (`xclip -i`, `xsel -i`)
- the primary selection (`xclip -o` with no `-selection`, `xsel -p`)
- other flags

**Neovim** only uses xclip when `$DISPLAY` is set, so tell it about pbpaste directly:

```vim
let g:clipboard = {'name': 'clipbridge', 'paste': {'+': 'pbpaste', '*': 'pbpaste'}, 'copy': {'+': 'true', '*': 'true'}}
```

**Doesn't work:**
- remote → Mac copy (`pbcopy`, `xclip -i`); use OSC 52 in your terminal for that
- apps that talk to an X server directly (vim built with `+clipboard`)

## Images

- **Where the image comes from:** in order, an image file copied in Finder, then `public.png`, then
  `public.tiff`. Copying a non-image file in Finder serves nothing, so its icon is never sent.
- **Size:** PNGs with a long edge of 2000 px or less pass through unchanged. Larger or non-PNG images
  are scaled to a 2000 px long edge and sent as PNG. Claude scales down large images anyway.

## Security model

- **Mac listener:** the app listens only on `127.0.0.1:7788`. Nothing on your network can reach it.
- **Per-host token:** each host has its own random 32-byte token, stored 0600 on both ends. Requests
  carry an HMAC-SHA256 over the path, host, timestamp and a random nonce. The token itself never travels
  and never appears in a process's arguments, so other users on a shared box can't read it from `ps`.
- **Request checks:** stale timestamps (more than 60 s off), replayed nonces and bad MACs get 401.
- **Signed responses:** the shim rejects any response not signed with the token. If another user on the
  box grabs the forward port first, they can't feed you a fake image or text, and they never see your
  token.
- **Freshness window:** only content copied in the last 2 minutes is served (menu: 2 min / 10 min / Off).
  Content already on the clipboard when the app starts counts as stale until you copy something.
- **Password managers:** items they mark as concealed or transient (`org.nspasteboard.ConcealedType`,
  `TransientType`, 1Password) are **never** served. Maccy honours the same markers.
- **What it can't stop:** while the forward is up and the window is open, any process running as *your*
  user on the remote can read the clipboard. That includes the remote Claude Code's own Bash tool. Use
  Pause when you copy something sensitive that isn't marked as concealed, or remove the host.
- **Log:** every pull is logged to `~/Library/Logs/clipbridge.log` (host, route, status, size; never the
  content) and shown under *Recent pulls* in the menu.

## Notes

- **Signing:** the app is signed with your Apple Development identity if you have one, otherwise
  ad-hoc. macOS may still refuse notifications for a locally built app ("Notifications are not allowed
  for this application"). Pulls are then only logged and listed in the menu.
- **macOS paste privacy:** if macOS asks whether ClipBridge may read the pasteboard, allow it under
  System Settings → Privacy & Security → Paste from Other Apps. The log records the current setting at
  start (`accessBehavior=2` means always allowed).
- **Claude Code versions:** the tested Claude Code builds on Linux (2.1.205 and 2.1.286) read images via
  `xclip`. If a later build reads the clipboard some other way, `scripts/spike/run.sh <alias> --real`
  shows it. That test starts Claude Code in tmux on the remote, presses Ctrl+V and looks for
  `[Image #1]`.

## Development

```sh
swift test                                            # core: auth, nonces, freshness, images, HTTP
python3 -m unittest discover -s remote -p 'test_*.py' # shim against a fake server
scripts/bundle.sh                                     # build + install the app
scripts/dev-request.py --host <alias> image|text|targets   # signed request to the local app
scripts/spike/run.sh <alias> [--real]                 # live Claude Code paste test on a host
```
