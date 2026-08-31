# Lightning-L2 Linux Launcher

A one-click launcher that runs [Lightning-L2](https://lightning-l2.com) (a Lineage II: High Five / L2J Mobius CT2.6 private server) natively on Linux — no VM required, real GPU performance via DXVK.

Install the `.deb`, click the app icon, point it at your Lineage II High Five client folder once, and it's playable from then on.

## Install

Download the latest `.deb` from [lightning-l2.com/downloads/lightning-l2-launcher.deb](https://lightning-l2.com/downloads/lightning-l2-launcher.deb) or this repo's [Releases](../../releases), then:

```bash
sudo apt install ./lightning-l2-launcher.deb
```

Launch **Lightning-L2** from your applications menu. First run asks for your client folder (the one containing `system\l2.exe` — a genuine High Five (CT2.6) client, get it from [lineage2.org.uk](https://www.lineage2.org.uk/?wpdmdl=126) if you don't have one), then does one-time setup (~250MB download, a few minutes). Every launch after that is instant.

Multiboxing works fine — launch a second time after the first instance is up to play a second account.

## What it actually does

On first run, `setup.sh`:

1. Downloads and applies Lightning-L2's official `system` folder patch.
2. **Removes the two GameGuard kernel driver files** (`npkcrypt.sys`, `npkcusb.sys`) from that patch. GameGuard's kernel-mode driver cannot load under Wine at all (Wine has no kernel), so this is what actually makes the client startable on Linux — not a bypass of some other protection, just removing a component that's physically incapable of loading outside real Windows anyway. `GameGuard.des` (the definitions file) is left in place because the client's startup check requires the file to *exist*, even though nothing in a Wine environment ever loads the driver behind it.
3. Downloads [Wine-GE](https://github.com/GloriousEggroll/wine-ge-custom) (a gaming-patched Wine build) into an isolated prefix under `~/.local/share/lightning-l2/` — **not** your system Wine install, and **not** your system Wine prefix.
4. Installs the Tahoma font via `winetricks` (the client's UI text silently fails to render without it).
5. Installs [DXVK](https://github.com/doitsujin/dxvk) (translates the client's old Direct3D 9 calls to Vulkan, which is both faster and more compatible than Wine's built-in `wined3d` for this specific client).

Every subsequent launch just runs `wine system/l2.exe` in that prefix.

## Why this exists (the short version)

The obvious path — a Windows VM — works, but with three real costs: hypervisor overhead eats a lot of a modest laptop's CPU, GPU passthrough for actual acceleration is a lot of setup for a 2012-era client, and you're running a whole second OS just to play one game. Running natively under Wine looked simpler but hit three real bugs in sequence before it actually worked:

- **A Wine loader-lock deadlock** during GameGuard's init (a thread-creation-during-DLL-init pattern that recent stock Wine handles more strictly than real Windows does, causing a permanent hang). Wine-GE's extra compatibility patches sail through it; stock Wine 9.0 does not.
- **An X11/NV-GLX `BadMatch` crash** from the client's legacy fixed-function Direct3D 9 renderer fighting GLX pixel-format negotiation on modern NVIDIA drivers. DXVK sidesteps this entirely by talking to Vulkan directly instead of going through GLX.
- **Silently missing UI/login text.** The client renders most of its interface fine but pulls certain text through the Windows font system, specifically asking for Tahoma — which isn't part of any default Wine or Linux font set and has to be installed separately.
- **A crash when destroying an inventory item.** That confirmation dialog goes through an `XMLDocument::Load` call that needs MSXML registered as a proper COM server — having the DLL physically present in the game folder isn't enough, and Wine doesn't register it by default. `winetricks msxml4 msxml6` fixes it.

None of these are Lightning-L2-specific bugs — they're generic "old D3D9 Windows game on modern Linux" pain points — but they took real trial and error to isolate individually, which is the whole reason this exists as a packaged, one-click tool instead of a paragraph of manual instructions.

## Troubleshooting

- **Logs**: every launch writes to `~/.local/share/lightning-l2/logs/launch_<timestamp>.log` (last 10 kept) — check the most recent one first. A `Terminal=true` window can close before you can read it; the log survives regardless.
- **"Lightning-L2 is already starting" on a fresh launch**: a previous attempt's lock (`~/.local/share/lightning-l2/.launch.lock`) didn't release — this shouldn't happen in normal use (the lock releases automatically ~8s into a healthy launch, or when the wine process exits); if it does, make sure no wine/l2.bin process is still running (`ps aux | grep wine`) and retry.
- **Reset everything**: `rm -rf ~/.local/share/lightning-l2 ~/.config/lightning-l2` and relaunch — this re-triggers first-run setup from scratch, including re-asking for your client folder.
- Something else: open an issue here with the relevant `launch_*.log`, or ask in the [Discord](https://discord.gg/dshrJbxfS).

## Building from source

```bash
git clone https://github.com/Unknown-brazilian/lightning-l2-linux-launcher
cd lightning-l2-linux-launcher
./build.sh
```

Outputs `lightning-l2-launcher_<version>_amd64.deb`. Bump `Version:` in `packaging/DEBIAN/control` before rebuilding a release.

## License

The launcher scripts and packaging in this repo (`packaging/`, `build.sh`) are MIT-licensed — see [LICENSE](LICENSE). This repo does **not** contain the Lineage II client or any Lightning-L2 server assets; those remain the property of their respective rights holders and are downloaded separately by the launcher at first run.
