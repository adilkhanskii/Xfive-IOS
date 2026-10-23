"""Pick the 7 most recent X5 marketplace screenshots from the inbox,
upscale each to App Store 6.9" (1290x2796), drop them into
fastlane/screenshots/en-US/ as iPhone 6.9 - N.png, and remove all
caption-studio leftovers from the same folder.

Source dimension: 1179x2556 (iPhone 15/16 Pro). Aspect ratio matches
1290x2796 within 0.03% so a single Lanczos upscale is clean.
"""
from pathlib import Path
from PIL import Image
import shutil

INBOX = Path(r"C:\Projects\clients\adilkhan\x5\.scripts\screens_inbox")
TARGET = Path(r"C:\Projects\clients\adilkhan\x5\fastlane\screenshots\en-US")
TARGET_SIZE = (1290, 2796)
TARGET_PHONE_SLOT = "iPhone 6.9"

# Keep only the latest batch — 7 PNGs from message ids 35928..35934 captured
# at 09:43:59 today are the X5 marketplace shots Diaz mentioned.
WANTED = [
    "20260504-094359_35928.png",
    "20260504-094359_35929.png",
    "20260504-094359_35930.png",
    "20260504-094359_35931.png",
    "20260504-094359_35932.png",
    "20260504-094359_35933.png",
    "20260504-094359_35934.png",
]


def main():
    TARGET.mkdir(parents=True, exist_ok=True)

    # Wipe stale caption-studio shots before staging the new ones.
    removed = 0
    for f in sorted(TARGET.iterdir()):
        if f.is_file() and f.suffix.lower() == ".png":
            f.unlink()
            removed += 1
    print(f"Removed {removed} stale screenshots from {TARGET}")

    for idx, src_name in enumerate(WANTED, start=1):
        src = INBOX / src_name
        if not src.exists():
            print(f"MISSING in inbox: {src_name}")
            continue
        img = Image.open(src).convert("RGB")
        if img.size != TARGET_SIZE:
            img = img.resize(TARGET_SIZE, Image.LANCZOS)
        out = TARGET / f"{TARGET_PHONE_SLOT} - {idx}.png"
        img.save(out, format="PNG", optimize=True)
        print(f"  -> {out.name}: {img.size[0]}x{img.size[1]}, "
              f"{out.stat().st_size} bytes")

    print(f"\nReady: {len(WANTED)} screenshots staged in {TARGET}")


if __name__ == "__main__":
    main()
