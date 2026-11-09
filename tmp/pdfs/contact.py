from PIL import Image, ImageDraw
from pathlib import Path
files = sorted(Path('tmp/pdfs/rendered').glob('page-*.png'))
tiles = []
for file in files:
    image = Image.open(file).convert('RGB')
    image.thumbnail((300, 425))
    tile = Image.new('RGB', (320, 455), '#d7deea')
    tile.paste(image, ((320-image.width)//2, 10))
    ImageDraw.Draw(tile).text((12, 435), file.name, fill='black')
    tiles.append(tile)
sheet = Image.new('RGB', (320*3, 455*((len(tiles)+2)//3)), 'white')
for index, tile in enumerate(tiles):
    sheet.paste(tile, ((index%3)*320, (index//3)*455))
sheet.save('tmp/pdfs/contact.png')
