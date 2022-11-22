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

This is a normal paragraph, nothing to see here! %% and this is a comment


## Lists

1. First ordered list item
   multi-line [link
   text wrap](https://google.com)
   but this will still be rendered on one line
2. Another item
   - Unordered sub-list.
1. Actual numbers don't matter, just that it's a number
   continue
   %% remember that SciMarkdown enforces at least one space after a list item starter
   %% but beyond that it can be arbitrarily aligned, so the line below will only continue
   %% if it also is on the same column as the first non-whitespace character
   12.    But the first number of an ordered list determines the start number!
          Line continues
   123.   Should be 13.
          Line continues
   34659. Should be 14.
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

- continued list, which is now loose and will have all items rendered inside a paragraph


- No indent
  - First indent
    - Second indent
- Dropping two indents

1. ordered
a. Ordered lists can also be started with a single letter of a-z or A-Z
b. next
A. Other list
   A. Other sublist
d) Another
  - test
    test
- other kind
a. blabla


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
@label(first-python-code-block)

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

%% uncomment python code below to see the traceback being properly output
%% on the command line
```python
# a = 5 + 'a'
```

%% same for R
```r
# d <- function(x) { x + 'a' }
# f <- function(x) { d(x) }
# a = f(5)
```

Python inline: >`py print("printed from within python")`

```r
print("r test")
write("stderr r test", stderr())
```

```r
print("other chunk")
print(5 * 25)
```

R inline: >`r cat("printed from within R")`

R inline with print: >`r print("printed from within R")`

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
 $$
 @label(eq:1)
 x = {-b \pm \sqrt{b^2-4ac} \over 2a}.
 $$

 See @ref(eq:1)

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

%% +------------------------+------------+----------+----------+
%% | Header row, column 1   | Header 2   | Header 3 | Header 4 |
%% | (header rows optional) |            |          |          |
%% +========================+============+==========+==========+
%% | body row 1, column 1   | column 2   | column 3 | column 4 |
%% +------------------------+------------+----------+----------+
%% | body row 2             | Cells may span columns.          |
%% +------------------------+------------+---------------------+
%% | body row 3             | Cells may  | - Table cells       |
%% +------------------------+ span rows. | - contain           |
%% | body row 4             |            | - body elements.    |
%% +------------------------+------------+---------------------+
%% 
%% +------------------------------+------------+
%% | First column header spanning | Column 3   |
%% | two rows                     |            |
%% +==============================+============+
%% | test rworwo


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


## Labels and References @label(h:labels)

@label(para) You can label the environment/block you're inside of by using the builtin `@label(label text)`

1. @label(ol:one)
   First ordered list item
   multi-line [link
   text wrap](https://google.com)
   but this will still be rendered on one line

To cross-reference a label use the builtin `@ref(label text)`:
- See section @ref(h:labels)
- Listing @ref(ol:one)
- Python @ref(first-python-code-block)
- Para @ref(para)
- Below ref use @ref(h:below-ref)

### Below @label(h:below-ref)

Position of label/ref in relation to each other does not matter!


## Citations

%% kwarg: pre for prefix, post for suffix, loc for locator, label
Blah blah @cites(@cite(Seidel2018,   loc    =    pp. 33-35), @cite(Burt2018))

%% whitespace before an argument is ignored, to get a leading space escape it with a \
Blah blah @cite(Schroeder91, loc=pp. 33-35\, 38-39 and *passim*, post=\ leading space).

Omit author name: Carlsson says blah @cite(-Carlson1997).

In-text citation: @textcite(Pukkala1987) says blah.

With locator: @textcite(Biging1992, loc=p. 33) says blah.
%% error due to postional arg after kwarg: @textcite(Biging1992, loc=p. 33, error)

%% This call will error, since nested calls of cite builtins (other than passing them
%% directly to @cites) are not allowed
%% Secondary citation: @cite(Roloff2014, post=zitiert nach @textcite(Roloff2018), loc=S. 147)
%% -> workaround:
Secondary citation: @cites(@cite(Roloff2014, loc=S. 147), @cite(Roloff2018, pre=zitiert nach Roloff (, post=\)))

## Bibliography

@bibliography()


## Other

Smallcaps: @sc(Mueller)
