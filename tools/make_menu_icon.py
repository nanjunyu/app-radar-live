import sys
from PIL import Image

def process_badge(im):
    # Mode 1: badge (non-white becomes black, white becomes transparent)
    # Target is 18x18. We'll do it with antialiasing.
    # To keep it anti-aliased, we can first scale up, process, then scale down,
    # or process pixel by pixel.
    im = im.convert('RGBA')
    width, height = im.size
    out = Image.new('RGBA', (width, height))
    for y in range(height):
        for x in range(width):
            r, g, b, a = im.getpixel((x, y))
            # Distance from white
            dist = (255-r) + (255-g) + (255-b)
            if dist < 30: # close to white
                out.putpixel((x, y), (0, 0, 0, 0))
            else:
                # keep original alpha, make color black
                out.putpixel((x, y), (0, 0, 0, a))
    return out

def process_silhouette(im):
    # Mode 2: silhouette (flood fill from corners to isolate background,
    # then make background and purple circle transparent, antenna black)
    im = im.convert('RGBA')
    width, height = im.size
    
    # 1. Flood fill to find background
    visited = [[False] * height for _ in range(width)]
    is_bg = [[False] * height for _ in range(width)]
    
    queue = [(0, 0), (width-1, 0), (0, height-1), (width-1, height-1)]
    for x, y in queue:
        visited[x][y] = True
        
    head = 0
    while head < len(queue):
        x, y = queue[head]
        head += 1
        r, g, b, a = im.getpixel((x, y))
        # if it is very light / white
        if r > 240 and g > 240 and b > 240:
            is_bg[x][y] = True
            for dx, dy in [(-1, 0), (1, 0), (0, -1), (0, 1)]:
                nx, ny = x + dx, y + dy
                if 0 <= nx < width and 0 <= ny < height:
                    if not visited[nx][ny]:
                        visited[nx][ny] = True
                        queue.append((nx, ny))
                        
    # 2. Output image
    out = Image.new('RGBA', (width, height))
    for y in range(height):
        for x in range(width):
            if is_bg[x][y]:
                out.putpixel((x, y), (0, 0, 0, 0))
            else:
                r, g, b, a = im.getpixel((x, y))
                if r > 240 and g > 240 and b > 240:
                    # Inner white antenna -> Black
                    out.putpixel((x, y), (0, 0, 0, a))
                else:
                    # Purple circle -> Transparent
                    out.putpixel((x, y), (0, 0, 0, 0))
    return out

def main():
    if len(sys.argv) < 5:
        print("Usage: python3 make_menu_icon.py <input> <output> <mode: badge|silhouette> <size>")
        sys.exit(1)
        
    input_path = sys.argv[1]
    output_path = sys.argv[2]
    mode = sys.argv[3]
    size = int(sys.argv[4])
    
    im = Image.open(input_path)
    
    # Process at high resolution first to preserve detail, then downscale
    # The logo is 1024x1024.
    if mode == 'badge':
        processed = process_badge(im)
    else:
        processed = process_silhouette(im)
        
    # Resize with high quality Lanczos resampling
    resized = processed.resize((size, size), Image.Resampling.LANCZOS)
    resized.save(output_path, 'PNG')
    print(f"Generated {output_path} at size {size}x{size}")

if __name__ == '__main__':
    main()
