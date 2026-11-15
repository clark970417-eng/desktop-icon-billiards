"""Small display-only Markdown subset; no HTML, images or executable content."""
import re

INLINE = re.compile(r'(`[^`\n]+`|\*\*[^*\n]+\*\*)')


def note_blocks(text):
    """Return (block style, [(text, inline style)]) values for native Text tags."""
    blocks = []
    for line in text.splitlines():
        line = line.strip()
        kind = 'body'
        if not line:
            blocks.append(('space', [('\n', '')]))
            continue
        heading = re.match(r'^(#{1,3})\s+(.+)$', line)
        bullet = re.match(r'^[-*+]\s+(.+)$', line)
        numbered = re.match(r'^(\d+[.)])\s+(.+)$', line)
        if heading:
            kind, line = 'heading', heading[2]
        elif bullet:
            kind, line = 'list', '•  ' + bullet[1]
        elif numbered:
            kind, line = 'list', numbered[1] + '  ' + numbered[2]
        elif line.startswith('> '):
            kind, line = 'quote', line[2:]
        spans = []
        for part in INLINE.split(line):
            if part.startswith('`') and part.endswith('`') and len(part) > 2:
                spans.append((part[1:-1], 'code'))
            elif part.startswith('**') and part.endswith('**') and len(part) > 4:
                spans.append((part[2:-2], 'bold'))
            elif part:
                spans.append((part, ''))
        blocks.append((kind, spans))
    return blocks
