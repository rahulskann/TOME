"""Generate a 2048x1536 grid image for the demo pack, then slice it:

    python make_demo_image.py
    python ../../tools/slicer/slice_map.py demo-world.png . --map-id world --zip
"""

from PIL import Image, ImageDraw

W, H, STEP = 2048, 1536, 128

img = Image.new("RGB", (W, H), "#1d2330")
draw = ImageDraw.Draw(img)
for x in range(0, W, STEP):
    draw.line([(x, 0), (x, H)], fill="#2f3a4f", width=2)
for y in range(0, H, STEP):
    draw.line([(0, y), (W, y)], fill="#2f3a4f", width=2)
for x in range(0, W, STEP * 2):
    for y in range(0, H, STEP * 2):
        draw.text((x + 6, y + 6), f"{x},{y}", fill="#8fa3c7")
img.save("demo-world.png")
print("wrote demo-world.png")
