## Headings

%% blocks that - contrary to vanilla markdown - require a leading blank line in pandoc's markdown:
%% heading, blockquote
%% TODO
# H1
## H2
### H3
#### H4
##### H5
###### H6

#### Headline / with # other + kinds tokens
#### __Fat head__ *cursive* [link](https://google.com)
%% ####Syntax error heading
%% empty headig -> syntax error
%%# 

%% Alternatively, for H1 and H2, an underline-ish style:
%% removed from this markdown style

%% Alt-H1
%% ======
%% 
%% Alt-H2
%% ------

## Paragraph

Lorem ipsum dolor sit amet, consetetur sadipscing elitr, sed diam
nonumy eirmod tempor invidunt ut.
Paragraphs end after two line breaks / a blank line, otherwise
the newline is just interpreted as a space.

%% markdown normally uses two spaces at the end of the line, but you can't see that
%% and might be stuck wondering about the weird wrapping behaviour
%% use pandoc's escaped_line_breaks extension instead
A backslash at the end of the line forces a line break \
Labore et dolore magna aliquyam erat, sed diam voluptua.

At vero eos et accusam et justo
duo dolores et ea rebum. Stet clita kasd gubergren.

Links spanning over a line break [link
wrapping lines](https://link-wrapping-lines.com) same for **emphasis
here**

## Text styles

Emphasis, aka italics, with *asterisks* or _underscores_.

Strong emphasis, aka bold, with **asterisks** or __underscores__.

Combined emphasis with **asterisks and _underscores_**.

%% Nested emphasis __must__ be alternated otherwise with **emphasis* and also emphasis* would
%% result in strong emphasis (** -> strong) that produces an error.
%% Contrary to markdown * and _ are always treated as emph characters and need to
%% be escaped if the literal character is needed
Normal text with\_underscore and aster\*sk

Strikethrough uses two tildes. ~~Scratch this.~~

H~2~O is a liquid.  2^10^ is 1024.

## Comments

%% This is a comment

This is a normal paragraph %% and this is a comment


## Lists

1. First ordered list item
   multi-line [link
   text wrap](https://google.com)
   but this will still be rendered on one line
2. Another item
   - Unordered sub-list.
   %% :[ref]: (test)
1. Actual numbers don't matter, just that it's a number
   continue
   1. Ordered sub-list
4. And another item.

   %% blank line above will make this a loose list -> every list item starts a paragraph
   You can have properly indented paragraphs within list items. Notice the blank line above, and the leading spaces (at least one, but we'll use three here to also align the raw Markdown).

   To have a line break without a paragraph, you will need to end the line with a \
   Note that this line is separate, but within the same paragraph.  
   (This is contrary to the typical GFM line break behaviour, where trailing spaces are not required.)

%% uncommenting this will be an error since a blank line would now contain whitespace
%%     
   Should be sep paragraph

%% asterisk (\*) removed from list item starters
%% * Unordered list can use asterisks
- Or minuses
+ Or pluses
+ test

  test
- other
%% lists will continue with just one blank line between them if the list starters (here '-')
%% are the same! but this will make them loose! each list item text starts a paragraph

- No indent
  - First indent
    - Second indent
- Dropping two indents

## Blockquote

    """
    ## Headline inside blockquote

    Paragraph paragraph paragraph paragraph paragraph paragraph
    Paragraph paragraph paragraph paragraph paragraph paragraph

    Paragraph paragraph paragraph paragraph paragraph paragraph

    - List 1
        - Sublist 1
    - List 1 continue
    + List 2
    """

    """
    Blockquotes are very handy in email to emulate reply text.
    This line is part of the same quote.
    """

Quote break.

    """
    This is a very long line that will still be quoted properly when it wraps. Oh boy let's keep writing to make sure this is long enough to actually wrap for everyone. Oh, you can *put* **Markdown** into a blockquote. 
    """


## Links and Refs


[I'm an inline-style link](https://www.google.com)

[I'm an inline-style link with title](https://www.google.com "Google's Homepage")

%% reference labels are case-sensitive contrary to regular markdown
[I'm a reference-style link][Arbitrary case-insensitive reference text]

[I'm a relative reference to a repository file](../blob/master/LICENSE)

[You can use numbers for reference-style link definitions][1]

Or leave it empty and use the [link text itself].

%% removed in this markdown style
%% URLs and URLs in angle brackets will automatically get turned into links. 
%% http://www.example.com or <http://www.example.com> and sometimes 
%% example.com (but not on Github, for example).

Some text to show that the reference links can follow later.

%% reference definitions have to start with :[ as opposed to just [ to avoid ambiguity with
%% inline links, otherwise we'd have to try parsing it and then backtrack
%% (since the first bracket for links needs to be parsed as inline (with emph, code span etc.)
%%  instead of just as pure text)
:[Arbitrary case-insensitive reference text]: (https://www.mozilla.org)
:[1]: (http://slashdot.org)
:[link text itself]: (http://www.reddit.com "Link title")


## Images

Here's our logo (hover to see the title text):

Inline-style: 
![alt text](https://github.com/adam-p/markdown-here/raw/master/src/common/images/icon48.png "Logo Title Text 1")

Reference-style: 
![alt text][logo]

:[logo]: (https://github.com/adam-p/markdown-here/raw/master/src/common/images/icon48.png "Logo Title Text 2")


## Code

Inline `code` has `back-ticks around` it.

If a code span would contain a back-tick you can use two back-ticks instead:
``code with ` can't end on `! ``

```javascript
var s = "JavaScript syntax highlighting";
alert(s);
```

```python
s = "Python syntax highlighting"
if s == "":
    if len(s.split()) > 3:
        print(s)
else:
    print(s)
```

```python
import matplotlib.pyplot as plt
plt.plot([1, 2, 3, 4])
plt.ylabel('some numbers')
# will just show the interactive window but won't automatically save the output
# like you may be used to with e.g. jupyter notebook
# plt.show()
# using plt.savefig etc. is preferred here, since better formats that are more
# suitable for publishing can be used etc.
print("second print")
```

```
%% same comment token as we have
No language indicated, so no syntax highlighting. 
But let's throw in a <b>tag</b>.
%% test that indents get printed
if s == "":
    if len(s.split()) > 3:
        print s
```


## Math

 When $a \ne 0$, there are two solutions to $ax^2 + bx + c = 0$ and they are:
 $$ x = {-b \pm \sqrt{b^2-4ac} \over 2a}. $$

 Digits that immediately follow a \$ sign will not start an inline math span
 so prices like $50 etc. don't have to be escaped!


## Tables

Colons can be used to align columns.

| Tables        | Are           | Cool  |
| ------------- |:-------------:| -----:|
| col 3 is      | right-aligned | \$1600 |
| col 2 is      | centered      |   \$12 |
| zebra stripes | are neat      |    \$1 |

There must be at least 3 dashes separating each header cell.
The outer pipes (|) are mandatory, and you don't need to make the 
raw Markdown line up prettily. You can also use inline Markdown.

%% require table rows to start with | so there's no ambiguity between table rows and thematic breaks
%% also require closing table cells with |?
| Markdown | Less | Pretty
| --- | --- | ---
| *Still* | `renders` | **nicely**
| 1 | 2 | 3


**Inline HTML removed in this markdown style!**


## Horizontal rule

%% only hyphens (compared to CommonMark: * - \_) can start a thematic break
Three or more hyphens

---

%% \*\*\*

%% Asterisks

%% \_\_\_

%% Underscores


## Line breaks

Here's a line for us to start with.

This line is separated from the one above by two newlines, so it will be a *separate paragraph*.

This line is also a separate paragraph, but...
This line is only separated by a single newline or space, so it's a separate line in the *same paragraph*.


## Citations

%% Markdown citations go inside square brackets and are separated by semicolons. Each citation must
%% have a key, composed of ‘@’ + the citation identifier from the database, and may optionally have a
%% prefix, a locator, and a suffix.
%% pandoc comparison:
%% Blah blah [see @doe99, pp. 33-35; also @smith04, chap. 1].
%% 
%% Blah blah [@doe99, pp. 33-35, 38-39 and *passim*].
%% 
%% Blah blah [@smith04; @doe99].
%% 
%% Omit author name: Smith says blah [-@smith04].
%% 
%% In-text citation: @smith04 says blah.
%%
%% With locator: @smith04 [p. 33] says blah.
%% Blah blah @cite(doe99, pre=see, loc=pp. 33-35, post=and *passim* & smith04, pre=also, loc=chap. 1)

%% cite only for one citation?
%% Blah blah @cites(@cite(doe99, pre=see, loc=pp. 33-35, post=and *passim*),
%% @cite(smith04, pre=also, loc=chap. 1))

Blah blah @cites(@cite(abc99,   loc    =    pp. 33-35), @cite(smith04))

Blah blah @cite(doe99, loc=pp. 33-35\, 38-39 and *passim*).

%% Blah blah @cite(smith04 & doe99).

Omit author name: Smith says blah @cite(-smith04).

In-text citation: @textcite(doe99) says blah.

With locator: @textcite(smith04, loc=p. 33) says blah.
%% error due to postional arg after kwarg: @textcite(smith04, loc=p. 33, error)
