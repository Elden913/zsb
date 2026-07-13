Very Simple status bar for wayland (mangowm) written in zig.
Program is not organized very well, only for personal use.

Uses the dwl ipc protocol

Supports:
- Workpaces (via dwl-ipc)
- Battery
- Volume
- Time

Theme loading (~/.config/zsb/settings.zon) Check src/main.zig for fields

Build:

```
zig build -Doptimize=ReleaseFast
````
