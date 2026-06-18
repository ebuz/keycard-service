#!/usr/bin/env python3
"""
Keycard Service: Discord Alert Integration
Runs under the keycard user. Connects to the same Discord bot token used by
BlackbeardBot (or a dedicated webhook) to post alerts to a designated channel.

Usage:
    python3 discord_alert.py <service_name> <exit_code> [<message>]

Configuration:
    DISCORD_ALERT_WEBHOOK    -- webhook URL (preferred, no bot token needed)
    DISCORD_BOT_TOKEN          -- if webhook unavailable, post via bot user
    DISCORD_ALERT_CHANNEL_ID   -- channel ID for bot-based posts
"""

import os
import sys
import asyncio

WEBHOOK = os.getenv("DISCORD_ALERT_WEBHOOK", "").strip()
BOT_TOKEN = os.getenv("DISCORD_BOT_TOKEN", "").strip()
CHANNEL_ID = os.getenv("DISCORD_ALERT_CHANNEL_ID", "").strip()

SERVICE = sys.argv[1] if len(sys.argv) > 1 else "unknown"
EXIT_CODE = sys.argv[2] if len(sys.argv) > 2 else "unknown"
MESSAGE = sys.argv[3] if len(sys.argv) > 3 else f"Service {SERVICE} failed with exit code {EXIT_CODE}"

TEXT = f"[keycard-service] {SERVICE}: {MESSAGE}"


def send_webhook() -> bool:
    import json
    import urllib.request
    import urllib.error

    if not WEBHOOK:
        return False

    payload = json.dumps({"content": TEXT}).encode("utf-8")
    req = urllib.request.Request(
        WEBHOOK,
        data=payload,
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    try:
        with urllib.request.urlopen(req, timeout=15) as resp:
            return resp.status in (200, 204)
    except urllib.error.HTTPError as e:
        print(f"Discord webhook failed: HTTP {e.code}", file=sys.stderr)
        return False
    except Exception as e:
        print(f"Discord webhook failed: {e}", file=sys.stderr)
        return False


async def send_bot() -> bool:
    try:
        import discord
    except ImportError:
        print("discord.py not installed; cannot use bot alerting", file=sys.stderr)
        return False

    if not BOT_TOKEN or not CHANNEL_ID:
        return False

    intents = discord.Intents.default()
    client = discord.Client(intents=intents)
    sent = False

    @client.event
    async def on_ready():
        nonlocal sent
        channel = client.get_channel(int(CHANNEL_ID))
        if channel is None:
            print(f"Discord channel {CHANNEL_ID} not found", file=sys.stderr)
        else:
            try:
                await channel.send(TEXT)
                sent = True
            except discord.Forbidden:
                print("Discord: forbidden to post in channel", file=sys.stderr)
            except discord.HTTPException as e:
                print(f"Discord HTTP error: {e}", file=sys.stderr)
        await client.close()

    try:
        await client.start(BOT_TOKEN)
    except Exception as e:
        print(f"Discord bot login failed: {e}", file=sys.stderr)
        return False

    return sent


def main() -> int:
    if send_webhook():
        print("Alert sent via Discord webhook")
        return 0

    if BOT_TOKEN and CHANNEL_ID:
        ok = asyncio.run(send_bot())
        if ok:
            print("Alert sent via Discord bot")
            return 0

    print("No Discord alerting configured or all methods failed")
    return 1


if __name__ == "__main__":
    sys.exit(main())
