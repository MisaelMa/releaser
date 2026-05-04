# Spec: Releaser.UI

## Overview

ANSI terminal color and formatting helper module. Provides functions to wrap text with escape codes for terminal output styling.

---

## Requirements: magenta/1 and blue/1 color helpers

`Releaser.UI` MUST expose `magenta/1` and `blue/1` functions. Each MUST wrap the given text with its corresponding ANSI color escape code, followed immediately by `IO.ANSI.reset()`, and return the resulting string. Both MUST follow the exact same pattern as the existing `green/1`, `cyan/1`, `yellow/1`, and `red/1` helpers.

### Scenario 4.1: magenta/1 wraps text with ANSI magenta and reset

- GIVEN the string `"hello"`
- WHEN `UI.magenta("hello")` is called
- THEN the result starts with the ANSI magenta escape sequence
- AND the result ends with the ANSI reset escape sequence
- AND the string `"hello"` appears between the two sequences

### Scenario 4.2: blue/1 wraps text with ANSI blue and reset

- GIVEN the string `"world"`
- WHEN `UI.blue("world")` is called
- THEN the result starts with the ANSI blue escape sequence
- AND the result ends with the ANSI reset escape sequence
- AND the string `"world"` appears between the two sequences

### Scenario 4.3: stripping ANSI leaves the bare text

- GIVEN a call to `UI.magenta("foo")` or `UI.blue("bar")`
- WHEN the ANSI escape sequences are stripped via `~r/\e\[[0-9;]*m/`
- THEN the result is `"foo"` or `"bar"` respectively
