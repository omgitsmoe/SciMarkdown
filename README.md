# SciMarkdown

A WIP Markdown variant with a focus on creating reproducible scientific documents.

## Features

- non-ambiguous syntax
- convenient comments with `%%` (subject to change)
- more intuitive in comparison with CommonMark Markdown and other variants:
    - blocks don't require a leading blank line
    - removed superfluous syntax: e. g. Setext headings
      ```md
      Heading
      =======
      ```
    - two spaces at the end of the line for line breaks was removed, since
      it wasn't visible when editing the raw markdown,
      use `\` at the end of a line to force a line break instead
    - nested emphasis must be alternated:
      ```md
      CommonMark: Combined emphasis with **asterisks and *underscores***.
      SciMarkdown: Combined emphasis with **asterisks and _underscores_**.
      ```
- more emphasis options: strikethrough, sub-/superscript, smallcaps
- execute fenced **and** inline code of supported programming lanugages (currently Python and R)
  and include the stdout/-err output
- labels and cross-references
- citation support provided by [citeproc](https://github.com/jgm/citeproc) -- for now
- support for latex math formulas
- no inline html, everything should be expressible in pure SciMarkdown
- thus it will be easier to add more backends

## Examples

See [this file](examples/complete.md) for a complete example of using SciMarkdown,
the HTML output can bee seen [here](https://htmlpreview.github.io/?https://github.com/omgitsmoe/SciMarkdown/blob/master/examples/complete.html).

## Usage

```
Usage: scimd [-h] [-o <FILENAME>] [-r <FILENAME>] [-s <FILENAME>] [-l <LOCALE>] [--write-bib-conversion] <IN-FILE>
    -h, --help
            Display this help and exit.

    -o, --out <FILENAME>
            Output filename.

    -r, --references <FILENAME>
            Path to references file (BibLaTeX or CSL-JSON).

    -s, --citation-style <FILENAME>
            Path to CSL file.

    -l, --locale <LOCALE>
            Specify locale as BCP 47 language tag.

        --write-bib-conversion
            Whether to write out the converted .bib file as CSL-JSON
```
