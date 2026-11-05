"""The seed (scripts/seed/seed.mjs, plan I12), which fills staging after a
reset, reads in the web app like anything a person sent: profile and group
pictures, direct texts with an edit, replies and reactions, a pic waiting,
a pending friend request, and both groups with their messages, reactions, and
a group pic. Runs the seed with this run's own tag on every username. Against
staging it's skipped: scripts/reset-staging.sh seeds staging itself.
Settings come from the environment; see common.py."""
import asyncio, os, re, subprocess, uuid
from playwright.async_api import async_playwright, expect

from common import BASE, INVITE, PHONE, REMOTE, launch, no_placeholders, open_page, row, shot, sign_in

tag = uuid.uuid4().hex[:4]
ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..")
MAYA, PRIYA, BEN = f"maya.lin_{tag}", f"priya.shah_{tag}", f"ben.hart_{tag}"
errors = []


def exact(name):
    return re.compile(f"^{re.escape(name)}$")


async def no_undecryptable(page):
    await expect(page.locator("#messages .msg.undecryptable")).to_have_count(0)


async def view_waiting_pic(page, chat, caption):
    """A tap on the row shows the waiting pic (X41): it decrypts, with its caption."""
    await row(page, exact(chat)).locator(".chat-item").click()
    await expect(page.locator("#viewer")).to_be_visible(timeout=10000)
    await expect(page.locator("#viewer-caption")).to_have_text(caption, timeout=10000)
    await expect(page.locator("#viewer-image")).to_have_js_property("complete", True)
    assert await page.locator("#viewer-image").evaluate("i => i.naturalWidth") == 720
    await shot(page, f"seed-pic-{chat.split()[0].lower()}", full_page=False)
    await asyncio.sleep(0.7)  # a tap right as a pic appears is ignored (TAP_GUARD_MS)
    await page.locator("#viewer").click()
    await expect(page.locator("#viewer")).to_be_hidden()


async def main():
    if REMOTE:
        print("skipped: scripts/reset-staging.sh seeds staging itself")
        return
    seed = subprocess.run(["node", os.path.join(ROOT, "scripts", "seed", "seed.mjs"), "--url", BASE, "--tag", tag],
                          env={**os.environ, "NAPSACK_INVITE": INVITE}, capture_output=True, text=True)
    print(seed.stdout.strip())
    assert seed.returncode == 0, seed.stderr
    # A second run stops at the first account that exists, writing nothing.
    again = subprocess.run(["node", os.path.join(ROOT, "scripts", "seed", "seed.mjs"), "--url", BASE, "--tag", tag],
                           env={**os.environ, "NAPSACK_INVITE": INVITE}, capture_output=True, text=True)
    assert again.returncode == 1 and "already exists" in again.stderr, again

    async with async_playwright() as pw:
        browser = await launch(pw)
        maya = await open_page(browser, errors=errors, label="maya")
        await sign_in(maya, MAYA)

        # Her friends, by their display names (Theo by her nickname for him), with pictures.
        for name in ("T", "Priya Shah", "Sam Okafor", "Saturday hike"):
            await expect(row(maya, exact(name)).locator(".avatar img")).to_have_count(1, timeout=10000)
        await no_placeholders(maya, "#chat-list")
        await shot(maya, "seed-list", full_page=False)

        # Theo's pic waits for her, and opens; then the chat: the edited text, a reply, reactions.
        await view_waiting_pic(maya, "T", "from the pier, no filter")
        await row(maya, exact("T")).locator(".chat-item").click()
        await expect(maya.locator(".msg", has_text="what time are we leaving")).to_be_visible(timeout=10000)
        await expect(maya.locator(".msg", has_text="what time are we leaving").locator(".edited-mark")).to_be_visible()
        await expect(maya.locator(".msg", has_text="day thing. we're old").locator(".quote")).to_contain_text("big tent")
        await expect(maya.locator("#messages .reaction", has_text="\U0001F602")).to_be_visible()
        await no_undecryptable(maya)

        await row(maya, exact("Priya Shah")).locator(".chat-item").click()
        await expect(maya.locator(".msg", has_text="PRIYA")).to_be_visible(timeout=10000)
        await expect(maya.locator("#messages .reaction", has_text="❤️").first).to_be_visible()
        await no_undecryptable(maya)

        # The group: its pic opens, then its messages, from everyone, with reactions.
        await view_waiting_pic(maya, "Saturday hike", "the view from last time, to motivate you")
        await row(maya, exact("Saturday hike")).locator(".chat-item").click()
        await expect(maya.locator(".msg", has_text="see everyone at 8!")).to_be_visible(timeout=10000)
        await expect(maya.locator(".msg", has_text="a bench is basically a café")).to_be_visible()
        await expect(maya.locator("#messages .reaction", has_text="\U0001F602").first).to_be_visible()
        await no_undecryptable(maya)
        await no_placeholders(maya, "#messages")
        await shot(maya, "seed-group")

        # On a phone: Priya has Ben's request waiting, and her book club.
        priya = await open_page(browser, errors=errors, label="priya", **PHONE)
        await sign_in(priya, PRIYA)
        await priya.click("#friends-button")
        await expect(priya.locator("#incoming-list li", has_text=BEN)).to_be_visible(timeout=10000)
        await priya.click("#friends-dialog [data-close]")
        await row(priya, exact("Book club")).locator(".chat-item").tap()
        await expect(priya.locator(".msg", has_text="see you all the 22nd")).to_be_visible(timeout=10000)
        await no_undecryptable(priya)
        await shot(priya, "seed-book-club-phone", full_page=False)

        await browser.close()
    assert not errors, errors
    print("seeded data reads in the web app: pictures, texts, edits, replies, reactions, pics, groups")


asyncio.run(main())
