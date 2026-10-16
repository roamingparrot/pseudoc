# CIE pseudocode to Python transpiler

A command line tool written in Zig that transpiles Cambridge International (CIE)
pseudocode into Python 3. It reads a `.pseudo` file and prints the equivalent
Python program, which can then be run with `python3`.

It covers the parts of the CIE pseudocode guide that school programs use most:
variables, input and output, selection, the three loop types, arrays,
procedures and functions. Anything it does not understand is reported as an
error with a line number instead of being turned into broken Python.

## Zig version

Developed and tested with **Zig 0.17.0** (`build.zig.zon` sets
`minimum_zig_version = "0.17.0"`). The standard library changed a lot between
Zig releases (file and I/O APIs in particular), so other versions are not
expected to compile. Python 3 is only needed to run the integration tests and
the generated programs; the transpiler itself has no dependencies.

## Build

```
zig build
```

The executable is written to `zig-out/bin/pseudocode_compiler`.

## Usage

```
pseudocode_compiler <input.pseudo> [-o output.py]
```

- Without `-o` the Python is printed to standard output.
- `-o file.py` writes it to a file instead.
- `-h` shows the usage message.
- Syntax errors are printed to standard error as `file:line:column: error: message`
  and the exit code is 1. No output file is written in that case.

```
zig build run -- tests/examples/functions.pseudo -o functions.py
python3 functions.py
```

(`zig build run -- <args>` builds and runs in one step.)

## Supported CIE syntax

| CIE pseudocode | Python generated |
|---|---|
| `x <- 10` or `x ← 10` | `x = 10` |
| `INPUT name` | `name = input()` (`int(input())` / `float(input())` for a variable declared `INTEGER` / `REAL`) |
| `OUTPUT a, b` | `print(a, b, sep="")` |
| `IF c THEN` ... `ELSE` ... `ENDIF` | `if c:` ... `else:` |
| `FOR i <- 1 TO 10` ... `NEXT i` | `for i in range(1, 11):` |
| `FOR i <- 10 TO 0 STEP -2` | `for i in range(10, -1, -2):` |
| `WHILE c DO` ... `ENDWHILE` | `while c:` |
| `REPEAT` ... `UNTIL c` | `while True:` ... `if c: break` |
| `CASE OF x` ... `ENDCASE` | `if` / `elif` / `else` chain |
| `AND`, `OR`, `NOT` | `and`, `or`, `not` |
| `=`, `<>`, `<`, `<=`, `>`, `>=` | `==`, `!=`, `<`, `<=`, `>`, `>=` |
| `+ - * /`, `DIV`, `MOD`, `^` (also `MOD(a, b)` and `DIV(a, b)`) | `+ - * /`, `//`, `%`, `**` |
| `&` (string join) | `+` |
| `TRUE`, `FALSE` | `True`, `False` |
| `DECLARE x : INTEGER` | `x = 0` (default value for the type) |
| `DECLARE a : ARRAY[1:10] OF INTEGER` | `a = [0] * 11` |
| `a[i] <- 5`, `a[i + 1]` | `a[i] = 5`, `a[i + 1]` |
| `CONSTANT Pi = 3.14` | `Pi = 3.14` |
| `PROCEDURE P(x : INTEGER)` ... `ENDPROCEDURE`, `CALL P(3)` | `def P(x):` ..., `P(3)` |
| `FUNCTION F(x : INTEGER) RETURNS INTEGER` ... `ENDFUNCTION`, `RETURN x` | `def F(x):` ..., `return x` |

Details worth knowing:

- Keywords must be written in capitals, as in the CIE guide. A statement that
  starts with `if` or `Output` gives an error that points this out.
- Comments start with `//` and run to the end of the line. They are dropped.
- Strings (`"..."` or `'...'`) are copied through unchanged, so operator words
  and symbols inside them are never translated. Backslashes are doubled so
  Python does not treat them as escapes.
- `FOR` loops include both bounds, ascending or descending. When the step is a
  variable, Python works out the direction at run time.
- `REPEAT ... UNTIL` always runs the body at least once.
- `CASE` branches can be single values, ranges (`1 TO 5`), or comma separated
  lists. `OTHERWISE` must be the last branch.
- Arrays are created one element longer than declared, so CIE indexes work
  unchanged (index 0 is simply unused).
- `THEN` may be on the line after the `IF` condition. `DO` after `WHILE` is
  optional.
- Python keywords and builtins used as variable names (`class`, `len`, `from`,
  ...) get an underscore added in the output (`class_`).
- Library functions: `LENGTH`, `UCASE`, `LCASE`, `LEFT`, `RIGHT`, `MID`,
  `SUBSTRING`, `INT`, `ROUND`, `ASC`, `CHR`.
