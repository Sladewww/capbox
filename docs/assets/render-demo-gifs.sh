#!/usr/bin/env bash
# Regenerate demo GIFs (Pillow + ffmpeg).
# 1) demo-commands.gif  — 常用命令：exec / pkg / cp / status
# 2) demo-quickstart.gif — quickstart：bootstrap → init → id -u
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
OUT="$ROOT/docs/assets"
python3 - "$OUT" <<'PY'
from PIL import Image, ImageDraw, ImageFont
from pathlib import Path
import tempfile, subprocess, sys

out_dir = Path(sys.argv[1])
frames_dir = Path(tempfile.mkdtemp(prefix='capbox-gif-'))
W = 880
try:
    font = ImageFont.truetype('/usr/share/fonts/truetype/dejavu/DejaVuSansMono.ttf', 18)
    font_title = ImageFont.truetype('/usr/share/fonts/truetype/dejavu/DejaVuSansMono-Bold.ttf', 18)
except Exception:
    font = font_title = ImageFont.load_default()


def make(name, title, scenes, *, height, bg, bar, palette):
    frames = []
    for i, (delay, lines) in enumerate(scenes):
        img = Image.new('RGB', (W, height), bg)
        d = ImageDraw.Draw(img)
        d.rectangle([0, 0, W, 40], fill=bar)
        d.rectangle([0, 0, 8, height], fill=palette['strip'])
        d.text((20, 10), title, fill=palette['title'], font=font_title)
        y = 58
        for c, t in lines:
            d.text((22, y), t, fill=palette.get(c, palette['fg']), font=font)
            y += 26
        fp = frames_dir / f'{name}-{i:02d}.png'
        img.save(fp)
        frames.append((fp, delay))
    lst = frames_dir / f'{name}.txt'
    with lst.open('w') as f:
        for fp, delay in frames:
            f.write(f"file '{fp}'\nduration {delay/1000}\n")
        f.write(f"file '{frames[-1][0]}'\n")
    pal = frames_dir / f'{name}-pal.png'
    gif = out_dir / f'{name}.gif'
    subprocess.run(['ffmpeg','-y','-f','concat','-safe','0','-i',str(lst),
                    '-vf','fps=8,scale=880:-1:flags=lanczos,palettegen',str(pal)],
                   capture_output=True, check=True)
    subprocess.run(['ffmpeg','-y','-f','concat','-safe','0','-i',str(lst),'-i',str(pal),
                    '-lavfi','fps=8,scale=880:-1:flags=lanczos[x];[x][1:v]paletteuse',str(gif)],
                   capture_output=True, check=True)
    print(gif, gif.stat().st_size)


# ---- 1) 常用命令（橙/琥珀主题）----
cmd_pal = {
    'fg': (245, 230, 200), 'dim': (160, 140, 110), 'accent': (255, 190, 70),
    'prompt': (120, 220, 255), 'title': (255, 220, 160), 'strip': (220, 140, 40),
}
make(
    'demo-commands',
    'CapBox · 常用命令  (exec / pkg / cp / status)',
    [
        (700, [('dim', '# 日常：在已 init 的项目里执行这些命令')]),
        (650, [('prompt', '$ '), ('fg', 'capbox exec -- id -u')]),
        (900, [('prompt', '$ '), ('fg', 'capbox exec -- id -u'), ('accent', '0')]),
        (650, [('prompt', '$ '), ('fg', 'capbox pkg install curl')]),
        (1100, [
            ('prompt', '$ '), ('fg', 'capbox pkg install curl'),
            ('dim', 'OK: curl-8.x installed'),
        ]),
        (650, [('prompt', '$ '), ('fg', 'capbox exec -- curl -I https://example.com')]),
        (1000, [
            ('prompt', '$ '), ('fg', 'capbox exec -- curl -I https://example.com'),
            ('accent', 'HTTP/2 200'),
        ]),
        (650, [('prompt', '$ '), ('fg', 'capbox cp guest:/root/out.txt host:./out.txt')]),
        (1000, [
            ('prompt', '$ '), ('fg', 'capbox cp guest:/root/out.txt host:./out.txt'),
            ('accent', '[capbox] copied → ./out.txt'),
        ]),
        (650, [('prompt', '$ '), ('fg', 'capbox status')]),
        (1200, [
            ('prompt', '$ '), ('fg', 'capbox status'),
            ('fg', '发行版     : alpine'),
            ('fg', 'rootfs     : .capbox/os/alpine（就绪）'),
            ('fg', '守护进程   : 未运行'),
            ('accent', '工作区     : /path/to/project'),
        ]),
    ],
    height=460, bg=(28, 22, 14), bar=(48, 36, 22), palette=cmd_pal,
)

# ---- 2) quickstart（绿主题：bootstrap → init → id）----
qs_pal = {
    'fg': (210, 235, 210), 'dim': (110, 140, 110), 'accent': (70, 220, 130),
    'prompt': (120, 200, 255), 'title': (180, 255, 200), 'strip': (40, 180, 90),
}
make(
    'demo-quickstart',
    'CapBox · Quickstart  (bootstrap → init → id)',
    [
        (700, [('dim', '# 空项目第一次使用')]),
        (650, [('prompt', '$ '), ('fg', 'capbox bootstrap')]),
        (1000, [
            ('prompt', '$ '), ('fg', 'capbox bootstrap'),
            ('accent', '[capbox] 已在工作区就绪: ./.capbox'),
        ]),
        (650, [('prompt', '$ '), ('fg', 'capbox init --distro alpine')]),
        (1200, [
            ('prompt', '$ '), ('fg', 'capbox init --distro alpine'),
            ('dim', '[capbox] 解包 rootfs → .capbox/os/alpine'),
            ('accent', '[capbox] 完成（alpine，~3.4MB）'),
        ]),
        (650, [('prompt', '$ '), ('fg', 'capbox exec -- id -u')]),
        (1100, [
            ('prompt', '$ '), ('fg', 'capbox exec -- id -u'),
            ('accent', '0'),
            ('dim', '# 容器内是 root，可以装包 / 改 /etc'),
        ]),
    ],
    height=400, bg=(16, 28, 20), bar=(28, 48, 34), palette=qs_pal,
)
PY
# drop old doctor gif
rm -f "$OUT/demo-doctor.gif"
echo "Wrote GIFs under $OUT"
