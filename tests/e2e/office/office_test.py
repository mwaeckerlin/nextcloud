"""Office in a real browser: opens a document in Collabora through Nextcloud,
types a text, saves it, and reads the saved file back over WebDAV.

The browser runs in the network of the host and opens Nextcloud under the
address a user types (NC_URL, e.g. http://localhost:8824/nextcloud), so the
public WOPI URL, the Collabora iframe and its WebSocket /cool/.../ws all go
through nginx the way they do for a user.

Environment: NC_URL, NC_USER, NC_PASSWORD, FILE_ID, DAV_URL (the document).
"""

import base64
import io
import os
import sys
import time
import urllib.request
import zipfile

from playwright.sync_api import sync_playwright

NC_URL = os.environ['NC_URL'].rstrip('/')
USER = os.environ['NC_USER']
PASSWORD = os.environ['NC_PASSWORD']
FILE_ID = os.environ['FILE_ID']
DAV_URL = os.environ['DAV_URL']
TEXT = f'Office e2e {int(time.time())}'
SCREENSHOT = '/tmp/office-failure.png'


def fail(page, reason):
    page.screenshot(path=SCREENSHOT, full_page=True)
    print(f'office: {reason}', file=sys.stderr)
    sys.exit(1)


def saved_text():
    """Text of content.xml in the document as WebDAV delivers it now."""
    auth = base64.b64encode(f'{USER}:{PASSWORD}'.encode()).decode()
    request = urllib.request.Request(DAV_URL, headers={'Authorization': f'Basic {auth}'})
    data = urllib.request.urlopen(request, timeout=20).read()
    if not data.startswith(b'PK'):
        return ''
    return zipfile.ZipFile(io.BytesIO(data)).read('content.xml').decode('utf-8', 'replace')


with sync_playwright() as playwright:
    browser = playwright.chromium.launch()
    page = browser.new_page(viewport={'width': 1400, 'height': 900})

    page.goto(f'{NC_URL}/index.php/login', wait_until='domcontentloaded', timeout=120_000)
    page.fill('input[name="user"]', USER)
    page.fill('input[name="password"]', PASSWORD)
    page.click('button[type="submit"]')
    page.wait_for_url(lambda url: '/login' not in url, timeout=60_000)

    # the page loads Collabora into an iframe, so its load event can take
    # long; the frame is awaited below
    try:
        page.goto(f'{NC_URL}/index.php/f/{FILE_ID}', wait_until='domcontentloaded', timeout=120_000)
    except Exception as error:
        fail(page, f'/f/{FILE_ID} delivered no page within 120s: {error}')
    deadline = time.time() + 120
    frame = None
    while frame is None and time.time() < deadline:
        frame = next((f for f in page.frames if '/browser/' in f.url and 'cool.html' in f.url), None)
        page.wait_for_timeout(1000)
    if frame is None:
        fail(page, 'no Collabora frame (cool.html) within 120s; frames: '
             + ', '.join(f.url for f in page.frames))

    # the document canvas appears once the WebSocket to Collabora is up and
    # the document is loaded
    try:
        canvas = frame.wait_for_selector('#document-canvas', state='visible', timeout=120_000)
    except Exception as error:
        fail(page, f'Collabora shows no document within 120s: {error}')
    # Collabora greets a first-time user with a welcome dialog over the
    # document; close it as the user would
    try:
        frame.wait_for_selector('.iframe-welcome-wrap', state='visible', timeout=15_000)
        page.keyboard.press('Escape')
        frame.wait_for_selector('.iframe-welcome-wrap', state='detached', timeout=5_000)
    except Exception:
        frame.evaluate("document.querySelectorAll('.iframe-welcome-wrap').forEach(e => e.remove())")
    # newer releases show an onboarding tour instead, whose overlay takes every
    # click on the document until the user presses «Skip»
    try:
        frame.click('#onboarding-skip-button', timeout=15_000)
        frame.wait_for_selector('#modal-dialog-onboarding-tour-overlay', state='detached', timeout=10_000)
    except Exception:
        pass
    page.wait_for_timeout(2000)
    canvas.click()
    page.keyboard.type(TEXT, delay=50)
    page.keyboard.press('Control+s')

    deadline = time.time() + 90
    while TEXT not in saved_text():
        if time.time() > deadline:
            fail(page, f'the saved document does not contain "{TEXT}" within 90s')
        page.wait_for_timeout(3000)

    print(f'office: Collabora opened, edited and saved the document: "{TEXT}"')
    browser.close()
