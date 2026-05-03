#!/usr/bin/env python3
import argparse
import os
import sys
import urllib.parse

from lxml import html


RESOURCE_RELS = {
    'stylesheet',
    'icon',
    'shortcut icon',
    'apple-touch-icon',
}


def is_external(url):
    parsed = urllib.parse.urlparse(url)
    return bool(parsed.scheme or parsed.netloc)


def check_attr(root, html_file, attr, value):
    if not value or value.startswith(('#', 'mailto:', 'javascript:', 'data:')):
        return None
    if is_external(value):
        return None

    parsed = urllib.parse.urlparse(value)
    if not parsed.path:
        return None

    decoded = urllib.parse.unquote(parsed.path)
    target = os.path.normpath(os.path.join(os.path.dirname(html_file), decoded))
    if os.path.exists(target):
        return None
    return html_file, attr, value, os.path.relpath(target, root)


def should_check_href(element):
    if element.tag == 'link':
        rel = (element.get('rel') or '').strip().lower()
        return rel in RESOURCE_RELS
    return False


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('root')
    args = parser.parse_args()

    root = os.path.abspath(args.root)
    missing = []

    for dirpath, _, filenames in os.walk(root):
        for filename in filenames:
            if not filename.endswith('.html'):
                continue
            html_file = os.path.join(dirpath, filename)
            doc = html.parse(html_file)
            for element in doc.iter():
                if element.get('src') is not None:
                    item = check_attr(root, html_file, 'src', element.get('src'))
                    if item:
                        missing.append(item)
                if element.get('href') is not None and should_check_href(element):
                    item = check_attr(root, html_file, 'href', element.get('href'))
                    if item:
                        missing.append(item)

    for html_file, attr, value, target in missing[:200]:
        print('{}: missing {}={!r} -> {}'.format(
            os.path.relpath(html_file, root), attr, value, target))
    if len(missing) > 200:
        print('... {} more missing resources'.format(len(missing) - 200))
    return 1 if missing else 0


if __name__ == '__main__':
    sys.exit(main())
