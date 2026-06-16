# Config

This is the `xplr` config that turns this fork into a fast dual-pane,
function-key file manager. It is the file referenced by the top-level README.

## What it gives you

- **Dual panes** with **Tab** to switch.
- Function keys: **F3** view · **F4** edit · **F5** copy (live in-panel
  progress bar) · **F6** move · **F7** mkdir · **F8** delete · **F10** quit.
- **Enter** descends into a directory, not quit.
- A **blue theme** with a function-key hint bar.
- A right column: **preview** (top) / **selection** (middle) / **help** (bottom).
  Text previews render on a uniform background; image files preview as real
  images on iTerm2 (via the fork's engine change) or `viu` blocks elsewhere.
- A **zsh-style multilevel `/` jump**: press `/` and type `p/w/s` to list every
  `~/projects/w*/s*…` match across directories at once; **Enter** jumps
  to the highlighted one.

## Install

1. **Build and install the patched binary** (the engine changes live in this
   repo — see the top-level README). The config relies on the fork's
   event-driven control pipe and image overlay.

2. **Install the two required plugins** into `~/.config/xplr/plugins/`:

   ```sh
   mkdir -p ~/.config/xplr/plugins
   git clone https://github.com/sayanarijit/dual-pane.xplr ~/.config/xplr/plugins/dual-pane
   git clone https://github.com/sayanarijit/map.xplr       ~/.config/xplr/plugins/map
   ```

3. **Install the config:**

   ```sh
   cp config/init.lua ~/.config/xplr/init.lua
   ```

## Notes

- `F5` copy writes its progress to `/tmp/xplr_copy_progress`; the `/` jump builds
  a temporary results folder at `/tmp/xplr-jump-results`. Both are scratch paths,
  recreated as needed.
- Real image previews require **iTerm2**; on other terminals the preview falls
  back to `viu`'s colored blocks (install [`viu`](https://github.com/atanunq/viu)).
