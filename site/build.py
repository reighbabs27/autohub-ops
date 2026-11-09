#!/usr/bin/env python3
"""Builds the GitHub Pages site into ../docs from the page bodies in pages/*.html.
Each body file starts with a line  <!-- title: Page title -->  ; the shared header/nav/footer is added here.
Run:  python3 site/build.py
"""
import pathlib, re

ROOT = pathlib.Path(__file__).resolve().parent
OUT = ROOT.parent / "docs"
NAV = [
    ("index.html", "Summary"),
    ("system.html", "System & card"),
    ("infrastructure.html", "Infrastructure"),
    ("baseline.html", "Baseline"),
    ("well-architected.html", "Well-Architected"),
    ("operations.html", "Monitoring · Backup · Security"),
    ("automation.html", "Automation & incident"),
    ("results.html", "Results"),
    ("next.html", "Next steps"),
    ("declaration.html", "Declaration"),
]

TEMPLATE = """<!doctype html>
<html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>{title} · AutoHub Assistant</title>
<link rel="icon" href="img/logo.svg"><link rel="stylesheet" href="style.css">
</head><body>
<header class="site"><div class="wrap">
<a class="logo" href="index.html"><img src="img/logo.svg" alt="">AutoHub Assistant</a>
<nav class="pages">{nav}</nav></div></header>
<main><div class="wrap">
{body}
</div></main>
<footer><div class="wrap">SAM10 Systems Administration and Maintenance — final project by Reighfer Joshua Bondoc.
AutoHub Assistant is a reskin of <a href="https://github.com/LibreChat-AI/LibreChat">LibreChat</a> (MIT licence, Danny Avila and contributors).
All dealership data is invented. Source: the <code>autohub-ops</code> repository.</div></footer>
<script>
document.querySelectorAll('img[data-shot]').forEach(function(img){{
  img.addEventListener('error',function(){{
    var d=document.createElement('div');d.className='shot-missing';
    d.textContent='Screenshot to add: docs/img/'+img.getAttribute('src').replace('img/','')+' — '+img.alt;
    img.replaceWith(d);}});
}});
</script>
</body></html>
"""

def main():
    OUT.mkdir(exist_ok=True)
    for f, label in NAV:
        src = (ROOT / "pages" / f).read_text()
        m = re.match(r"<!-- title: (.*?) -->\n", src)
        title = m.group(1) if m else label
        on = ' class="on"'
        nav = "".join('<a href="%s"%s>%s</a>' % (h, on if h == f else "", l) for h, l in NAV)
        (OUT / f).write_text(TEMPLATE.format(title=title, nav=nav, body=src[m.end() if m else 0:]))
        print("built", f)

if __name__ == "__main__":
    main()
