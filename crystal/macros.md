# Crystal Macros

A practical guide to writing macros in Crystal, followed by a complete reference of the macro language: the top-level macro methods and every AST node type with the methods available on it at compile time.

- [Part I — Writing Macros](#part-i--writing-macros)
  - [What macros are](#what-macros-are)
  - [Defining and invoking macros](#defining-and-invoking-macros)
  - [Interpolating nodes: `{{ }}` vs `{% %}`](#interpolating-nodes----vs---)
  - [Names and identifiers: `id`, `stringify`, `symbolize`](#names-and-identifiers-id-stringify-symbolize)
  - [Conditionals and loops](#conditionals-and-loops)
  - [Macro variables and fresh variables](#macro-variables-and-fresh-variables)
  - [`verbatim`](#verbatim)
  - [Macro hooks](#macro-hooks)
  - [Annotations](#annotations)
  - [The compile-time world](#the-compile-time-world)
  - [Debugging macros](#debugging-macros)
  - [Pitfalls and best practices](#pitfalls-and-best-practices)
- [Part II — Macro Language Reference](#part-ii--macro-language-reference)
  - [Top-level methods](#top-level-methods)
  - [`ASTNode` (base of all nodes)](#astnode-base-of-all-nodes)
  - [Literal nodes](#literal-nodes)
  - [Expression nodes](#expression-nodes)
  - [Definition nodes](#definition-nodes)
  - [Type grammar nodes](#type-grammar-nodes)
  - [Macro-internal nodes](#macro-internal-nodes)
  - [`MacroId`](#macroid)
  - [`TypeNode`](#typenode)

---

# Part I — Writing Macros

## What macros are

A macro is a fragment of code that is expanded at **compile time**. When the compiler encounters a macro call, it runs the macro body as a small compile-time program whose output is Crystal source code; that generated code is then parsed and compiled in place of the call.

Inside a macro, everything between `{{ ... }}` and `{% ... %}` operates on **AST nodes** — objects representing the syntax tree of your program — rather than on runtime values. Macro arguments are passed as AST nodes, types can be introspected through `@type`, and the fixed set of methods documented in Part II is available on those nodes.

Macros are expanded during the semantic phase, once per instantiation site that needs them, so generated code is fully type-checked like hand-written code.

## Defining and invoking macros

```crystal
macro define_method(name, content)
  def {{name.id}}
    {{content}}
  end
end

define_method foo, 1
define_method :bar, 2
define_method "baz", 3

puts foo # => 1
puts bar # => 2
puts baz # => 3
```

Notes:

- Macro calls look like method calls, but there is no receiver and no runtime dispatch.
- Arguments arrive as AST nodes: `foo` is a `Call`, `:bar` is a `SymbolLiteral`, `"baz"` is a `StringLiteral`.
- A macro may declare a splat (`*args`), a double splat (`**opts`), and a block argument (`&block`), which receive `ArrayLiteral` / `TupleLiteral`, `NamedTupleLiteral`, and `Block` nodes respectively.

## Interpolating nodes: `{{ }}` vs `{% %}`

Two delimiters exist inside a macro body:

- `{{ exp }}` — **macro expression**: evaluates `exp` in the macro language and pastes the result into the generated code.
- `{% ... %}` — **macro control**: evaluated at compile time for its effect (conditionals, loops, assignments) and produces no output by itself.

```crystal
macro assert_size(type, expected)
  {% actual = sizeof(type) %}
  {% unless actual == expected %}
    {% raise "#{type} has size #{actual}, expected #{expected}" %}
  {% end %}
end
```

Outside of macros, `{{ ... }}` and `{% ... %}` can also appear directly in regular code (top-level, method bodies, type definitions) — they are expanded the same way.

## Names and identifiers: `id`, `stringify`, `symbolize`

Different node types can be converted to a common currency:

- `.id` → `MacroId`: the bare identifier. Use it to turn a string, symbol, var or call into something usable as a method name, variable name, etc.
- `.stringify` → `StringLiteral`: the node's textual representation (including quotes for string literals).
- `.symbolize` → `SymbolLiteral`: the node's textual representation as a symbol.

```crystal
macro getter(name)
  def {{name.id}}
    @{{name.id}}
  end
end

getter unicorns   # Call
getter :unicorns  # SymbolLiteral
getter "unicorns" # StringLiteral
```

All three calls generate the same method, because `.id` normalizes them. Without `.id`, the generated code would contain `def :unicorns` or `def "unicorns"` — invalid syntax.

## Conditionals and loops

```crystal
{% if flag?(:win32) %}
  # emitted only on Windows
{% elsif some_node.is_a?(StringLiteral) %}
  # ...
{% else %}
  # ...
{% end %}
```

```crystal
{% for name, index in %w[foo bar baz] %}
  def {{name.id}}
    {{index}}
  end
{% end %}
```

`{% for %}` iterates over `ArrayLiteral`, `TupleLiteral`, `HashLiteral`, `NamedTupleLiteral` (yielding key/value pairs) and `RangeLiteral` of integer literals. `{% begin %}...{% end %}` groups generated code. Loop-local variables are implicitly fresh per iteration.

## Macro variables and fresh variables

Variables assigned inside `{% ... %}` live only in the macro's compile-time scope:

```crystal
{% count = 3 %}
{% names = ["a", "b", "c"] %}
```

To declare a variable in the **generated** code without colliding with variables at the expansion site, use a *fresh variable*: prefix the name with `%`.

```crystal
macro repeat(times, &block)
  %i = 0
  while %i < {{times}}
    {{block.body}}
    %i += 1
  end
end

repeat(3) { puts %i }
```

Each expansion of the macro renames `%i` to a unique identifier (like `__temp_5`), so nested or repeated expansions never clash. `MacroVar#expressions` lets you index fresh variables (`%i{0}`, `%i{1}`, …) when you need a stable family of them.

## `verbatim`

`{% verbatim do %} ... {% end %}` suppresses macro expansion of the nested `{{ }}` / `{% %}` inside it. This is essential when a macro must *generate another macro*:

```crystal
macro define_dsl(name)
  macro {{name.id}}
    {% verbatim do %}
      def generated_{{@type.name.underscore.id}}
      end
    {% end %}
  end
end
```

Without `verbatim`, the inner `{{@type...}}` would be evaluated by the outer macro instead of being emitted literally.

## Macro hooks

Special macro definitions act as callbacks fired by the compiler:

| Hook                         | Fires when                                                                                                                                            |
|------------------------------|-------------------------------------------------------------------------------------------------------------------------------------------------------|
| `macro finished`             | The main type hierarchy is known; the last expansion phase before codegen. Ideal for generating code that needs `all_subclasses`, `all_methods`, etc. |
| `macro inherited`            | A type is subclassed.                                                                                                                                 |
| `macro included`             | A module is included into a type.                                                                                                                     |
| `macro extended`             | A module is used with `extend`.                                                                                                                       |
| `macro method_missing(call)` | An unknown method is called on the type (receives the `Call` node).                                                                                   |
| `macro method_added(def)`    | A method is defined in the type (receives the `Def` node).                                                                                            |

Example — a registry of subclasses:

```crystal
abstract class Animal
  macro inherited
    {% unless @type.abstract? %}
      Animal.register({{@type}})
    {% end %}
  end

  def self.register(type)
    (@@subclasses ||= [] of String) << type.name
  end
end
```

`finished` runs after all other hooks, so it sees the complete program; hooks like `inherited` run while the hierarchy is still being built, and some `TypeNode` methods (e.g. `all_subclasses`) are only reliable inside `finished`.

## Annotations

Macros can read annotations attached to types, methods, defs and instance variables:

```crystal
annotation Field
end

class Config
  @[Field(name: "port")]
  @port : Int32 = 8080
end
```

```crystal
{% for ivar in @type.instance_vars %}
  {% ann = ivar.annotation(Field) %}
  {% if ann %}
    # ann[:name] -> "port"; ann.args / ann.named_args also available
  {% end %}
{% end %}
```

`annotation(T)` returns the last annotation of that type or `NilLiteral`; `annotations(T)` returns all of them; `annotations` returns every annotation regardless of type.

## The compile-time world

A handful of top-level macro methods connect expansion to the build environment:

- `{{ flag?(:x86_64) }}` / `host_flag?` — test compile-time flags (target vs host, which differ under cross-compilation).
- `{{ env("HOME") }}` — read an environment variable at compile time.
- `read_file(path)` / `read_file?(path)` / `file_exists?(path)` — embed external files (use `"#{__DIR__}/..."` for paths relative to the current source file).
- `{{ run("./gen", arg) }}` — compile and run a Crystal helper program at compile time and embed its output. Powerful (arbitrary file/network access) but slow and cached by mtime; keep run programs deterministic and fast.
- `{{ system("git rev-parse HEAD") }}` or backtick literals — run a shell command.
- `{% skip_file unless flag?(:darwin) %}` — skip the rest of the current file.
- `{{ compare_versions(Crystal::VERSION, "1.0.0") }}` — semver comparison for version-dependent code.

## Debugging macros

- `{% puts node %}`, `{% p node %}`, `{% pp node %}` — print AST nodes at compile time.
- `{% p! expr %}` / `{% pp! expr %}` — print the expression **and** its value.
- `{% debug %}` — dump the macro's whole generated buffer (formatted by default; `{% debug(format: false) %}` for raw output).
- `{% raise "message" %}` — abort compilation with an error; `node.raise` highlights that node. `warning` emits a non-fatal warning.
- `crystal tool expand -c file.cr:line:col file.cr` — show the expansion of a macro at a cursor location.

## Pitfalls and best practices

- **Macro arguments are syntax, not values.** `foo(1 + 2)` receives a `Call` node for `1 + 2`, not `3`. Use `.id`, `stringify`, or introspect the node; evaluate arithmetic only in `{% %}` with literal operands.
- **`is_a?` checks AST node types, never program types.** `{{ 1.is_a?(NumberLiteral) }}` is `true`; `{{ 1.is_a?(Int32) }}` is `false`.
- **Resolve paths deliberately.** `Path#resolve` raises a compile-time error on unknown constants; `resolve?` returns `NilLiteral` instead. `parse_type("Foo(Int32)")` builds a resolvable type grammar node from a string.
- **`run` caching.** The compiler caches the executable produced for `run` and recompiles only when its dependencies' mtimes change. A run program that itself depends on the time of day or on shell commands at compile time defeats this caching and slows every build.
- **Top-level vs method context.** `TypeNode#instance_vars` and `#has_inner_pointers?` must be called from within a method (or a hook that expands into one); at top level they return empty/incorrect results.
- **Keep expansions small.** Generated code is type-checked at every instantiation site; prefer generating a thin wrapper over shared runtime code instead of duplicating large bodies.

---

# Part II — Macro Language Reference

The methods below are the fixed subset of methods callable on AST nodes at compile time. They are documented in the compiler as the fictitious module `Crystal::Macros`. Node classes marked *abstract* exist only as a common base for other nodes.

## Top-level methods

These are invoked without a receiver anywhere `{{ }}` / `{% %}` is allowed.

| Method                     | Returns                                        | Description                                                                                                                                                     |
|----------------------------|------------------------------------------------|-----------------------------------------------------------------------------------------------------------------------------------------------------------------|
| `compare_versions(v1, v2)` | `NumberLiteral`                                | Compares two semantic versions; `-1`, `0` or `1`.                                                                                                               |
| `debug(format = true)`     | `Nop`                                          | Outputs the current macro's buffer to stdout; formatted unless `format: false`.                                                                                 |
| `env(name)`                | `StringLiteral \| NilLiteral`                  | Value of an environment variable at compile time, or `nil`.                                                                                                     |
| `flag?(name)`              | `BoolLiteral`                                  | Whether a compile-time flag is set for the target platform.                                                                                                     |
| `host_flag?(name)`         | `BoolLiteral`                                  | Whether a compile-time flag is set for the host platform (differs from `flag?` when cross-compiling).                                                           |
| `parse_type(type_name)`    | `Path \| Generic \| ProcNotation \| Metaclass` | Parses a string into a type grammar node; use `#resolve` on the result. Compile-time error if the type/constant doesn't exist or a generic argument is missing. |
| `puts(*expressions)`       | `Nop`                                          | Prints AST nodes at compile time (debugging).                                                                                                                   |
| `print(*expressions)`      | `Nop`                                          | Prints AST nodes at compile time (debugging).                                                                                                                   |
| `p(*expressions)`          | `Nop`                                          | Same as `puts`.                                                                                                                                                 |
| `pp(*expressions)`         | `Nop`                                          | Same as `puts`.                                                                                                                                                 |
| `p!(*expressions)`         | `Nop`                                          | Prints macro expressions together with their values.                                                                                                            |
| `pp!(*expressions)`        | `Nop`                                          | Same as `p!`.                                                                                                                                                   |
| `` `(command) `` | `MacroId` | Executes a system command, returns its output; compile-time error on failure. Invoked via command literals: `` {{ `echo hi` }} ``. |
| `system(command)` | `MacroId` | Same as the backtick form: `{{ system("echo hi") }}`. |
| `raise(message)` | `NoReturn` | Gives a compile-time error with the message. |
| `warning(message)` | `NilLiteral` | Emits a compile-time warning. |
| `file_exists?(filename)` | `BoolLiteral` | Whether the given file exists. |
| `read_file(filename)` | `StringLiteral` | Reads a file; compile-time error if missing/unreadable. Relative paths resolve against the current working directory — prefer `"#{__DIR__}/file"`. |
| `read_file?(filename)` | `StringLiteral \| NilLiteral` | Like `read_file`, but returns `nil` on any I/O failure. |
| `run(filename, *args)` | `MacroId` | Compiles and executes a Crystal program, returning its output. The compiler may cache the executable (recompiling only on dependency mtime changes); keep the program deterministic and fast. |
| `skip_file` | `Nop` | Skips the rest of the file it is executed in: `{% skip_file unless flag?(:darwin) %}`. |
| `sizeof(type)` | `NumberLiteral` | Size of a *stable* type in bytes. `type` must be a constant; not evaluable at macro time nor a `typeof`. |
| `alignof(type)` | `NumberLiteral` | Alignment of a *stable* type in bytes; same restrictions as `sizeof`. |

A type is **stable** for `sizeof`/`alignof` if its size and alignment cannot change as new code is processed. All types are stable except: structs (e.g. `Bytes`), `ReferenceStorage` instances, modules (e.g. `Math` — but `Math.class` is stable), uninstantiated generics (e.g. `Array`), `StaticArray`/`Tuple`/`NamedTuple` with unstable element types, and unions containing unstable types.

## `ASTNode` (base of all nodes)

The base class of all AST nodes; these methods are available on **every** node listed below.

| Method              | Returns                       | Description                                                                                                                                                                             |
|---------------------|-------------------------------|-----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| `id`                | `MacroId`                     | This node as an identifier. Useful to get an identifier out of a `StringLiteral`, `SymbolLiteral`, `Var` or `Call`.                                                                     |
| `stringify`         | `StringLiteral`               | This node's textual representation. On a string literal the result still contains the quotes.                                                                                           |
| `symbolize`         | `SymbolLiteral`               | This node's textual representation as a symbol: `{{ "foo".id.symbolize }} # => :foo`.                                                                                                   |
| `class_name`        | `StringLiteral`               | This node's class name, e.g. `"StringLiteral"`.                                                                                                                                         |
| `filename`          | `StringLiteral \| NilLiteral` | Filename where this node is located, if known.                                                                                                                                          |
| `line_number`       | `StringLiteral \| NilLiteral` | Line where this node begins (1-based), if known.                                                                                                                                        |
| `column_number`     | `StringLiteral \| NilLiteral` | Column where this node begins (1-based), if known.                                                                                                                                      |
| `end_line_number`   | `StringLiteral \| NilLiteral` | Line where this node ends (1-based), if known.                                                                                                                                          |
| `end_column_number` | `StringLiteral \| NilLiteral` | Column where this node ends (1-based), if known.                                                                                                                                        |
| `==(other)`         | `BoolLiteral`                 | Whether this node's textual representation equals *other*'s.                                                                                                                            |
| `!=(other)`         | `BoolLiteral`                 | Whether this node's textual representation differs from *other*'s.                                                                                                                      |
| `raise(message)`    | `NoReturn`                    | Compile-time error highlighting this node.                                                                                                                                              |
| `warning(message)`  | `NilLiteral`                  | Compile-time warning highlighting this node.                                                                                                                                            |
| `doc`               | `StringLiteral`               | Documentation comments attached to this node, or `""`. Empty outside of `crystal docs`.                                                                                                 |
| `doc_comment`       | `MacroId`                     | Documentation comments, each line prefixed with `#` so the output can be spliced into another node's docs (see *merging expansion and call comments*). Empty outside of `crystal docs`. |
| `is_a?(type)`       | `BoolLiteral`                 | Whether this node's type is the given **AST node** type (or a subclass): `{{ 1.is_a?(NumberLiteral) }} # => true`. Never refers to program types.                                       |
| `nil?`              | `BoolLiteral`                 | Whether this node is a `NilLiteral` or `Nop`.                                                                                                                                           |

## Literal nodes

### `Nop`

The empty node. Similar to `NilLiteral`, but its textual representation is the empty string — e.g. the missing `else` branch of an `if` without `else`. Adds no methods.

### `NilLiteral`

The `nil` literal. Adds no methods.

### `BoolLiteral`

A `true`/`false` literal. Adds no methods.

### `NumberLiteral`

Any number literal.

| Method                    | Returns         | Description                                                     |
|---------------------------|-----------------|-----------------------------------------------------------------|
| `zero?`                   | `BoolLiteral`   | Whether the value is `0`.                                       |
| `<`, `<=`, `>`, `>=`      | `BoolLiteral`   | Value comparison against another `NumberLiteral`.               |
| `<=>(other)`              | `NumberLiteral` | Comparison returning `-1`, `0` or `1`.                          |
| `+`, `-`, `*`             | `NumberLiteral` | Same as `Number#+`, `Number#-`, `Number#*`.                     |
| `//`, `%`                 | `NumberLiteral` | Same as `Number#//`, `Number#%`.                                |
| `&`, `\|`, `^`            | `NumberLiteral` | Bitwise operators.                                              |
| `**`                      | `NumberLiteral` | Same as `Number#**`.                                            |
| `<<`, `>>`                | `NumberLiteral` | Shift operators.                                                |
| unary `+`, unary `-`, `~` | `NumberLiteral` | Unary operators.                                                |
| `kind`                    | `SymbolLiteral` | The literal's type suffix: `:i32`, `:u16`, `:f32`, `:f64`, etc. |
| `to_number`               | `MacroId`       | The value without a type suffix.                                |

Note: `/` (exact float division) is **not** available on `NumberLiteral` — use `//` (floored division), which works for integer literals.

### `CharLiteral`

A character literal.

| Method | Returns         | Description                |
|--------|-----------------|----------------------------|
| `id`   | `MacroId`       | This character's contents. |
| `ord`  | `NumberLiteral` | Similar to `Char#ord`.     |

### String-like nodes: `StringLiteral`, `SymbolLiteral`, `MacroId`

These three node types share one set of string methods (the compiler defines them once and mixes them into all three classes; return types written `Self`-like below return the receiver's own node type). They are listed here once.

| Method                     | Returns                                                                    | Description                                                                                                                                                                                                                                                                                                       |
|----------------------------|----------------------------------------------------------------------------|-------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| `id`                       | `MacroId`                                                                  | A `MacroId` for this string's contents.                                                                                                                                                                                                                                                                           |
| `[](range)`                | `Self`                                                                     | Similar to `String#[]`.                                                                                                                                                                                                                                                                                           |
| `=~(regex)`                | `BoolLiteral`                                                              | Similar to `String#matches?`.                                                                                                                                                                                                                                                                                     |
| `+(other)`                 | `Self`                                                                     | Similar to `String#+` (other: `StringLiteral \| CharLiteral`).                                                                                                                                                                                                                                                    |
| `camelcase(lower: false)`  | `Self`                                                                     | Similar to `String#camelcase`.                                                                                                                                                                                                                                                                                    |
| `capitalize`               | `Self`                                                                     | Similar to `String#capitalize`.                                                                                                                                                                                                                                                                                   |
| `chars`                    | `ArrayLiteral(CharLiteral)`                                                | Similar to `String#chars`.                                                                                                                                                                                                                                                                                        |
| `chomp`                    | `Self`                                                                     | Similar to `String#chomp`.                                                                                                                                                                                                                                                                                        |
| `count(other)`             | `NumberLiteral`                                                            | Similar to `String#count`.                                                                                                                                                                                                                                                                                        |
| `downcase`                 | `Self`                                                                     | Similar to `String#downcase`.                                                                                                                                                                                                                                                                                     |
| `empty?`                   | `BoolLiteral`                                                              | Similar to `String#empty?`.                                                                                                                                                                                                                                                                                       |
| `ends_with?(other)`        | `BoolLiteral`                                                              | Similar to `String#ends_with?`.                                                                                                                                                                                                                                                                                   |
| `gsub(regex, &block)`      | `Self`                                                                     | Similar to `String#gsub(pattern, options, &)`. The special variables `$~`, `$1`, … are **not** supported; the block receives the match string and an `ArrayLiteral(StringLiteral \| NilLiteral)` of captures.                                                                                                     |
| `gsub(regex, replacement)` | `Self`                                                                     | Similar to `String#gsub`.                                                                                                                                                                                                                                                                                         |
| `includes?(search)`        | `BoolLiteral`                                                              | Similar to `String#includes?`.                                                                                                                                                                                                                                                                                    |
| `match(regex)`             | `HashLiteral(NumberLiteral \| StringLiteral, StringLiteral \| NilLiteral)` | Capture hash for the match (same form as `Regex::MatchData#to_h`), or `nil`.                                                                                                                                                                                                                                      |
| `scan(regex)`              | `ArrayLiteral(HashLiteral(...))`                                           | A capture hash per match of *regex*.                                                                                                                                                                                                                                                                              |
| `size`                     | `NumberLiteral`                                                            | Similar to `String#size`.                                                                                                                                                                                                                                                                                         |
| `lines`                    | `ArrayLiteral(StringLiteral)`                                              | Similar to `String#lines`.                                                                                                                                                                                                                                                                                        |
| `split`                    | `ArrayLiteral(StringLiteral)`                                              | Similar to `String#split()`.                                                                                                                                                                                                                                                                                      |
| `split(node)`              | `ArrayLiteral(StringLiteral)`                                              | Overloads for `StringLiteral`, `CharLiteral` and `RegexLiteral`. The `split(ASTNode)` overload is **deprecated** — use `split(StringLiteral)`.                                                                                                                                                                    |
| `starts_with?(other)`      | `BoolLiteral`                                                              | Similar to `String#starts_with?`.                                                                                                                                                                                                                                                                                 |
| `strip`                    | `Self`                                                                     | Similar to `String#strip`.                                                                                                                                                                                                                                                                                        |
| `titleize`                 | `Self`                                                                     | Similar to `String#titleize`.                                                                                                                                                                                                                                                                                     |
| `to_i(base = 10)`          | `NumberLiteral`                                                            | Similar to `String#to_i`.                                                                                                                                                                                                                                                                                         |
| `to_utf16`                 | `ASTNode`                                                                  | **Experimental.** Expression evaluating to a slice literal of UTF-16 code units plus a trailing null (not part of the slice) so `#to_unsafe` is always null-terminated: `{{ "abc😂".to_utf16 }} # => ::Slice(::UInt16).literal(97, 98, 99, 55357, 56834, 0)[0, 5]`. The result is not necessarily a literal node. |
| `tr(from, to)`             | `Self`                                                                     | Similar to `String#tr`.                                                                                                                                                                                                                                                                                           |
| `underscore`               | `Self`                                                                     | Similar to `String#underscore`.                                                                                                                                                                                                                                                                                   |
| `upcase`                   | `Self`                                                                     | Similar to `String#upcase`.                                                                                                                                                                                                                                                                                       |

Additionally, `StringLiteral` and `MacroId` have:

| Method                 | Returns       | Description                                                             |
|------------------------|---------------|-------------------------------------------------------------------------|
| `>(other)`, `<(other)` | `BoolLiteral` | Similar to `String#>` / `String#<` (other: `StringLiteral \| MacroId`). |

And `StringLiteral` alone has:

| Method     | Returns         | Description                         |
|------------|-----------------|-------------------------------------|
| `*(other)` | `StringLiteral` | Similar to `String#*` (repetition). |

### `StringInterpolation`

An interpolated string like `"Hello, #{name}!"`.

| Method        | Returns                 | Description                                                                                                             |
|---------------|-------------------------|-------------------------------------------------------------------------------------------------------------------------|
| `expressions` | `ArrayLiteral(ASTNode)` | The parts of the interpolation, alternating `StringLiteral` (plaintext) and arbitrary nodes (interpolated expressions). |

### `ArrayLiteral`

An array literal, e.g. `[1, 2, 3]`.

| Method                                       | Returns                               | Description                                                                                                        |
|----------------------------------------------|---------------------------------------|--------------------------------------------------------------------------------------------------------------------|
| `any?(&)`, `all?(&)`                         | `BoolLiteral`                         | Similar to `Enumerable#any?` / `#all?`.                                                                            |
| `splat(trailing_string = nil)`               | `MacroId`                             | All elements joined by commas; *trailing_string* is appended unless empty — splat with an optional trailing comma. |
| `clear`                                      | `ArrayLiteral`                        | Similar to `Array#clear`.                                                                                          |
| `empty?`                                     | `BoolLiteral`                         | Similar to `Array#empty?`.                                                                                         |
| `find(&)`                                    | `ASTNode \| NilLiteral`               | Similar to `Enumerable#find`.                                                                                      |
| `first`                                      | `ASTNode \| NilLiteral`               | Like `Array#first`, but `NilLiteral` when empty.                                                                   |
| `includes?(node)`                            | `BoolLiteral`                         | Similar to `Enumerable#includes?(obj)`.                                                                            |
| `join(separator)`                            | `StringLiteral`                       | Similar to `Enumerable#join`.                                                                                      |
| `last`                                       | `ASTNode \| NilLiteral`               | Like `Array#last`, but `NilLiteral` when empty.                                                                    |
| `size`                                       | `NumberLiteral`                       | Similar to `Array#size`.                                                                                           |
| `map(&)`, `map_with_index(&)`                | `ArrayLiteral`                        | Similar to `Enumerable#map` / `#map_with_index`.                                                                   |
| `each(&)`, `each_with_index(&)`              | `NilLiteral`                          | Similar to `Array#each` / `Enumerable#each_with_index`.                                                            |
| `select(&)`, `reject(&)`                     | `ArrayLiteral`                        | Similar to `Enumerable#select` / `#reject`.                                                                        |
| `reduce(&)`, `reduce(memo, &)`               | `ASTNode`                             | Similar to `Enumerable#reduce`.                                                                                    |
| `shuffle`                                    | `ArrayLiteral`                        | Similar to `Array#shuffle`.                                                                                        |
| `sort`, `sort_by(&)`                         | `ArrayLiteral`                        | Similar to `Array#sort` / `#sort_by`.                                                                              |
| `uniq`                                       | `ArrayLiteral`                        | Similar to `Array#uniq`.                                                                                           |
| `[](index)`                                  | `ASTNode`                             | Similar to `Array#[]?(Int)`.                                                                                       |
| `[](range)`                                  | `ArrayLiteral(ASTNode) \| NilLiteral` | Similar to `Array#[]?(Range)`.                                                                                     |
| `[](start, count)`                           | `ArrayLiteral(ASTNode) \| NilLiteral` | Similar to `Array#[]?(Int, Int)`.                                                                                  |
| `[]=(index, value)`                          | `ASTNode`                             | Similar to `Array#[]=`.                                                                                            |
| `unshift(value)`, `push(value)`, `<<(value)` | `ArrayLiteral`                        | Similar to `Array#unshift` / `#push` / `#<<`.                                                                      |
| `+(other)`, `-(other)`                       | `ArrayLiteral`                        | Similar to `Array#+` / `#-`.                                                                                       |
| `*(other)`                                   | `ArrayLiteral`                        | Similar to `Array#*`.                                                                                              |
| `of`                                         | `ASTNode \| Nop`                      | The element type written after the brackets in `[] of String`, if any.                                             |
| `type`                                       | `Path \| Nop`                         | The receiver type in `MyArray{1, 2, 3}`, if any.                                                                   |

### `HashLiteral`

A hash literal, e.g. `{"a" => 1}`.

| Method                                | Returns                      | Description                                                                                                              |
|---------------------------------------|------------------------------|--------------------------------------------------------------------------------------------------------------------------|
| `clear`                               | `HashLiteral`                | Similar to `Hash#clear`.                                                                                                 |
| `each(&)`                             | `NilLiteral`                 | Similar to `Hash#each`.                                                                                                  |
| `empty?`                              | `BoolLiteral`                | Similar to `Hash#empty?`.                                                                                                |
| `keys`                                | `ArrayLiteral`               | Similar to `Hash#keys`.                                                                                                  |
| `size`                                | `NumberLiteral`              | Similar to `Hash#size`.                                                                                                  |
| `to_a`                                | `ArrayLiteral(TupleLiteral)` | Similar to `Hash#to_a`.                                                                                                  |
| `values`                              | `ArrayLiteral`               | Similar to `Hash#values`.                                                                                                |
| `map(&)`                              | `ArrayLiteral`               | Similar to `Hash#map`.                                                                                                   |
| `select(&)`                           | `HashLiteral`                | Similar to `Hash#select`.                                                                                                |
| `select(*keys)`                       | `HashLiteral`                | New hash with only the given keys.                                                                                       |
| `reject(&)`                           | `HashLiteral`                | Similar to `Hash#reject`.                                                                                                |
| `reject(*keys)`                       | `HashLiteral`                | New hash without the given keys.                                                                                         |
| `[](key)`                             | `ASTNode`                    | Similar to `Hash#[]?`.                                                                                                   |
| `[]=(key, value)`                     | `ASTNode`                    | Similar to `Hash#[]=`.                                                                                                   |
| `has_key?(key)`                       | `BoolLiteral`                | Similar to `Hash#has_key?`.                                                                                              |
| `of_key`                              | `ASTNode \| Nop`             | Key type in `{} of String => Int32`, if any.                                                                             |
| `of_value`                            | `ASTNode \| Nop`             | Value type in `{} of String => Int32`, if any.                                                                           |
| `type`                                | `Path \| Nop`                | The receiver type in `MyHash{'a' => 1}`, if any.                                                                         |
| `double_splat(trailing_string = nil)` | `MacroId`                    | All entries joined by commas, with an optional trailing string unless empty — double-splat with optional trailing comma. |

### `NamedTupleLiteral`

A named tuple literal, e.g. `{a: 1, b: 2}`.

| Method                                | Returns                      | Description                                                                             |
|---------------------------------------|------------------------------|-----------------------------------------------------------------------------------------|
| `each(&)`, `each_with_index(&)`       | `NilLiteral`                 | Similar to `NamedTuple#each` / `#each_with_index`.                                      |
| `empty?`                              | `BoolLiteral`                | Similar to `NamedTuple#empty?`.                                                         |
| `keys`                                | `ArrayLiteral`               | Similar to `NamedTuple#keys`.                                                           |
| `size`                                | `NumberLiteral`              | Similar to `NamedTuple#size`.                                                           |
| `to_a`                                | `ArrayLiteral(TupleLiteral)` | Similar to `NamedTuple#to_a`.                                                           |
| `values`                              | `ArrayLiteral`               | Similar to `NamedTuple#values`.                                                         |
| `map(&)`                              | `ArrayLiteral`               | Similar to `NamedTuple#map`.                                                            |
| `select(&)`                           | `NamedTupleLiteral`          | Similar to `Hash#select`.                                                               |
| `select(*keys)`                       | `NamedTupleLiteral`          | New named tuple with only the given keys (`SymbolLiteral \| StringLiteral \| MacroId`). |
| `reject(&)`                           | `NamedTupleLiteral`          | Similar to `Hash#reject`.                                                               |
| `reject(*keys)`                       | `NamedTupleLiteral`          | New named tuple without the given keys.                                                 |
| `double_splat(trailing_string = nil)` | `MacroId`                    | Similar to `HashLiteral#double_splat`.                                                  |
| `[](key)`                             | `ASTNode`                    | Similar to `NamedTuple#[]`, but `NilLiteral` if *key* is undefined.                     |
| `[]=(key, value)`                     | `ASTNode`                    | Adds or replaces a key.                                                                 |
| `has_key?(key)`                       | `BoolLiteral`                | Similar to `NamedTuple#has_key?`.                                                       |

### `RangeLiteral`

A range literal, e.g. `(1..5)`.

| Method          | Returns        | Description                                                                      |
|-----------------|----------------|----------------------------------------------------------------------------------|
| `begin`         | `ASTNode`      | Similar to `Range#begin`.                                                        |
| `each(&)`       | `NilLiteral`   | Similar to `Range#each`.                                                         |
| `end`           | `ASTNode`      | Similar to `Range#end`.                                                          |
| `excludes_end?` | `BoolLiteral`  | Similar to `Range#excludes_end?`.                                                |
| `map(&)`        | `ArrayLiteral` | Like `Enumerable#map` for a range; only for ranges of integer `NumberLiteral`s.  |
| `to_a`          | `ArrayLiteral` | Like `Enumerable#to_a` for a range; only for ranges of integer `NumberLiteral`s. |

### `RegexLiteral`

A regular expression literal, e.g. `/foo/i`.

| Method    | Returns                                | Description                                                |
|-----------|----------------------------------------|------------------------------------------------------------|
| `source`  | `StringLiteral \| StringInterpolation` | Similar to `Regex#source`.                                 |
| `options` | `ArrayLiteral(SymbolLiteral)`          | Like `Regex#options`, but as symbols, e.g. `[:i, :m, :x]`. |

### `TupleLiteral`

A tuple literal, e.g. `{1, "a"}`. Its methods mirror `ArrayLiteral`'s, with tuple-preserving return types.

| Method                                       | Returns                      | Description                                                       |
|----------------------------------------------|------------------------------|-------------------------------------------------------------------|
| `any?(&)`, `all?(&)`                         | `BoolLiteral`                | Similar to `Enumerable#any?` / `#all?`.                           |
| `splat(trailing_string = nil)`               | `MacroId`                    | Elements joined by commas, optional trailing string unless empty. |
| `empty?`                                     | `BoolLiteral`                | Similar to `Tuple#empty?`.                                        |
| `find(&)`                                    | `ASTNode \| NilLiteral`      | Similar to `Enumerable#find`.                                     |
| `first`                                      | `ASTNode \| NilLiteral`      | Like `Tuple#first`, but `NilLiteral` when empty.                  |
| `includes?(node)`                            | `BoolLiteral`                | Similar to `Enumerable#includes?(obj)`.                           |
| `join(separator)`                            | `StringLiteral`              | Similar to `Enumerable#join`.                                     |
| `last`                                       | `ASTNode \| NilLiteral`      | Like `Tuple#last`, but `NilLiteral` when empty.                   |
| `size`                                       | `NumberLiteral`              | Similar to `Tuple#size`.                                          |
| `map(&)`, `map_with_index(&)`                | `TupleLiteral`               | Similar to `Enumerable#map` / `#map_with_index`.                  |
| `each(&)`, `each_with_index(&)`              | `NilLiteral`                 | Similar to `Tuple#each` / `Enumerable#each_with_index`.           |
| `select(&)`, `reject(&)`                     | `TupleLiteral`               | Similar to `Enumerable#select` / `#reject`.                       |
| `reduce(&)`, `reduce(memo, &)`               | `ASTNode`                    | Similar to `Enumerable#reduce`.                                   |
| `shuffle`                                    | `TupleLiteral`               | Similar to `Array#shuffle`.                                       |
| `sort`, `sort_by(&)`                         | `TupleLiteral`               | Similar to `Array#sort` / `#sort_by`.                             |
| `uniq`                                       | `TupleLiteral`               | Similar to `Array#uniq`.                                          |
| `[](index)`                                  | `ASTNode`                    | Similar to `Tuple#[]?(Int)`.                                      |
| `[](range)`                                  | `TupleLiteral \| NilLiteral` | Similar to `Tuple#[]?(Range)`.                                    |
| `[](start, count)`                           | `TupleLiteral \| NilLiteral` | Like `Array#[]?(Int, Int)`, returning a `TupleLiteral`.           |
| `[]=(index, value)`                          | `ASTNode`                    | Similar to `Array#[]=`.                                           |
| `unshift(value)`, `push(value)`, `<<(value)` | `TupleLiteral`               | Similar to `Array#unshift` / `#push` / `#<<`.                     |
| `+(other)`, `-(other)`                       | `TupleLiteral`               | Similar to `Tuple#+` / `Array#-`.                                 |
| `*(other)`                                   | `TupleLiteral`               | Similar to `Tuple#*`.                                             |

## Expression nodes

### `MetaVar`

A fictitious node representing a variable or instance variable together with type information (produced e.g. by `TypeNode#instance_vars`).

| Method               | Returns                    | Description                                                                                                                          |
|----------------------|----------------------------|--------------------------------------------------------------------------------------------------------------------------------------|
| `name`               | `MacroId`                  | The variable's name.                                                                                                                 |
| `type`               | `TypeNode \| NilLiteral`   | The variable's type, if known.                                                                                                       |
| `default_value`      | `ASTNode`                  | The default value. A `NilLiteral` is returned both for "no default" and for a `nil` default — distinguish with `has_default_value?`. |
| `has_default_value?` | `BoolLiteral`              | Whether the variable has a default value (which may itself be `nil`).                                                                |
| `annotation(type)`   | `Annotation \| NilLiteral` | The last `Annotation` of the given type attached to this variable.                                                                   |
| `annotations(type)`  | `ArrayLiteral(Annotation)` | All annotations of the given type attached to this variable.                                                                         |
| `annotations`        | `ArrayLiteral(Annotation)` | All annotations attached to this variable.                                                                                           |

### `Annotation`

An annotation on top of a type or variable, e.g. `@[Field(name: "x")]`.

| Method       | Returns             | Description                                                                                         |
|--------------|---------------------|-----------------------------------------------------------------------------------------------------|
| `name`       | `Path`              | The annotation's name.                                                                              |
| `[](index)`  | `ASTNode`           | Value of a positional argument, or `NilLiteral` if out of bounds.                                   |
| `[](name)`   | `ASTNode`           | Value of a named argument (`SymbolLiteral \| StringLiteral \| MacroId`), or `NilLiteral` if absent. |
| `args`       | `TupleLiteral`      | The positional arguments.                                                                           |
| `named_args` | `NamedTupleLiteral` | The named arguments.                                                                                |

### `Var`

A local variable or block argument.

| Method | Returns   | Description      |
|--------|-----------|------------------|
| `id`   | `MacroId` | This var's name. |

### `Block`

A code block.

| Method        | Returns                       | Description                          |
|---------------|-------------------------------|--------------------------------------|
| `body`        | `ASTNode`                     | The block's body, if any.            |
| `args`        | `ArrayLiteral(MacroId)`       | The block's arguments.               |
| `splat_index` | `NumberLiteral \| NilLiteral` | Index of the splat argument, if any. |

### `Expressions`

A group of expressions.

| Method        | Returns                 | Description                           |
|---------------|-------------------------|---------------------------------------|
| `expressions` | `ArrayLiteral(ASTNode)` | The list of expressions in this node. |

### `Call`

A method call.

| Method       | Returns                       | Description                                                     |
|--------------|-------------------------------|-----------------------------------------------------------------|
| `id`         | `MacroId`                     | This call's name as an identifier.                              |
| `name`       | `MacroId`                     | The method name of this call.                                   |
| `receiver`   | `ASTNode \| Nop`              | This call's receiver, if any.                                   |
| `global?`    | `BoolLiteral`                 | Whether this call refers to a global method (starts with `::`). |
| `args`       | `ArrayLiteral`                | This call's arguments.                                          |
| `named_args` | `ArrayLiteral(NamedArgument)` | This call's named arguments.                                    |
| `block`      | `Block \| Nop`                | This call's block, if any.                                      |
| `block_arg`  | `ASTNode \| Nop`              | This call's block argument, if any.                             |

### `NamedArgument`

A call's named argument.

| Method  | Returns   | Description           |
|---------|-----------|-----------------------|
| `name`  | `MacroId` | The argument's name.  |
| `value` | `ASTNode` | The argument's value. |

### `If`

An `if` expression. (`unless` expressions in regular code are normalized to `If`; see `MacroIf` for macro-level `{% unless %}` — that node records which keyword was used.)

| Method | Returns   | Description               |
|--------|-----------|---------------------------|
| `cond` | `ASTNode` | The condition.            |
| `then` | `ASTNode` | The `then` clause's body. |
| `else` | `ASTNode` | The `else` clause's body. |

### `Assign`

An assignment expression.

| Method   | Returns   | Description               |
|----------|-----------|---------------------------|
| `target` | `ASTNode` | The target assigned to.   |
| `value`  | `ASTNode` | The value being assigned. |

### `MultiAssign`

A multiple-assignment expression.

| Method    | Returns                 | Description                |
|-----------|-------------------------|----------------------------|
| `targets` | `ArrayLiteral(ASTNode)` | The targets assigned to.   |
| `values`  | `ArrayLiteral(ASTNode)` | The values being assigned. |

### `InstanceVar`, `ClassVar`, `Global`

An instance variable, class variable, or global variable.

| Method | Returns   | Description          |
|--------|-----------|----------------------|
| `name` | `MacroId` | The variable's name. |

### `ReadInstanceVar`

Access to an instance variable through a receiver: `obj.@var`.

| Method | Returns   | Description                            |
|--------|-----------|----------------------------------------|
| `obj`  | `ASTNode` | The object whose variable is accessed. |
| `name` | `MacroId` | The instance variable's name.          |

### `BinaryOp` (abstract), `And`, `Or`

A binary expression like `&&` or `||`.

| Method  | Returns   | Description          |
|---------|-----------|----------------------|
| `left`  | `ASTNode` | The left-hand side.  |
| `right` | `ASTNode` | The right-hand side. |

### `Arg`

A `def` argument.

| Method              | Returns                    | Description                                                      |
|---------------------|----------------------------|------------------------------------------------------------------|
| `name`              | `MacroId`                  | The **external** name — for `def write(to file)` returns `to`.   |
| `internal_name`     | `MacroId`                  | The **internal** name — for `def write(to file)` returns `file`. |
| `default_value`     | `ASTNode \| Nop`           | The default value, if any.                                       |
| `restriction`       | `ASTNode \| Nop`           | The type restriction, if any.                                    |
| `annotation(type)`  | `Annotation \| NilLiteral` | The last `Annotation` of the given type.                         |
| `annotations(type)` | `ArrayLiteral(Annotation)` | All annotations of the given type.                               |
| `annotations`       | `ArrayLiteral(Annotation)` | All annotations on this arg.                                     |

### `Def`

A method definition.

| Method              | Returns                       | Description                                             |
|---------------------|-------------------------------|---------------------------------------------------------|
| `name`              | `MacroId`                     | The method's name.                                      |
| `args`              | `ArrayLiteral(Arg)`           | The method's arguments.                                 |
| `splat_index`       | `NumberLiteral \| NilLiteral` | Index of the splat argument, if any.                    |
| `double_splat`      | `Arg \| Nop`                  | The double splat argument, if any.                      |
| `block_arg`         | `Arg \| Nop`                  | The block argument, if any.                             |
| `accepts_block?`    | `BoolLiteral`                 | Whether this method can be called with a block.         |
| `return_type`       | `ASTNode \| Nop`              | The declared return type, if any.                       |
| `free_vars`         | `ArrayLiteral(MacroId)`       | The method's free variables (empty if none).            |
| `body`              | `ASTNode`                     | The method's body.                                      |
| `receiver`          | `ASTNode \| Nop`              | The receiver (e.g. `self`), or `Nop`.                   |
| `abstract?`         | `BoolLiteral`                 | Whether the method is declared `abstract`.              |
| `visibility`        | `SymbolLiteral`               | `:public`, `:protected` or `:private`.                  |
| `annotation(type)`  | `Annotation \| NilLiteral`    | The last `Annotation` of the given type on this method. |
| `annotations(type)` | `ArrayLiteral(Annotation)`    | All annotations of the given type on this method.       |
| `annotations`       | `ArrayLiteral(Annotation)`    | All annotations on this method.                         |

### `Primitive`

A fictitious node representing the body of a `Def` marked with `@[Primitive]`.

| Method | Returns         | Description                                                                                                     |
|--------|-----------------|-----------------------------------------------------------------------------------------------------------------|
| `name` | `SymbolLiteral` | The primitive's name — identical to the `@[Primitive]` argument: `{{ Foo.methods.first.body.name }} # => :abc`. |

### `Macro`

A macro definition.

| Method         | Returns                       | Description                            |
|----------------|-------------------------------|----------------------------------------|
| `name`         | `MacroId`                     | The macro's name.                      |
| `args`         | `ArrayLiteral(Arg)`           | The macro's arguments.                 |
| `splat_index`  | `NumberLiteral \| NilLiteral` | Index of the splat argument, if any.   |
| `double_splat` | `Arg \| Nop`                  | The double splat argument, if any.     |
| `block_arg`    | `Arg \| Nop`                  | The block argument, if any.            |
| `body`         | `ASTNode`                     | The macro's body.                      |
| `visibility`   | `SymbolLiteral`               | `:public`, `:protected` or `:private`. |

### `UnaryExpression` (abstract)

Base of unary expressions; subclasses: `Not` (`!`), `PointerOf` (`pointerof`), `SizeOf` (`sizeof`), `InstanceSizeOf` (`instance_sizeof`), `AlignOf` (`alignof`), `InstanceAlignOf` (`instance_alignof`), `Out` (`out`), `Splat` (`*exp`), `DoubleSplat` (`**exp`), and `MacroVerbatim`.

| Method | Returns   | Description                              |
|--------|-----------|------------------------------------------|
| `exp`  | `ASTNode` | The expression the operation applies to. |

### `OffsetOf`

An `offsetof` expression.

| Method   | Returns   | Description                                 |
|----------|-----------|---------------------------------------------|
| `type`   | `ASTNode` | The type used in the expression.            |
| `offset` | `ASTNode` | The offset argument used in the expression. |

### `VisibilityModifier`

A visibility modifier (`private def foo`, …).

| Method       | Returns         | Description                             |
|--------------|-----------------|-----------------------------------------|
| `visibility` | `SymbolLiteral` | `:public`, `:protected` or `:private`.  |
| `exp`        | `ASTNode`       | The expression the modifier applies to. |

### `IsA`

An `.is_a?` or `.nil?` call.

| Method     | Returns   | Description          |
|------------|-----------|----------------------|
| `receiver` | `ASTNode` | The call's receiver. |
| `arg`      | `ASTNode` | The call's argument. |

### `RespondsTo`

A `.responds_to?` call.

| Method     | Returns         | Description                    |
|------------|-----------------|--------------------------------|
| `receiver` | `ASTNode`       | The call's receiver.           |
| `name`     | `StringLiteral` | The method name being checked. |

### `Require`

A `require` statement.

| Method | Returns         | Description                    |
|--------|-----------------|--------------------------------|
| `path` | `StringLiteral` | The argument of the `require`. |

### `When`

A `when` or `in` inside a `case` or `select`.

| Method        | Returns        | Description                          |
|---------------|----------------|--------------------------------------|
| `conds`       | `ArrayLiteral` | The conditions of this `when`.       |
| `body`        | `ASTNode`      | The body of this `when`.             |
| `exhaustive?` | `BoolLiteral`  | `true` for `in`, `false` for `when`. |

### `Case`

A `case` expression.

| Method        | Returns              | Description                                  |
|---------------|----------------------|----------------------------------------------|
| `cond`        | `ASTNode`            | The condition (target) of the `case`.        |
| `whens`       | `ArrayLiteral(When)` | The `when`s.                                 |
| `else`        | `ASTNode`            | The `else`.                                  |
| `exhaustive?` | `BoolLiteral`        | Whether this is an exhaustive `case ... in`. |

### `Select`

A `select` expression.

| Method  | Returns              | Description  |
|---------|----------------------|--------------|
| `whens` | `ArrayLiteral(When)` | The `when`s. |
| `else`  | `ASTNode`            | The `else`.  |

### `ImplicitObj`

The implicit object in a `case ... when .bar?` condition. Adds no methods.

### `While`

A `while` expression. (`until` is normalized to `While` with a negated condition.)

| Method | Returns   | Description    |
|--------|-----------|----------------|
| `cond` | `ASTNode` | The condition. |
| `body` | `ASTNode` | The body.      |

### `Rescue`

A `rescue` clause inside an exception handler.

| Method  | Returns                      | Description                                         |
|---------|------------------------------|-----------------------------------------------------|
| `body`  | `ASTNode`                    | The clause's body.                                  |
| `types` | `ArrayLiteral \| NilLiteral` | The rescued exception types, if any.                |
| `name`  | `MacroId \| Nop`             | The variable name of the rescued exception, if any. |

### `ExceptionHandler`

A `begin ... end` expression with `rescue`/`else`/`ensure` clauses.

| Method    | Returns                              | Description                       |
|-----------|--------------------------------------|-----------------------------------|
| `body`    | `ASTNode`                            | The main body.                    |
| `rescues` | `ArrayLiteral(Rescue) \| NilLiteral` | The `rescue` clauses, if any.     |
| `else`    | `ASTNode \| Nop`                     | The `else` clause body, if any.   |
| `ensure`  | `ASTNode \| Nop`                     | The `ensure` clause body, if any. |

### `ProcLiteral`

A proc literal: `->(arg : String) { puts arg }`.

| Method        | Returns             | Description                       |
|---------------|---------------------|-----------------------------------|
| `args`        | `ArrayLiteral(Arg)` | The proc's arguments.             |
| `body`        | `ASTNode`           | The proc's body.                  |
| `return_type` | `ASTNode \| Nop`    | The declared return type, if any. |

### `ProcPointer`

A proc pointer: `->my_var.some_method(String)`.

| Method    | Returns                 | Description                                                                  |
|-----------|-------------------------|------------------------------------------------------------------------------|
| `args`    | `ArrayLiteral(ASTNode)` | The argument types.                                                          |
| `obj`     | `ASTNode \| NilLiteral` | The receiver, or `nil` if unattached.                                        |
| `name`    | `MacroId`               | The method this proc points to.                                              |
| `global?` | `BoolLiteral`           | Whether it refers to a global method (starts with `::` and has no receiver). |

### `Self`

The `self` expression, in code or type names. Adds no methods.

### `ControlExpression` (abstract), `Return`, `Break`, `Next`

Base of control-flow expressions.

| Method | Returns          | Description                                                                      |
|--------|------------------|----------------------------------------------------------------------------------|
| `exp`  | `ASTNode \| Nop` | The argument, if any. Multiple arguments are wrapped in a single `TupleLiteral`. |

### `Yield`

A `yield` expression.

| Method        | Returns          | Description                                                         |
|---------------|------------------|---------------------------------------------------------------------|
| `expressions` | `ArrayLiteral`   | The arguments to the `yield`.                                       |
| `scope`       | `ASTNode \| Nop` | The scope — the part after `with` in a `with ... yield` expression. |

### `Include` / `Extend`

An `include` or `extend` statement.

| Method | Returns   | Description                                   |
|--------|-----------|-----------------------------------------------|
| `name` | `ASTNode` | The name of the type being included/extended. |

### `Alias`

An `alias` statement.

| Method | Returns   | Description                           |
|--------|-----------|---------------------------------------|
| `name` | `Path`    | The alias's name.                     |
| `type` | `ASTNode` | The type this alias is equivalent to. |

### `Cast` / `NilableCast`

A cast call: `obj.as(to)` / `obj.as?(to)`.

| Method | Returns   | Description                  |
|--------|-----------|------------------------------|
| `obj`  | `ASTNode` | The object being cast.       |
| `to`   | `ASTNode` | The target type of the cast. |

### `TypeOf`

A `typeof` expression.

| Method | Returns                 | Description                    |
|--------|-------------------------|--------------------------------|
| `args` | `ArrayLiteral(ASTNode)` | The arguments to the `typeof`. |

## Definition nodes

### `ClassDef`

A class or struct definition.

| Method                     | Returns                       | Description                                                                                                                                                                              |
|----------------------------|-------------------------------|------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| `abstract?`                | `BoolLiteral`                 | Whether this defines an abstract class or struct.                                                                                                                                        |
| `kind`                     | `MacroId`                     | The keyword used: `class` or `struct`.                                                                                                                                                   |
| `name(generic_args: true)` | `Path \| Generic`             | The type's name. With *generic_args* true and a generic definition, returns a `Generic` whose arguments are `MacroId`s (possibly with a `Splat` at the splat index); otherwise a `Path`. |
| `superclass`               | `ASTNode`                     | The superclass, or `Nop` if unspecified.                                                                                                                                                 |
| `body`                     | `ASTNode`                     | The definition's body.                                                                                                                                                                   |
| `type_vars`                | `ArrayLiteral`                | `MacroId`s of the generic type parameters (empty for non-generics).                                                                                                                      |
| `splat_index`              | `NumberLiteral \| NilLiteral` | Splat index of the generic type parameters, or `nil` if not generic / no splat.                                                                                                          |
| `struct?`                  | `BoolLiteral`                 | Whether this defines a struct (`false` for a class).                                                                                                                                     |

### `ModuleDef`

A module definition.

| Method                     | Returns                       | Description                                           |
|----------------------------|-------------------------------|-------------------------------------------------------|
| `kind`                     | `MacroId`                     | Always `module`.                                      |
| `name(generic_args: true)` | `Path \| Generic`             | Same contract as `ClassDef#name`.                     |
| `body`                     | `ASTNode`                     | The definition's body.                                |
| `type_vars`                | `ArrayLiteral`                | Generic type parameters (empty for non-generics).     |
| `splat_index`              | `NumberLiteral \| NilLiteral` | Splat index of the generic type parameters, or `nil`. |

### `EnumDef`

An enum definition.

| Method                     | Returns   | Description                                                                     |
|----------------------------|-----------|---------------------------------------------------------------------------------|
| `kind`                     | `MacroId` | Always `enum`.                                                                  |
| `name(generic_args: true)` | `Path`    | The enum's name (*generic_args* has no effect; it exists for interface parity). |
| `base_type`                | `ASTNode` | The enum's base type, or `Nop` if unspecified.                                  |
| `body`                     | `ASTNode` | The definition's body.                                                          |

### `AnnotationDef`

An annotation definition.

| Method                     | Returns   | Description                                                    |
|----------------------------|-----------|----------------------------------------------------------------|
| `kind`                     | `MacroId` | Always `annotation`.                                           |
| `name(generic_args: true)` | `Path`    | The annotation's name (*generic_args* has no effect).          |
| `body`                     | `Nop`     | Always `Nop` — annotation definitions cannot contain anything. |

### `LibDef`

A lib definition.

| Method                     | Returns   | Description                                    |
|----------------------------|-----------|------------------------------------------------|
| `kind`                     | `MacroId` | Always `lib`.                                  |
| `name(generic_args: true)` | `Path`    | The lib's name (*generic_args* has no effect). |
| `body`                     | `ASTNode` | The definition's body.                         |

### `CStructOrUnionDef`

A struct or union definition inside a lib.

| Method                     | Returns       | Description                                     |
|----------------------------|---------------|-------------------------------------------------|
| `union?`                   | `BoolLiteral` | Whether this defines a C union.                 |
| `kind`                     | `MacroId`     | `struct` or `union`.                            |
| `name(generic_args: true)` | `Path`        | The type's name (*generic_args* has no effect). |
| `body`                     | `ASTNode`     | The definition's body.                          |

### `FunDef`

A function declaration inside a lib, or a top-level C function definition.

| Method        | Returns                | Description                                                                                           |
|---------------|------------------------|-------------------------------------------------------------------------------------------------------|
| `name`        | `MacroId`              | The function's name in Crystal.                                                                       |
| `real_name`   | `StringLiteral \| Nop` | The real C name, if any.                                                                              |
| `args`        | `ArrayLiteral(Arg)`    | The parameters (excluding the variadic parameter).                                                    |
| `variadic?`   | `BoolLiteral`          | Whether the function is variadic.                                                                     |
| `return_type` | `ASTNode \| Nop`       | The return type, if specified.                                                                        |
| `body`        | `ASTNode \| Nop`       | The body, if any. Both lib funs and top-level funs may return `Nop` — use `has_body?` to distinguish. |
| `has_body?`   | `BoolLiteral`          | Top-level funs have a body; lib funs do not.                                                          |

### `TypeDef`

A typedef inside a lib: `type Foo = Bar`.

| Method | Returns   | Description                             |
|--------|-----------|-----------------------------------------|
| `name` | `Path`    | The typedef's name.                     |
| `type` | `ASTNode` | The type this typedef is equivalent to. |

### `ExternalVar`

An external variable declaration inside a lib.

| Method      | Returns                | Description                                              |
|-------------|------------------------|----------------------------------------------------------|
| `name`      | `MacroId`              | The variable's name in Crystal, without the leading `$`. |
| `real_name` | `StringLiteral \| Nop` | The real C name, if any.                                 |
| `type`      | `ASTNode`              | The variable's type.                                     |

## Type grammar nodes

These nodes appear in type positions — restrictions, declarations, generic arguments — and in the result of `parse_type`.

### `Path`

A path to a constant or type: `Foo`, `Foo::Bar::Baz`.

| Method     | Returns                 | Description                                                                                                                  |
|------------|-------------------------|------------------------------------------------------------------------------------------------------------------------------|
| `names`    | `ArrayLiteral(MacroId)` | Each separate part of the path.                                                                                              |
| `global?`  | `BoolLiteral`           | Whether this is a global path (starts with `::`).                                                                            |
| `global`   | `BoolLiteral`           | **Deprecated** — use `global?`.                                                                                              |
| `resolve`  | `ASTNode`               | Resolves to a `TypeNode` for a type, to the constant's value for a constant; compile-time error otherwise.                   |
| `resolve?` | `ASTNode \| NilLiteral` | Like `resolve`, but returns `NilLiteral` on failure.                                                                         |
| `types`    | `ArrayLiteral(ASTNode)` | This path inside an array literal — lets you call `types` uniformly on any type grammar node (`Generic`, `Path` or `Union`). |

### `Generic`

A generic instantiation: `Foo(T)`, `Foo::Bar::Baz(T)`.

| Method       | Returns                           | Description                                                              |
|--------------|-----------------------------------|--------------------------------------------------------------------------|
| `name`       | `Path`                            | The path to the generic.                                                 |
| `type_vars`  | `ArrayLiteral(ASTNode)`           | The type arguments of the instantiation.                                 |
| `named_args` | `NamedTupleLiteral \| NilLiteral` | The named arguments, if any.                                             |
| `resolve`    | `ASTNode`                         | Resolves to a `TypeNode`; compile-time error otherwise.                  |
| `resolve?`   | `ASTNode \| NilLiteral`           | Like `resolve`, but `NilLiteral` on failure.                             |
| `types`      | `ArrayLiteral(ASTNode)`           | This generic inside an array literal (uniform access, see `Path#types`). |

### `ProcNotation`

The type of a proc or block argument: `String -> Int32`.

| Method     | Returns                 | Description                                             |
|------------|-------------------------|---------------------------------------------------------|
| `inputs`   | `ArrayLiteral(ASTNode)` | The argument types (empty if none).                     |
| `output`   | `ASTNode \| NilLiteral` | The output type, or `nil` if there is no return type.   |
| `resolve`  | `ASTNode`               | Resolves to a `TypeNode`; compile-time error otherwise. |
| `resolve?` | `ASTNode \| NilLiteral` | Like `resolve`, but `NilLiteral` on failure.            |

### `Union`

A type union: `(Int32 | String)`.

| Method     | Returns                 | Description                                                                   |
|------------|-------------------------|-------------------------------------------------------------------------------|
| `types`    | `ArrayLiteral(ASTNode)` | The types of this union.                                                      |
| `resolve`  | `ASTNode`               | Resolves to a `TypeNode`; compile-time error if any member can't be resolved. |
| `resolve?` | `ASTNode \| NilLiteral` | Like `resolve`, but `NilLiteral` on failure.                                  |

### `Metaclass`

A metaclass in a type expression: `T.class`.

| Method     | Returns                 | Description                                                |
|------------|-------------------------|------------------------------------------------------------|
| `instance` | `ASTNode`               | The node representing the instance type of this metaclass. |
| `resolve`  | `ASTNode`               | Resolves to a `TypeNode`; compile-time error otherwise.    |
| `resolve?` | `ASTNode \| NilLiteral` | Like `resolve`, but `NilLiteral` on failure.               |

### `TypeDeclaration`

A type declaration: `x : Int32`.

| Method  | Returns          | Description                 |
|---------|------------------|-----------------------------|
| `var`   | `MacroId`        | The variable part.          |
| `type`  | `ASTNode`        | The type part.              |
| `value` | `ASTNode \| Nop` | The assigned value, if any. |

### `UninitializedVar`

An uninitialized declaration: `a = uninitialized Int32`.

| Method | Returns   | Description        |
|--------|-----------|--------------------|
| `var`  | `MacroId` | The variable part. |
| `type` | `ASTNode` | The type part.     |

## Macro-internal nodes

Nodes produced by parsing macro syntax itself.

### `MacroExpression`

A `{{ ... }}` or `{% ... %}` expression.

| Method    | Returns       | Description                                                                                   |
|-----------|---------------|-----------------------------------------------------------------------------------------------|
| `exp`     | `ASTNode`     | The expression inside this node.                                                              |
| `output?` | `BoolLiteral` | Whether this node interpolates the result (`{{ }}`) rather than just evaluating it (`{% %}`). |

### `MacroLiteral`

Free text that is part of a macro.

| Method  | Returns   | Description              |
|---------|-----------|--------------------------|
| `value` | `MacroId` | The text of the literal. |

### `MacroIf`

An `{% if %}` / `{% unless %}` inside a macro.

| Method       | Returns       | Description                               |
|--------------|---------------|-------------------------------------------|
| `cond`       | `ASTNode`     | The condition.                            |
| `then`       | `ASTNode`     | The `then` branch.                        |
| `else`       | `ASTNode`     | The `else` branch.                        |
| `is_unless?` | `BoolLiteral` | Whether this node represents an `unless`. |

### `MacroFor`

A `{% for x in exp %}` loop inside a macro.

| Method | Returns             | Description                         |
|--------|---------------------|-------------------------------------|
| `vars` | `ArrayLiteral(Var)` | The variables declared after `for`. |
| `exp`  | `ASTNode`           | The expression after `in`.          |
| `body` | `ASTNode`           | The loop body.                      |

### `MacroVar`

A macro fresh variable (`%var`, optionally indexed `%var{0}`).

| Method        | Returns        | Description                                   |
|---------------|----------------|-----------------------------------------------|
| `name`        | `MacroId`      | The fresh variable's name.                    |
| `expressions` | `ArrayLiteral` | The associated indices of the fresh variable. |

### `MacroVerbatim`

A `{% verbatim do %} ... {% end %}` expression. A `UnaryExpression` — the inner expression is available via `exp`.

### `Underscore`

The `_` expression, in code (e.g. an assignment target) and in type names. Adds no methods.

### `MagicConstant`

A pseudo constant carrying source-location information: `__FILE__`, `__LINE__`, `__DIR__`. Usually resolved by the compiler; appears unresolved as a default parameter value. Adds no methods.

### `Asm`

An inline assembly expression.

| Method        | Returns                       | Description                                                          |
|---------------|-------------------------------|----------------------------------------------------------------------|
| `text`        | `StringLiteral`               | The template string.                                                 |
| `outputs`     | `ArrayLiteral(AsmOperand)`    | The output operands.                                                 |
| `inputs`      | `ArrayLiteral(AsmOperand)`    | The input operands.                                                  |
| `clobbers`    | `ArrayLiteral(StringLiteral)` | Clobbered register names.                                            |
| `volatile?`   | `BoolLiteral`                 | Whether there are side effects beyond `outputs`/`inputs`/`clobbers`. |
| `alignstack?` | `BoolLiteral`                 | Whether stack alignment code is required.                            |
| `intel?`      | `BoolLiteral`                 | Whether the template uses Intel syntax (`false` = AT&T).             |
| `can_throw?`  | `BoolLiteral`                 | Whether the expression might unwind the stack.                       |

### `AsmOperand`

An output or input operand of an `Asm` node.

| Method       | Returns         | Description                              |
|--------------|-----------------|------------------------------------------|
| `constraint` | `StringLiteral` | The constraint string.                   |
| `exp`        | `ASTNode`       | The associated output or input argument. |

## `MacroId`

A fictitious node representing an identifier like `foo`, `Bar` or `something_else`. The parser never creates these; you create them by calling `id` on a `StringLiteral`, `SymbolLiteral`, `Call`, `Var` or `Path`. This lets strings, symbols, variables and calls be treated uniformly when generating names.

`MacroId` supports the full [shared string method set](#string-like-nodes-stringliteral-symbolliteral-macroid) plus `>` and `<` comparisons.

## `TypeNode`

Represents an actual type in the program, like `Int32` or `String`. Obtained via `@type`, `@def`, resolving a `Path`/`Generic`/`Union`/`Metaclass`/`ProcNotation`, or type introspection methods.

### Kind predicates

| Method      | Returns       | Description                                           |
|-------------|---------------|-------------------------------------------------------|
| `abstract?` | `BoolLiteral` | Whether the type is abstract.                         |
| `union?`    | `BoolLiteral` | Whether this is a union type. See also `union_types`. |
| `nilable?`  | `BoolLiteral` | Whether `nil` is an instance of this type.            |
| `module?`   | `BoolLiteral` | Whether this is a `module`.                           |
| `class?`    | `BoolLiteral` | Whether this is a `class`.                            |
| `struct?`   | `BoolLiteral` | Whether this is a `struct`.                           |

### Name and structure

| Method                     | Returns                  | Description                                                                                                  |
|----------------------------|--------------------------|--------------------------------------------------------------------------------------------------------------|
| `name(generic_args: true)` | `MacroId`                | Fully qualified name; without generic arguments if `generic_args: false`. `{{Foo.name}} # => Foo(T)`.        |
| `type_vars`                | `ArrayLiteral(TypeNode)` | The type variables of a generic type (empty for non-generics).                                               |
| `union_types`              | `ArrayLiteral(TypeNode)` | The types forming the union; for non-unions, this type in a single-element array — safe to call on any type. |
| `size`                     | `NumberLiteral`          | Number of elements in a tuple type or tuple metaclass type; compile error otherwise.                         |
| `keys`                     | `ArrayLiteral(MacroId)`  | Keys of a named tuple type; compile error otherwise.                                                         |
| `[](key)`                  | `TypeNode \| NilLiteral` | The type for a key in a named tuple type (`SymbolLiteral \| MacroId`); compile error otherwise.              |

### Hierarchy and members

| Method                     | Returns                  | Description                                                                                                |
|----------------------------|--------------------------|------------------------------------------------------------------------------------------------------------|
| `ancestors`                | `ArrayLiteral(TypeNode)` | All ancestors of this type.                                                                                |
| `superclass`               | `TypeNode \| NilLiteral` | The direct superclass.                                                                                     |
| `subclasses`               | `ArrayLiteral(TypeNode)` | The direct subclasses.                                                                                     |
| `all_subclasses`           | `ArrayLiteral(TypeNode)` | All subclasses (reliable inside `macro finished`).                                                         |
| `includers`                | `ArrayLiteral(TypeNode)` | All types this type is directly included in.                                                               |
| `constants`                | `ArrayLiteral(MacroId)`  | Constants and types defined by this type.                                                                  |
| `constant(name)`           | `ASTNode`                | A constant defined in this type: its value as an `ASTNode`, a `TypeNode` if it's a type, or `NilLiteral`.  |
| `has_constant?(name)`      | `BoolLiteral`            | Whether this type has the constant (`"DEFAULT_OPTIONS"` or `:DEFAULT_OPTIONS`).                            |
| `instance_vars`            | `ArrayLiteral(MetaVar)`  | Instance variables of this type. Only from within methods — returns an empty list at top level.            |
| `class_vars`               | `ArrayLiteral(MetaVar)`  | Class variables of this type.                                                                              |
| `methods`                  | `ArrayLiteral(Def)`      | Instance methods defined by this type, excluding inherited ones.                                           |
| `all_methods`              | `ArrayLiteral(Def)`      | Instance methods including those inherited from ancestors and base types (`Reference`, `Value`, `Object`). |
| `has_method?(name)`        | `BoolLiteral`            | Whether this type has the method (`"default_options"` or `:default_options`).                              |
| `overrides?(type, method)` | `BoolLiteral`            | Whether this type overrides *method* from *type*: `{{ Bar.overrides?(Foo, "one") }}`.                      |

### Annotations and visibility

| Method              | Returns                    | Description                                           |
|---------------------|----------------------------|-------------------------------------------------------|
| `annotation(type)`  | `Annotation \| NilLiteral` | The last `Annotation` of the given type on this type. |
| `annotations(type)` | `ArrayLiteral(Annotation)` | All annotations of the given type on this type.       |
| `annotations`       | `ArrayLiteral(Annotation)` | All annotations on this type.                         |
| `private?`          | `BoolLiteral`              | Whether this type is private.                         |
| `public?`           | `BoolLiteral`              | Whether this type is public.                          |
| `visibility`        | `SymbolLiteral`            | `:public` or `:private`.                              |

### Class/instance relationship and resolution

| Method     | Returns    | Description                                                                           |
|------------|------------|---------------------------------------------------------------------------------------|
| `class`    | `TypeNode` | The class of this type — e.g. `type.class.methods` gives class methods.               |
| `instance` | `TypeNode` | The instance type if this is a class type, or `self` otherwise. Opposite of `#class`. |
| `resolve`  | `TypeNode` | Returns `self` — lets you call `resolve` on any node that might already be a type.    |
| `resolve?` | `TypeNode` | Returns `self` — same purpose as `resolve`.                                           |

### Comparison operators

| Method      | Returns       | Description                                                                      |
|-------------|---------------|----------------------------------------------------------------------------------|
| `<(other)`  | `BoolLiteral` | Whether *other* is an ancestor of this type.                                     |
| `<=(other)` | `BoolLiteral` | Whether this type is the same as *other* or *other* is an ancestor.              |
| `>(other)`  | `BoolLiteral` | Whether this type is an ancestor of *other*.                                     |
| `>=(other)` | `BoolLiteral` | Whether *other* is the same as this type or this type is an ancestor of *other*. |

### Memory layout

| Method                | Returns       | Description                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                      |
|-----------------------|---------------|--------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| `has_inner_pointers?` | `BoolLiteral` | Whether the type contains any inner pointers. Primitive types (except `Void`) do not; `Proc` and `Pointer` do; unions, structs, tuples and static arrays do if any member does; classes do. Types without inner pointers may use atomic allocation (`GC.malloc_atomic`): `Pointer(T).malloc` is atomic iff `T` has no inner pointers, and `T.allocate` is atomic iff `T` is a reference type and `ReferenceStorage(T)` has no inner pointers. Like `instance_vars`, must be called from within a method — results may be incorrect at top level. |
