# spec/spec_helper.cr
require "spec"
require "../src/my_project"

# Spec
# ====
#
# Crystal's built-in testing library, run with `crystal spec`. Specs live in `spec/**/*_spec.cr`.
#
#  ```crystal
#  require "spec"
#
#  describe Array do
#    describe "#size" do
#      it "reports the number of elements" do
#        [1, 2, 3].size.should eq 3
#      end
#    end
#  end
#  ```
#
# Structure
# ---------
#
# A top-level `describe` names the unit under test; nested `describe`s specify smaller units or set up context. `context` is an alias for `describe`, for readability. `it` defines a test case; inside it, assertions use `should` / `should_not`.
#
# Defining examples
# -----------------
#
#   `describe(description = nil, *, focus = false, tags = nil, &block)`
#   Example group. Nestable.
#
#   `context(description = nil, *, focus = false, tags = nil, &block)`
#   Alias for `describe`.
#
#   `it(description = "assert", *, focus = false, tags = nil, &block)`
#   A test case.
#
#   `pending(description = "assert", *, focus = false, tags = nil, &block)`
#   Pending case; block (if any) never runs.
#
#   `pending!(msg = "Cannot run example")`
#   Marks the *running* example pending, based on a runtime condition.
#
#   `fail(msg)`
#   Fails the current example manually.
#
# `focus: true` on any example or group restricts the run to focused items. `tags` takes a `String` or `Enumerable(String)`; group tags are inherited by nested items.
#
#  ```crystal
#  it "adds", focus: true { (1 + 1).should eq 2 }
#
#  it "test git" do
#    cmd = Process.find_executable("git")
#    pending!("git is not available") unless cmd
#    cmd.should end_with("git")
#  end
#  ```
#
# Expectations
# ------------
#
# Every object gains `should` / `should_not`, which take a matcher and fail the example on mismatch. An optional failure message can follow:
#
#  ```crystal
#  actual.should eq(expected)
#  actual.should_not be_nil
#  value.should eq(42), "custom message"
#  ```
#
# Some overloads narrow the returned type:
#
#  ```crystal
#  x = x.should be_a(Int32)      # excludes other union members
#  x = x.should_not be_a(Char)   # excludes Char
#  x = x.should_not be_nil       # excludes Nil
#  ```
#
# Matchers
# --------
#
#   `eq(value)`                                    `actual == value` (for two `String`s, also checks `bytesize` and `size`)
#   `be(value)`                                    `actual.same?(value)`
#   `be_true` / `be_false`                         `== true` / `== false`
#   `be_truthy` / `be_falsey`                      not `nil`/`false` / is `nil` or `false`
#   `be_nil`                                       `actual.nil?`
#   `be_close(expected, delta)`                    within `delta` of `expected`
#   `be < / <= / > / >= value`                     ordered comparison
#   `match(value)`                                 `actual =~ value`
#   `contain(expected)`                            `actual.includes?(expected)`
#   `start_with(expected)` / `end_with(expected)`  `String` prefix / suffix
#   `be_empty`                                     `actual.empty?`
#   `be_a(type)`                                   `actual.is_a?(type)`
#
# `expect_raises`
# ---------------
#
#  ```crystal
#  expect_raises(klass, message = nil, &block)
#  ```
#
# Passes if the block raises `klass` whose message contains `message` (a `String`), matches it (a `Regex`), or unconditionally (`nil`). Returns the rescued exception.
#
#  ```crystal
#  ex = expect_raises(ArgumentError, "bad input") { raise ArgumentError.new("bad input here") }
#  ```
#
# Hooks
# -----
#
# Nested contexts inherit `*_each` hooks. Multiple `before_*` blocks run in definition order (outermost first); `after_*` blocks run in reverse.
#
# Per-context (inside a `describe`/`context`; error in root context):
#
#   `before_each(&block)`                           Before each spec in the context.
#   `after_each(&block)`                            After each spec.
#   `before_all(&block)`                            Once, before the first spec.
#   `after_all(&block)`                             Once, after the last spec.
#   `around_each(&block : Example::Procsy ->)`      Wraps each spec; block must call `example.run`.
#   `around_all(&block : ExampleGroup::Procsy ->)`  Wraps the context; block must call `group.run`. Not valid in root.
#
# Suite-wide (callable at top level):
#
#   `Spec.before_each(&block)` / `Spec.after_each(&block)`    Around each spec in the suite (`after` runs in reverse).
#   `Spec.before_suite(&block)` / `Spec.after_suite(&block)`  Once around the whole suite.
#   `Spec.around_each(&block : Example::Procsy ->)`           Wraps each spec; block must call `example.run`.
#
#  ```crystal
#  describe "nested" do
#    around_each do |example|
#      setup
#      example.run
#      teardown
#    end
#  end
#  ```
#
# Command line
# ------------
#
#  ```console
#  crystal spec                          # all specs
#  crystal spec spec/foo_spec.cr         # one file
#  crystal spec spec/foo_spec.cr:14      # the spec/group at line 14
#  crystal spec --tag fast               # tagged "fast"
#  crystal spec --tag ~slow              # excluding "slow"
#  ```
#
#   `-e`, `--example STRING`  Run examples whose full nested name includes `STRING`.
#   `-l`, `--line LINE`       Run examples on `LINE`.
#   `-p`, `--profile`         Print the 10 slowest specs.
#   `--fail-fast`             Abort on first failure.
#   `--location file:line`    Run the example at a location; repeatable.
#   `--tag TAG`               Include (`TAG`) or exclude (`~TAG`) by tag.
#   `--list-tags`             List all tags with counts.
#   `--order MODE`            `random`, `default`, or a numeric seed.
#   `--junit_output PATH`     Write JUnit XML.
#   `-v`, `--verbose`         Verbose formatter.
#   `--tap`                   TAP formatter.
#   `--color` / `--no-color`  Force ANSI color on/off.
#   `--dry-run`               Report all as passing without running.
#   `-h`, `--help`            Show help.
#
# Environment variables: `SPEC_VERBOSE=1` (verbose formatter), `SPEC_SPLIT` (`remainder%quotient` partition), `SPEC_SPLIT_DOTS` (line break every N dots), `SPEC_FOCUS_NO_FAIL=1` (don't fail the run just for using `focus`), `CRYSTAL_WORKERS` (fiber execution context size).
#
# Focus, tags, order, formatters
# ------------------------------
#
# * Focus — `focus: true` runs only focused items; the run then exits nonzero unless `SPEC_FOCUS_NO_FAIL=1`.
# * Tags — filter with `--tag` / `--tag ~`; list with `--list-tags`.
# * Order — `--order random` shuffles and prints a seed; pass that seed to `--order` to reproduce.
# * Formatters — dot (default), `--verbose`, `--tap`, `--junit_output PATH`.
#
# Helpers
# -------
#
# Required separately; both define macros usable at top level.
#
# `require "spec/helpers/iterate"`
# --------------------------------
#
#  ```crystal
#  it_iterates(description, expected, method, *, infinite = false, tuple = false)
#  ```
#
# Creates two examples (`" yielding"` and `" iterator"`) testing both forms of an iteration method against `expected`, checking element type-equality. `infinite` skips the finish check; `tuple` splats multi-value elements. Lower-level `assert_iterates_yielding` and `assert_iterates_iterator` can be used inside an example directly.
#
#  ```crystal
#  it_iterates "Array#each", [1, 2, 3], (1..3).each
#  it_iterates "#cycle", [1, 2, 3, 1], (1..3).cycle, infinite: true
#  it_iterates "#each_with_index", [{1, 0}, {2, 1}], (1..2).each_with_index, tuple: true
#  ```
#
# `require "spec/helpers/string"`
# -------------------------------
#
#  ```crystal
#  assert_prints(call, str)
#  assert_prints(call, *, should: expectation)
#  ```
#
# Asserts that a call and its `IO`-accepting overload both produce the same string. Checks the direct call (must return `String`), the `String.build` form, and a UTF-16-encoded `IO` round-trip (skipped under the `without_iconv` flag).
#
#  ```crystal
#  assert_prints 123.to_s, "123"
#  assert_prints 123.to_s(16), "7b"
#  ```