- Inside a procedure or function, assigning to a variable that was declared in
  the main program *before* the routine adds a `global` line to the Python.

## Example

CIE pseudocode (`average.pseudo`):

```
// average of three marks, with a grade for each
FUNCTION Grade(mark : INTEGER) RETURNS STRING
    CASE OF mark
        70 TO 100 : RETURN "A"
        50 TO 69 : RETURN "B"
        OTHERWISE : RETURN "U"
    ENDCASE
ENDFUNCTION

DECLARE mark : INTEGER
DECLARE total : INTEGER
total <- 0
FOR student <- 1 TO 3
    INPUT mark
    total <- total + mark
    OUTPUT "mark ", mark, " is grade ", Grade(mark)
NEXT student
OUTPUT "average: ", total / 3
```

Generated Python:

```python
def Grade(mark):
    if 70 <= mark <= 100:
        return "A"
    elif 50 <= mark <= 69:
        return "B"
    else:
        return "U"
mark = 0
total = 0
total = 0
for student in range(1, 4):
    mark = int(input())
    total = total + mark
    print("mark ", mark, " is grade ", Grade(mark), sep="")
print("average: ", total / 3, sep="")
```

Running it with the marks 75, 58 and 40 as input prints:

```
mark 75 is grade A
mark 58 is grade B
mark 40 is grade U
average: 57.666666666666664
```

## Known limitations

Not supported (the transpiler stops with an error naming the construct):

- File handling (`OPENFILE`, `READFILE`, `WRITEFILE`, `CLOSEFILE`, `SEEK`,
  `GETRECORD`, `PUTRECORD`, `EOF`)
- User defined types (`TYPE` / `ENDTYPE`, `DEFINE`) and records
- Classes and object oriented pseudocode (`CLASS`, `NEW`, `INHERITS`, ...)
- Two dimensional arrays (`ARRAY[1:3, 1:3]`, `a[i, j]`)
- `BYREF` parameters (all arguments are passed the Python way: numbers and
  strings by value, arrays by reference)
- `RAND` and the other library functions not listed above
- Types other than `INTEGER`, `REAL`, `STRING`, `CHAR`, `BOOLEAN` (for example `DATE`)

Behaviour that differs from CIE pseudocode or that is easy to trip over:

- `INPUT` only converts to a number when the variable was `DECLARE`d as
  `INTEGER` or `REAL` before the `INPUT`. Otherwise the value is a string.
- `OUTPUT` shows values the Python way: `6 / 2` prints `3.0` and `TRUE` prints
  `True`.
- `DIV` uses Python's `//`, which rounds towards minus infinity. For negative
  numbers that differs from truncating division.
- `&` becomes `+`, so both sides must already be strings. Use
  `OUTPUT "total ", n` (commas) to print a mix of text and numbers.
- Array indexes are not checked against the declared bounds. The lower bound
  must be a whole number but is otherwise ignored: elements 0 up to the upper
  bound always exist.
- A procedure or function only gets a `global` line for variables declared in
  the main program *above* it. Procedures are expected to come after the
  `DECLARE`s, as is normal in CIE programs.
- Procedures and functions cannot be defined inside each other.
- Only one comparison is allowed per expression (`a < b < c` is an error);
  use `AND`.
- A statement that is only a function call needs `CALL`, as in the CIE guide.
- Syntax checking stops at the first error.

## Testing

```
zig build test       # unit tests inside the Zig source files
zig build examples   # integration tests (needs python3)
```

`zig build test` runs the unit tests in `src/`. Most of them translate a small
piece of pseudocode and compare the Python text, or check the exact error
message and line number for bad input.

`zig build examples` runs `tests/run_examples.py`, which

- transpiles every `tests/examples/NAME.pseudo`, runs the generated Python
  (feeding it `NAME.in` as standard input if that file exists) and compares what
  it prints with `NAME.out`, and
- checks that every `tests/errors/NAME.pseudo` is rejected with an error message
  containing the text in `NAME.err`.

The examples cover assignment, input and output, arithmetic, strings,
comparison and boolean operators, nested conditionals, ascending and descending
`FOR` loops (including bounds, steps and variable steps), `WHILE`,
`REPEAT ... UNTIL`, arrays, `CASE`, procedures, functions, library functions,
and a handful of longer programs (bubble sort, linear search, primes, password
check, grade calculator).

## Project layout

```
build.zig            build script (also defines the test and examples steps)
src/main.zig         command line handling
src/source.zig       reading the input file
src/lexer.zig        turns text into tokens
src/translator.zig   parses the tokens and writes the Python
tests/examples/      programs with expected output
tests/errors/        programs that must be rejected, with expected messages
tests/run_examples.py  integration test runner
```

The translator is a single pass: a recursive descent parser that returns Python
text for each expression and writes each statement as soon as it is parsed.
There is no separate syntax tree.
