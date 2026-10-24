"""The administration pages in a real browser: every warning and error a page
shows the administrator, as a note card or as a toast, fails the test.

The browser runs in the network of the host and opens Nextcloud under the
address a user types (NC_URL), logs in as admin and opens each page of PAGES.
A page counts once its content stays the same for five seconds, because the
pages load their checks after the first paint.

Environment: NC_URL, NC_USER, NC_PASSWORD, ALLOWED (texts, separated by «|»,
that may appear because the README lists them as work of the administrator).
"""

import os
import sys
import time

from playwright.sync_api import sync_playwright

NC_URL = os.environ['NC_URL'].rstrip('/')
USER = os.environ['NC_USER']
PASSWORD = os.environ['NC_PASSWORD']
ALLOWED = [text for text in os.environ.get('ALLOWED', '').split('|') if text]
SCREENSHOT = '/tmp/admin-pages-failure.png'

# section of Administration settings => what it shows
PAGES = {
    'overview': 'setup checks, version, integrity',
    'server': 'background jobs, mail server',
    'richdocuments': 'Nextcloud Office: Collabora reachable, WOPI allowlist',
    'talk': 'Talk: signaling server',
    'logging': 'log reader',
}

# warnings and errors as Nextcloud shows them: note cards of @nextcloud/vue in
# both class forms, toasts of @nextcloud/dialogs, and the setup checks of the
# overview
FINDINGS = """() => [...document.querySelectorAll(
    '.notecard--warning, .notecard--error, .notecard.warning, .notecard.error,'
    + ' .toast-error, .toast-warning, .toastify.toast-error,'
    + ' #security-warning li.error, #security-warning li.warning, .setup-check--error, .setup-check--warning'
  )].filter(e => e.offsetParent !== null).map(e => e.innerText.replace(/\\s+/g, ' ').trim()).filter(t => t)"""


def settled(page):
    """Waits until the text of the page stays the same for five seconds."""
    last, since = None, time.time()
    deadline = time.time() + 90
    while time.time() < deadline:
        text = page.evaluate('() => document.body.innerText')
        if text != last:
            last, since = text, time.time()
        elif time.time() - since >= 5:
            return
        page.wait_for_timeout(1000)


with sync_playwright() as playwright:
    browser = playwright.chromium.launch()
    page = browser.new_page(viewport={'width': 1400, 'height': 900})
    page.goto(f'{NC_URL}/index.php/login', wait_until='domcontentloaded', timeout=120_000)
    page.fill('input[name="user"]', USER)
    page.fill('input[name="password"]', PASSWORD)
    page.click('button[type="submit"]')
    page.wait_for_url(lambda url: '/login' not in url, timeout=60_000)

    reported = []
    for section, content in PAGES.items():
        response = page.goto(f'{NC_URL}/index.php/settings/admin/{section}', wait_until='domcontentloaded', timeout=120_000)
        if response is None or response.status != 200:
            reported.append(f'{section}: the page answers {response.status if response else "nothing"}')
            continue
        settled(page)
        for text in page.evaluate(FINDINGS):
            if not any(allowed in text for allowed in ALLOWED):
                reported.append(f'{section} ({content}): {text}')
        print(f'admin pages: {section} checked')

    if reported:
        page.screenshot(path=SCREENSHOT, full_page=True)
        print('admin pages report:\n' + '\n'.join(reported), file=sys.stderr)
        sys.exit(1)
    print('admin pages: no warning and no error')
    browser.close()
