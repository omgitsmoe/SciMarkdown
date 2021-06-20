@echo off
call python -c "print('\n' * 10*1000000)" > many-blanks.md
call python -c "print('foo\n\n' * 1000000)" > many-paragraphs.md
call python -c "print('###### foo\n' * 1000000)" > many-atx-headers.md
call python -c "print('```\nfoo\n```\n\n' * 1000000)" > many-fenced-code-blocks.md
call python -c "print('foo ' * 10*1000000)" > long-block-oneline.md
call python -c "print('foo\n' * 1000000)" > long-block-multiline.md
call python -c "print('*foo* ' * 1000000)" > many-emphasis.md
call python -c "print('[a](/url) ' * 1000000)" > many-links.md
call python -c "print('- foo\n' * 1000000)" > long-list.md
call python -c "print('- foo\n  - a\n  - b\n' * 1000000)" > long-list-with-sublists.md
call python -c "print('foo\n\n- foo\n\n' * 1000000)" > many-lists.md
