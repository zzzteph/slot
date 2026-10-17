"""Builds every icon the builds need from art/icon_render.png (written by tools/render_art.gd): the car
on its glowing lane, on a dark rounded badge -> art/icon.png (256), art/icon_1024.png, art/icon.ico
(Windows, 16-256). Run from the project root:  python tools/make_icons.py"""
from PIL import Image, ImageDraw, ImageFilter

S = 1024
render = Image.open("art/icon_render.png").convert("RGBA")


def badge(size):
    # Rounded square: night-time charcoal at the top to the braids' electric blue at the bottom.
    grad = Image.new("RGBA", (size, size))
    top, bottom = (22, 22, 32), (16, 70, 104)
    px = grad.load()
    for y in range(size):
        t = y / (size - 1)
        c = tuple(int(top[i] + (bottom[i] - top[i]) * t) for i in range(3)) + (255,)
        for x in range(size):
            px[x, y] = c
    img = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    mask = Image.new("L", (size, size), 0)
    r = int(size * 0.2)
    ImageDraw.Draw(mask).rounded_rectangle([0, 0, size - 1, size - 1], radius=r, fill=255)
    img.paste(grad, (0, 0), mask)
    ImageDraw.Draw(img).rounded_rectangle([3, 3, size - 4, size - 4], radius=r - 3,
                                          outline=(255, 255, 255, 70), width=max(2, size // 128))
    return img


base = badge(S)
# The render fills its frame with the piece of track; the car sits in the middle. Crop to what was drawn
# and fit it big: the lane runs off the badge's edges, where the rounded mask cuts it.
box = render.split()[3].getbbox()
render = render.crop(box)
k = S * 1.0 / max(render.width, render.height)
render = render.resize((round(render.width * k), round(render.height * k)), Image.LANCZOS)
fitted = Image.new("RGBA", (S, S), (0, 0, 0, 0))
fitted.alpha_composite(render, ((S - render.width) // 2, (S - render.height) // 2))
# A soft electric glow under it all, then the picture.
alpha = fitted.split()[3]
glow = Image.new("RGBA", (S, S), (90, 200, 255, 0))
glow.putalpha(alpha.point(lambda a: int(a * 0.45)))
glow = glow.filter(ImageFilter.GaussianBlur(28))
base.alpha_composite(glow, (0, 10))
base.alpha_composite(fitted, (0, 0))
mask = Image.new("L", (S, S), 0)
ImageDraw.Draw(mask).rounded_rectangle([0, 0, S - 1, S - 1], radius=int(S * 0.2), fill=255)
out = Image.new("RGBA", (S, S), (0, 0, 0, 0))
out.paste(base, (0, 0), mask)

out.save("art/icon_1024.png")
out.resize((256, 256), Image.LANCZOS).save("art/icon.png")
out.resize((256, 256), Image.LANCZOS).save("art/icon.ico",
                                         sizes=[(16, 16), (24, 24), (32, 32), (48, 48), (64, 64), (128, 128), (256, 256)])
print("icons: art/icon.png, art/icon_1024.png, art/icon.ico")
