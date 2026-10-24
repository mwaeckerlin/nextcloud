# Browser for the office test. The Playwright image brings the system
# libraries of the browsers; its Python library is removed after the image
# build, so this image installs the library and the Chromium that fits it.
FROM mcr.microsoft.com/playwright/python:latest
RUN pip install --no-cache-dir playwright
RUN playwright install chromium
COPY --chown=pwuser:pwuser office_test.py /work/office_test.py
COPY --chown=pwuser:pwuser admin_pages_test.py /work/admin_pages_test.py
WORKDIR /work
USER pwuser
ENTRYPOINT ["python3", "/work/office_test.py"]
