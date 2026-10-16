"""Integration tests for the transpiler.

For every tests/examples/NAME.pseudo this script
  1. transpiles it with the compiler binary,
  2. runs the generated python (feeding NAME.in to stdin if that file exists),
  3. compares what it printed with NAME.out.

For every tests/errors/NAME.pseudo the compiler must fail, and its error
output must contain the text found in NAME.err.

usage: python3 tests/run_examples.py [path/to/pseudocode_compiler]

Without an argument it uses zig-out/bin/pseudocode_compiler, so run
`zig build` first. It can be run from any directory.
"""
import subprocess
import sys
from pathlib import Path

testsDir = Path(__file__).parent


def readOptional(path):
    return path.read_text() if path.exists() else ""


def runExample(compiler, source):
    transpiled = subprocess.run([compiler, str(source)], capture_output=True, text=True)
    if transpiled.returncode != 0:
        return "transpiler failed: " + transpiled.stderr.strip()

    program = subprocess.run(
        [sys.executable, "-I", "-c", transpiled.stdout],
        input=readOptional(source.with_suffix(".in")),
        capture_output=True,
        text=True,
        timeout=10,
    )
    if program.returncode != 0:
        return "generated python crashed: " + program.stderr.strip()

    expected = source.with_suffix(".out").read_text()
    if program.stdout != expected:
        return "output differs\n--- expected\n%s--- actual\n%s" % (expected, program.stdout)
    return None


def runErrorCase(compiler, source):
    transpiled = subprocess.run([compiler, str(source)], capture_output=True, text=True)
    if transpiled.returncode == 0:
        return "expected the transpiler to reject this program"
    expectedText = source.with_suffix(".err").read_text().strip()
    if expectedText not in transpiled.stderr:
        return "error message %r does not contain %r" % (transpiled.stderr.strip(), expectedText)
    return None


def main():
    defaultCompiler = testsDir.parent / "zig-out" / "bin" / "pseudocode_compiler"
    compiler = sys.argv[1] if len(sys.argv) > 1 else str(defaultCompiler)
    if not Path(compiler).exists():
        print("compiler not found at %s - run `zig build` first" % compiler)
        sys.exit(2)
    failures = 0
    total = 0

    for source in sorted((testsDir / "examples").glob("*.pseudo")):
        total += 1
        problem = runExample(compiler, source)
        if problem:
            failures += 1
            print("FAIL examples/%s: %s" % (source.name, problem))

    for source in sorted((testsDir / "errors").glob("*.pseudo")):
        total += 1
        problem = runErrorCase(compiler, source)
        if problem:
            failures += 1
            print("FAIL errors/%s: %s" % (source.name, problem))

    print("%d of %d integration tests passed" % (total - failures, total))
    sys.exit(1 if failures else 0)


main()
