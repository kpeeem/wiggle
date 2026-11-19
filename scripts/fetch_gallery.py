import json
import sys
import time
import urllib.parse
import urllib.request
from pathlib import Path

cards = {
    "cauldron": "Cooking eggs at the Witches' Cauldron, by Muybridge, Eadweard, 1830-1904.jpg",
    "echo": "Echo Lake, North Conway, N.H, by Soule, John P., 1827-1904.jpg",
    "diana": "Diana's Baths, North Conway, N.H, by Soule, John P., 1827-1904.jpg",
    "bennu": "Bennu's Boulder No.1 Stereo Pair (Stereoscope Version).jpg",
    "edinburgh": "Edinburgh Shandwick H09439.jpg",
    "bridge": "Tay Road Bridge parallel-view 3D.jpg",
}
agent = {"User-Agent": "WiggleDemo/0.1 (https://github.com/kpeeem/wiggle) python-urllib"}
root = Path(sys.argv[1] if len(sys.argv) > 1 else "data/web")
query = urllib.parse.urlencode({
    "action": "query", "titles": "|".join("File:" + title for title in cards.values()),
    "prop": "imageinfo", "iiprop": "url", "format": "json"})
with urllib.request.urlopen(urllib.request.Request("https://commons.wikimedia.org/w/api.php?" + query, headers=agent), timeout=120) as response:
    pages = json.load(response)["query"]["pages"].values()
urls = {page["title"][5:]: page["imageinfo"][0]["url"] for page in pages}
for name, title in cards.items():
    target = root / name / "card.jpg"
    target.parent.mkdir(parents=True, exist_ok=True)
    for attempt in range(5):
        if target.exists() and target.stat().st_size > 10000:
            break
        try:
            with urllib.request.urlopen(urllib.request.Request(urls[title], headers=agent), timeout=120) as response:
                target.write_bytes(response.read())
        except OSError as error:
            print(name, error, file=sys.stderr)
            time.sleep(15 * (attempt + 1))
    print(name, target.stat().st_size // 1024, "KB")
    time.sleep(3)
