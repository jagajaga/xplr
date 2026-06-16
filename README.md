# xplr (jagajaga's fork)

A personal fork of [xplr](https://github.com/sayanarijit/xplr) with two engine
changes upstream doesn't have, plus a config that turns it into a fast dual-pane,
function-key file manager.

## The `/` jump — fuzzy, multilevel, live

Press `/` and start typing a path. Each keystroke re-globs every segment and
lists **all** matching folders across the whole tree at once — narrowing live as
you type. No descending one directory at a time, no external `fzf`:

```text
/ ❯ p          →  papers/   photos/   projects/   public/
/ ❯ p/w        →  projects∕web-app    projects∕worker    public∕wiki
/ ❯ p/w/s      →  projects∕web-app∕src    projects∕worker∕scripts
                  projects∕web-app∕server
                  └─ Enter → jumps to the highlighted match
```

So `p/w/s` finds everything under `~/projects/w…/s…` in one flat list (the `∕`
on screen stands in for `/`, since a real slash can't be in a name). **Enter**
resolves the highlight to its real path — following symlink chains (e.g. a
cloud-synced folder that is itself a symlink) — and takes you there.

## Engine changes

- **Event-driven UI — no polling.** A session-lifetime control FIFO + a dedicated
  reader thread feed the main event loop, so background processes update the UI
  **live** without a keypress. A file copy's progress bar animates in real time
  and the other pane refreshes the instant the copy finishes — upstream xplr only
  redraws on keyboard input.
- **Real in-panel image previews (iTerm2).** The preview panel renders actual
  images via the iTerm2 inline-image protocol (through `viu`) — centered, no black
  letterbox — instead of ANSI blocks.

## The config

Shipped at [`config/init.lua`](./config/init.lua) — copy it to
`~/.config/xplr/init.lua`. It gives you **dual panes** (**Tab** to switch), the
function keys **F3** view / **F4** edit / **F5** copy (with a live progress bar) /
**F6** move / **F7** mkdir / **F8** delete / **F10** quit, **Enter** to descend
into a directory, a blue theme with a function-key hint bar, a preview /
selection / help right column, and the `/` jump above. See
[`config/README.md`](./config/README.md) for setup.

Engine changes live in `src/runner.rs`, `src/ui.rs`, and `src/app.rs`. Everything
below is the upstream xplr README.

---

<h1 align="center">
  ▸[<a href="https://github.com/sayanarijit/xplr/blob/main/assets/icon/xplr.svg"><img src="https://s3.gifyu.com/images/xplr32.png" alt="▓▓" height="20" width="20" /></a> xplr]
</h1>

<p align="center">
A hackable, minimal, fast TUI file explorer
</p>

<p align="center">

<a href="https://crates.io/crates/xplr">
<img src="https://img.shields.io/crates/v/xplr.svg" />
</a>

</p>

<p align="center">

https://user-images.githubusercontent.com/11632726/166747867-8a4573f2-cb2f-43a6-a23d-c99fc30c6594.mp4

</p>

<h3 align="center">
  [<a href="https://xplr.dev/en/install">Install</a>]
  [<a href="https://xplr.dev/en">Documentation</a>]
  [<a href="https://xplr.dev/en/awesome-hacks">Hacks</a>]
  [<a href="https://xplr.dev/en/awesome-plugins">Plugins</a>]
  [<a href="https://xplr.dev/en/awesome-integrations">Integrations</a>]
</h3>

xplr is a terminal UI based file explorer that aims to increase our terminal
productivity by being a flexible, interactive orchestrator for the ever growing
awesome command-line utilities that work with the file-system.

To achieve its goal, xplr strives to be a fast, minimal and more importantly,
hackable file explorer.

xplr is not meant to be a replacement for the standard shell commands or the
GUI file managers. Rather, it aims to [integrate them all][14] and expose an
intuitive, scriptable, [keyboard controlled][2],
[real-time visual interface][1], also being an ideal candidate for [further
integration][15], enabling you to achieve insane terminal productivity.

## Introductions & Reviews

- [[VIDEO] XPLR: Insanely Hackable Lua File Manager ~ Brodie Robertson](https://youtu.be/MaVRtYh1IRU)

- [[Article] What is a TUI file explorer & why would you need one? ~ xplr.stck.me](https://xplr.stck.me/post/25252/What-is-a-TUI-file-explorer-why-would-you-need-one)

- [[Article] FOSSPicks - Linux Magazine](<https://www.linux-magazine.com/Issues/2022/258/FOSSPicks/(offset)/6>)

## Packaging

Package maintainers please refer to the [RELEASE.md](./RELEASE.md).

<a href="https://repology.org/project/xplr/versions"><img src="https://repology.org/badge/vertical-allrepos/xplr.svg" /></a>

## Backers

<a href="https://opencollective.com/xplr#backer"><img src="https://opencollective.com/xplr/tiers/backer.svg?width=890" /></a>

[1]: https://xplr.dev/en/layouts
[2]: https://xplr.dev/en/configure-key-bindings
[14]: https://xplr.dev/en/awesome-plugins#integration
[15]: https://xplr.dev/en/awesome-integrations
