#!/usr/bin/env bash
# Screenshot a page of the rendered docs site (docs/_site), to check a visual
# change rather than guess at it. Adapted from blog.kolen.dev's bin/screenshot.sh.
#
#   scripts/screenshot.sh <path-under-_site> <out.png>
#
# Examples:
#   scripts/screenshot.sh index.html /tmp/home.png
#   SCREENSHOT_THEME=dark scripts/screenshot.sh guide/philosophy.html /tmp/p.png
#   SCREENSHOT_SECTION=architecture scripts/screenshot.sh design.html /tmp/a.png
#
# SCREENSHOT_THEME (light or dark, default light) is the colour scheme the page
# sees, which the site follows; a dark shot is checked to have come out dark.
# SCREENSHOT_SIZE is the window, default 1400,1400.
# SCREENSHOT_SECTION shoots a copy of the page holding only the <section> with
# that id, under the page title. Scrolling to a #fragment does not work: the
# headless shell captures a blank page.
#
# Requires a headless browser, installed once per machine with:
#   quarto install chrome-headless-shell
# It lands in ~/.local/share/quarto/; nothing is added to this repo.
#
# Render before shooting: `pixi run build`.
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SITE="${REPO}/docs/_site"
CHS="${CHROME_HEADLESS_SHELL:-${HOME}/.local/share/quarto/chrome-headless-shell/chrome-headless-shell-linux64/chrome-headless-shell}"
PORT="${SCREENSHOT_PORT:-21577}"
SIZE="${SCREENSHOT_SIZE:-1400,1400}"
THEME="${SCREENSHOT_THEME:-light}"
SECTION="${SCREENSHOT_SECTION:-}"

if [[ $# -lt 2 ]]; then
	sed -n '2,23p' "${BASH_SOURCE[0]}"
	exit 64
fi

case "${THEME}" in
light) scheme=1 ;;
dark) scheme=0 ;;
*)
	echo "SCREENSHOT_THEME is light or dark, not ${THEME}" >&2
	exit 64
	;;
esac

path="${1}"
out="${2}"

if [[ ! -x ${CHS} ]]; then
	echo "no headless browser at ${CHS}" >&2
	echo "install it with: quarto install chrome-headless-shell" >&2
	exit 1
fi
if [[ ! -f ${SITE}/${path} ]]; then
	echo "${SITE}/${path} does not exist; run 'pixi run build' first" >&2
	exit 1
fi

# The cut-down copy sits next to the page, so its relative links still resolve.
if [[ -n ${SECTION} ]]; then
	copy="$(dirname "${path}")/.screenshot-$$.html"
	trap 'rm -f "${SITE}/${copy}"' EXIT
	python3 - "${SITE}/${path}" "${SITE}/${copy}" "${SECTION}" <<'PY'
import re, sys
page, copy, section = sys.argv[1:]
s = open(page, encoding="utf-8").read()
start = s.find(f'<section id="{section}"')
if start < 0:
    sys.exit(f"no section {section} in {page}")
# Cut from the first section of the body to the chosen one, and after the
# chosen one's sibling, so the title and the page chrome stay.
level = re.match(r'<section id="[^"]*" class="level(\d)', s[start:]).group(1)
first = s.find('<section id="', s.find("<main"))
end = s.find(f'class="level{level}"', s.find(">", start))
end = s.rfind("<section", start, end) if end >= 0 else s.find("</main>")
open(copy, "w", encoding="utf-8").write(s[:first] + s[start:end] + s[s.find("</main>"):])
PY
	path="${copy}"
fi

# Serve over HTTP rather than file://, where Quarto keeps the colour scheme
# toggle in memory instead of localStorage. Fully detach the server (own
# session, all three fds closed); otherwise it holds this script's stdout open.
if ! curl -fsS -o /dev/null "http://127.0.0.1:${PORT}/" 2>/dev/null; then
	(cd "${SITE}" && setsid python3 -m http.server "${PORT}" </dev/null >/dev/null 2>&1 &)
	sleep 1.5
fi

# The colour scheme is set with preferredColorScheme alone: --force-dark-mode,
# the obvious flag, leaves the site light every time.
shoot() {
	timeout 40 "${CHS}" \
		--headless \
		--disable-gpu \
		--no-sandbox \
		--hide-scrollbars \
		--window-size="${SIZE}" \
		--blink-settings=preferredColorScheme="${scheme}" \
		--virtual-time-budget=8000 \
		--user-data-dir="$(mktemp -d)" \
		"$@" \
		"http://127.0.0.1:${PORT}/${path}"
}

shoot --screenshot="${out}" 2>&1 |
	grep -viE 'devtools|bytes written|Fontconfig|CONSOLE|:WARNING:' || true

# Quarto marks the theme it chose on <body>.
if [[ ${THEME} == dark ]]; then
	dom="$(shoot --dump-dom 2>/dev/null)"
	if ! grep -q '<body[^>]*quarto-dark' <<<"${dom}"; then
		echo "asked for dark, but the page rendered light: ${out} is not a dark shot" >&2
		exit 1
	fi
fi

echo "wrote ${out}"
