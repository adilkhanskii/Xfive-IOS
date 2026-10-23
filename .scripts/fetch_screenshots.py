"""Download recent image attachments from Telegram Saved Messages.

Diaz sent ~7 X5 marketplace screenshots to his own "Saved Messages" and
told the agent to grab them and pipe them into fastlane/screenshots.

Run: python fetch_screenshots.py [count]
"""
import asyncio
import os
import sys
import io
from pathlib import Path

sys.stdout = io.TextIOWrapper(sys.stdout.buffer, encoding="utf-8")
sys.stderr = io.TextIOWrapper(sys.stderr.buffer, encoding="utf-8")

from dotenv import load_dotenv
from telethon import TelegramClient

TG_DIR = Path(r"C:\Projects\personal\connections\telegram")
load_dotenv(TG_DIR / ".env")
API_ID = int(os.environ["TG_API_ID"])
API_HASH = os.environ["TG_API_HASH"]
SESSION = str(TG_DIR / "tuyakov")

OUT_DIR = Path(r"C:\Projects\clients\adilkhan\x5\.scripts\screens_inbox")
OUT_DIR.mkdir(parents=True, exist_ok=True)

LIMIT = int(sys.argv[1]) if len(sys.argv) > 1 else 12


async def main():
    async with TelegramClient(SESSION, API_ID, API_HASH) as client:
        if not await client.is_user_authorized():
            print("SESSION_EXPIRED")
            return
        msgs = await client.get_messages("me", limit=LIMIT)
        downloaded = []
        for m in msgs:
            if not m.photo and not (m.document and m.document.mime_type
                                    and m.document.mime_type.startswith("image/")):
                continue
            ext = ".png"
            if m.document and m.document.mime_type:
                if "jpeg" in m.document.mime_type:
                    ext = ".jpg"
                elif "heic" in m.document.mime_type:
                    ext = ".heic"
            ts = m.date.strftime("%Y%m%d-%H%M%S")
            target = OUT_DIR / f"{ts}_{m.id}{ext}"
            await client.download_media(m, file=str(target))
            size = target.stat().st_size if target.exists() else 0
            downloaded.append((target.name, size, m.date.isoformat()))
            print(f"got {target.name} ({size} bytes, {m.date})")
        print(f"\nTotal downloaded: {len(downloaded)}")
        for name, size, date in downloaded:
            print(f"  {date} | {name} | {size}")


if __name__ == "__main__":
    asyncio.run(main())
