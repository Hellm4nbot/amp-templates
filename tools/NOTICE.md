# tools/7zr.exe

7-Zip console extractor (7zr), version 26.04, 602 624 bytes.

Shipped here because the Bannerlord Coop CDN fallback needs a 7z extractor inside the
AMP container image, which has neither `7z` nor `pip` nor `bsdtar`. Downloading it from
7-zip.org at update time was the first approach, but that domain's DNS returns SERVFAIL
(verified from both the host resolver and Google DoH), so the template now fetches it
from this repository first and falls back to 7-zip.org.

7-Zip is by Igor Pavlov, licensed under the GNU LGPL. See https://www.7-zip.org/license.txt
The binary is redistributed unmodified.
