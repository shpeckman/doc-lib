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

`macro finished`  
The main type hierarchy is known; the last expansion phase before codegen.  
Ideal for generating code that needs `all_subclasses`, `all_methods`, etc.  

`macro inherited`  
A type is subclassed.  

`macro included`  
A module is included into a type.  

`macro extended`  
A module is used with `extend`.  

`macro method_missing(call)`  
An unknown method is called on the type (receives the `Call` node).  

`macro method_added(def)`  
A method is defined in the type (receives the `Def` node).  

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

`{{ flag?(:x86_64) }}` / `host_flag?`  
test compile-time flags (target vs host, which differ under cross-compilation).  

`{{ env("HOME") }}`  
read an environment variable at compile time.  

`read_file(path)` / `read_file?(path)` / `file_exists?(path)`  
embed external files (use `"#{__DIR__}/..."` for paths relative to the current source file).  

`{{ run("./gen", arg) }}`  
compile and run a Crystal helper program at compile time and embed its output.  
Powerful (arbitrary file/network access) but slow and cached by mtime; keep run programs deterministic and fast.  

`{{ system("git rev-parse HEAD") }}` or backtick literals  
run a shell command.  

`{% skip_file unless flag?(:darwin) %}`  
skip the rest of the current file.  

`{{ compare_versions(Crystal::VERSION, "1.0.0") }}`  
semver comparison for version-dependent code.  


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

Each entry is a method signature followed by a description of what it returns and any caveats. Return types are written as AST node names.

## Top-level methods

These are invoked without a receiver anywhere `{{ }}` / `{% %}` is allowed.

`compare_versions(v1, v2)`  
Compares two semantic versions; returns a `NumberLiteral` of `-1`, `0` or `1`.  
`{{ compare_versions(Crystal::VERSION, "1.0.0") }}`

`debug(format = true)`  
Outputs the current macro's buffer to stdout; formatted unless `format: false`. Returns `Nop`.

`env(name)`  
Value of an environment variable at compile time as a `StringLiteral`, or `NilLiteral`.  
`{{ env("HOME") }}`

`flag?(name)`  
Whether a compile-time flag is set for the **target** platform; `BoolLiteral`.  
`{{ flag?(:x86_64) }}`

`host_flag?(name)`  
Whether a compile-time flag is set for the **host** platform; `BoolLiteral`. Differs from `flag?` when cross-compiling.

`parse_type(type_name)`  
Parses a string into a type grammar node (`Path`, `Generic`, `ProcNotation` or `Metaclass`); use `#resolve` on the result. Compile-time error if the type/constant doesn't exist or a generic argument is missing.  
`parse_type("Foo(Int32)")`

`puts(*expressions)`, `print(*expressions)`  
Prints AST nodes at compile time (debugging). Returns `Nop`.

`p(*expressions)`, `pp(*expressions)`  
Same as `puts`.

`p!(*expressions)`, `pp!(*expressions)`  
Prints macro expressions together with their values. Returns `Nop`.

`` `(command) ``  
Executes a system command and returns its output as a `MacroId`; compile-time error on failure. Invoked via command literals: `` {{ `echo hi` }} ``.

`system(command)`  
Same as the backtick form: `{{ system("echo hi") }}`.

`raise(message)`  
Gives a compile-time error with the message. `NoReturn`.

`warning(message)`  
Emits a compile-time warning. Returns `NilLiteral`.

`file_exists?(filename)`  
Whether the given file exists; `BoolLiteral`.

`read_file(filename)`  
Reads a file as a `StringLiteral`; compile-time error if missing/unreadable. Relative paths resolve against the current working directory — prefer `"#{__DIR__}/file"`.

`read_file?(filename)`  
Like `read_file`, but returns `NilLiteral` on any I/O failure.

`run(filename, *args)`  
Compiles and executes a Crystal program, returning its output as a `MacroId`. The compiler may cache the executable (recompiling only on dependency mtime changes); keep the program deterministic and fast.

`skip_file`  
Skips the rest of the file it is executed in: `{% skip_file unless flag?(:darwin) %}`. Returns `Nop`.

`sizeof(type)`  
Size of a *stable* type in bytes; `NumberLiteral`. `type` must be a constant; not evaluable at macro time nor a `typeof`.

`alignof(type)`  
Alignment of a *stable* type in bytes; `NumberLiteral`. Same restrictions as `sizeof`.

A type is **stable** for `sizeof`/`alignof` if its size and alignment cannot change as new code is processed. All types are stable except: structs (e.g. `Bytes`), `ReferenceStorage` instances, modules (e.g. `Math` — but `Math.class` is stable), uninstantiated generics (e.g. `Array`), `StaticArray`/`Tuple`/`NamedTuple` with unstable element types, and unions containing unstable types.

## `ASTNode` (base of all nodes)

The base class of all AST nodes; these methods are available on **every** node listed below.

`id`  
This node as a `MacroId`. Useful to get an identifier out of a `StringLiteral`, `SymbolLiteral`, `Var` or `Call`.

`stringify`  
This node's textual representation as a `StringLiteral`. On a string literal the result still contains the quotes.

`symbolize`  
This node's textual representation as a `SymbolLiteral`: `{{ "foo".id.symbolize }} # => :foo`.

`class_name`  
This node's class name, e.g. `"StringLiteral"`; `StringLiteral`.

`filename`  
Filename where this node is located, if known; `StringLiteral | NilLiteral`.

`line_number`  
Line where this node begins (1-based), if known; `StringLiteral | NilLiteral`.

`column_number`  
Column where this node begins (1-based), if known; `StringLiteral | NilLiteral`.

`end_line_number`  
Line where this node ends (1-based), if known; `StringLiteral | NilLiteral`.

`end_column_number`  
Column where this node ends (1-based), if known; `StringLiteral | NilLiteral`.

`==(other)`  
Whether this node's textual representation equals *other*'s; `BoolLiteral`.

`!=(other)`  
Whether this node's textual representation differs from *other*'s; `BoolLiteral`.

`raise(message)`  
Compile-time error highlighting this node. `NoReturn`.

`warning(message)`  
Compile-time warning highlighting this node. Returns `NilLiteral`.

`doc`  
Documentation comments attached to this node, or `""`; `StringLiteral`. Empty outside of `crystal docs`.

`doc_comment`  
Documentation comments, each line prefixed with `#` so the output can be spliced into another node's docs (see *merging expansion and call comments*); `MacroId`. Empty outside of `crystal docs`.

`is_a?(type)`  
Whether this node's type is the given **AST node** type (or a subclass); `BoolLiteral`. `{{ 1.is_a?(NumberLiteral) }} # => true`. Never refers to program types.

`nil?`  
Whether this node is a `NilLiteral` or `Nop`; `BoolLiteral`.

## Literal nodes

### `Nop`

The empty node. Similar to `NilLiteral`, but its textual representation is the empty string — e.g. the missing `else` branch of an `if` without `else`. Adds no methods.

### `NilLiteral`

The `nil` literal. Adds no methods.

### `BoolLiteral`

A `true`/`false` literal. Adds no methods.

### `NumberLiteral`

Any number literal.

`zero?`  
Whether the value is `0`; `BoolLiteral`.

`<`, `<=`, `>`, `>=`  
Value comparison against another `NumberLiteral`; `BoolLiteral`.

`<=>(other)`  
Comparison returning `-1`, `0` or `1`; `NumberLiteral`.

`+`, `-`, `*`  
Same as `Number#+`, `Number#-`, `Number#*`; `NumberLiteral`.

`//`, `%`  
Same as `Number#//`, `Number#%`; `NumberLiteral`. Note: `/` (exact float division) is **not** available on `NumberLiteral` — use `//` (floored division), which works for integer literals.

`&`, `|`, `^`  
Bitwise operators; `NumberLiteral`.

`**`  
Same as `Number#**`; `NumberLiteral`.

`<<`, `>>`  
Shift operators; `NumberLiteral`.

unary `+`, unary `-`, `~`  
Unary operators; `NumberLiteral`.

`kind`  
The literal's type suffix: `:i32`, `:u16`, `:f32`, `:f64`, etc.; `SymbolLiteral`.

`to_number`  
The value without a type suffix; `MacroId`.

### `CharLiteral`

A character literal.

`id`  
This character's contents; `MacroId`.

`ord`  
Similar to `Char#ord`; `NumberLiteral`.

### String-like nodes: `StringLiteral`, `SymbolLiteral`, `MacroId`

These three node types share one set of string methods (the compiler defines them once and mixes them into all three classes; return types written `Self`-like below return the receiver's own node type). They are listed here once.

`id`  
A `MacroId` for this string's contents.

`[](range)`  
Similar to `String#[]`; `Self`.

`=~(regex)`  
Similar to `String#matches?`; `BoolLiteral`.

`+(other)`  
Similar to `String#+` (other: `StringLiteral | CharLiteral`); `Self`.

`camelcase(lower: false)`  
Similar to `String#camelcase`; `Self`.

`capitalize`  
Similar to `String#capitalize`; `Self`.

`chars`  
Similar to `String#chars`; `ArrayLiteral(CharLiteral)`.

`chomp`  
Similar to `String#chomp`; `Self`.

`count(other)`  
Similar to `String#count`; `NumberLiteral`.

`downcase`  
Similar to `String#downcase`; `Self`.

`empty?`  
Similar to `String#empty?`; `BoolLiteral`.

`ends_with?(other)`  
Similar to `String#ends_with?`; `BoolLiteral`.

`gsub(regex, &block)`  
Similar to `String#gsub(pattern, options, &)`; `Self`. The special variables `$~`, `$1`, … are **not** supported; the block receives the match string and an `ArrayLiteral(StringLiteral | NilLiteral)` of captures.

`gsub(regex, replacement)`  
Similar to `String#gsub`; `Self`.

`includes?(search)`  
Similar to `String#includes?`; `BoolLiteral`.

`match(regex)`  
Capture hash for the match (same form as `Regex::MatchData#to_h`), or `nil`; `HashLiteral(NumberLiteral | StringLiteral, StringLiteral | NilLiteral)`.

`scan(regex)`  
A capture hash per match of *regex*; `ArrayLiteral(HashLiteral(...))`.

`size`  
Similar to `String#size`; `NumberLiteral`.

`lines`  
Similar to `String#lines`; `ArrayLiteral(StringLiteral)`.

`split`  
Similar to `String#split()`; `ArrayLiteral(StringLiteral)`.

`split(node)`  
Overloads for `StringLiteral`, `CharLiteral` and `RegexLiteral`; `ArrayLiteral(StringLiteral)`. The `split(ASTNode)` overload is **deprecated** — use `split(StringLiteral)`.

`starts_with?(other)`  
Similar to `String#starts_with?`; `BoolLiteral`.

`strip`  
Similar to `String#strip`; `Self`.

`titleize`  
Similar to `String#titleize`; `Self`.

`to_i(base = 10)`  
Similar to `String#to_i`; `NumberLiteral`.

`to_utf16`  
**Experimental.** Expression evaluating to a slice literal of UTF-16 code units plus a trailing null (not part of the slice) so `#to_unsafe` is always null-terminated: `{{ "abc😂".to_utf16 }} # => ::Slice(::UInt16).literal(97, 98, 99, 55357, 56834, 0)[0, 5]`. The result is not necessarily a literal node; `ASTNode`.

`tr(from, to)`  
Similar to `String#tr`; `Self`.

`underscore`  
Similar to `String#underscore`; `Self`.

`upcase`  
Similar to `String#upcase`; `Self`.

Additionally, `StringLiteral` and `MacroId` have:

`>(other)`, `<(other)`  
Similar to `String#>` / `String#<` (other: `StringLiteral | MacroId`); `BoolLiteral`.

And `StringLiteral` alone has:

`*(other)`  
Similar to `String#*` (repetition); `StringLiteral`.

### `StringInterpolation`

An interpolated string like `"Hello, #{name}!"`.

`expressions`  
The parts of the interpolation, alternating `StringLiteral` (plaintext) and arbitrary nodes (interpolated expressions); `ArrayLiteral(ASTNode)`.

### `ArrayLiteral`

An array literal, e.g. `[1, 2, 3]`.

`any?(&)`, `all?(&)`  
Similar to `Enumerable#any?` / `#all?`; `BoolLiteral`.

`splat(trailing_string = nil)`  
All elements joined by commas; *trailing_string* is appended unless empty — splat with an optional trailing comma; `MacroId`.

`clear`  
Similar to `Array#clear`; `ArrayLiteral`.

`empty?`  
Similar to `Array#empty?`; `BoolLiteral`.

`find(&)`  
Similar to `Enumerable#find`; `ASTNode | NilLiteral`.

`first`  
Like `Array#first`, but `NilLiteral` when empty; `ASTNode | NilLiteral`.

`includes?(node)`  
Similar to `Enumerable#includes?(obj)`; `BoolLiteral`.

`join(separator)`  
Similar to `Enumerable#join`; `StringLiteral`.

`last`  
Like `Array#last`, but `NilLiteral` when empty; `ASTNode | NilLiteral`.

`size`  
Similar to `Array#size`; `NumberLiteral`.

`map(&)`, `map_with_index(&)`  
Similar to `Enumerable#map` / `#map_with_index`; `ArrayLiteral`.

`each(&)`, `each_with_index(&)`  
Similar to `Array#each` / `Enumerable#each_with_index`; `NilLiteral`.

`select(&)`, `reject(&)`  
Similar to `Enumerable#select` / `#reject`; `ArrayLiteral`.

`reduce(&)`, `reduce(memo, &)`  
Similar to `Enumerable#reduce`; `ASTNode`.

`shuffle`  
Similar to `Array#shuffle`; `ArrayLiteral`.

`sort`, `sort_by(&)`  
Similar to `Array#sort` / `#sort_by`; `ArrayLiteral`.

`uniq`  
Similar to `Array#uniq`; `ArrayLiteral`.

`[](index)`  
Similar to `Array#[]?(Int)`; `ASTNode`.

`[](range)`  
Similar to `Array#[]?(Range)`; `ArrayLiteral(ASTNode) | NilLiteral`.

`[](start, count)`  
Similar to `Array#[]?(Int, Int)`; `ArrayLiteral(ASTNode) | NilLiteral`.

`[]=(index, value)`  
Similar to `Array#[]=`; `ASTNode`.

`unshift(value)`, `push(value)`, `<<(value)`  
Similar to `Array#unshift` / `#push` / `#<<`; `ArrayLiteral`.

`+(other)`, `-(other)`  
Similar to `Array#+` / `#-`; `ArrayLiteral`.

`*(other)`  
Similar to `Array#*`; `ArrayLiteral`.

`of`  
The element type written after the brackets in `[] of String`, if any; `ASTNode | Nop`.

`type`  
The receiver type in `MyArray{1, 2, 3}`, if any; `Path | Nop`.

### `HashLiteral`

A hash literal, e.g. `{"a" => 1}`.

`clear`  
Similar to `Hash#clear`; `HashLiteral`.

`each(&)`  
Similar to `Hash#each`; `NilLiteral`.

`empty?`  
Similar to `Hash#empty?`; `BoolLiteral`.

`keys`  
Similar to `Hash#keys`; `ArrayLiteral`.

`size`  
Similar to `Hash#size`; `NumberLiteral`.

`to_a`  
Similar to `Hash#to_a`; `ArrayLiteral(TupleLiteral)`.

`values`  
Similar to `Hash#values`; `ArrayLiteral`.

`map(&)`  
Similar to `Hash#map`; `ArrayLiteral`.

`select(&)`  
Similar to `Hash#select`; `HashLiteral`.

`select(*keys)`  
New hash with only the given keys; `HashLiteral`.

`reject(&)`  
Similar to `Hash#reject`; `HashLiteral`.

`reject(*keys)`  
New hash without the given keys; `HashLiteral`.

`[](key)`  
Similar to `Hash#[]?`; `ASTNode`.

`[]=(key, value)`  
Similar to `Hash#[]=`; `ASTNode`.

`has_key?(key)`  
Similar to `Hash#has_key?`; `BoolLiteral`.

`of_key`  
Key type in `{} of String => Int32`, if any; `ASTNode | Nop`.

`of_value`  
Value type in `{} of String => Int32`, if any; `ASTNode | Nop`.

`type`  
The receiver type in `MyHash{'a' => 1}`, if any; `Path | Nop`.

`double_splat(trailing_string = nil)`  
All entries joined by commas, with an optional trailing string unless empty — double-splat with optional trailing comma; `MacroId`.

### `NamedTupleLiteral`

A named tuple literal, e.g. `{a: 1, b: 2}`.

`each(&)`, `each_with_index(&)`  
Similar to `NamedTuple#each` / `#each_with_index`; `NilLiteral`.

`empty?`  
Similar to `NamedTuple#empty?`; `BoolLiteral`.

`keys`  
Similar to `NamedTuple#keys`; `ArrayLiteral`.

`size`  
Similar to `NamedTuple#size`; `NumberLiteral`.

`to_a`  
Similar to `NamedTuple#to_a`; `ArrayLiteral(TupleLiteral)`.

`values`  
Similar to `NamedTuple#values`; `ArrayLiteral`.

`map(&)`  
Similar to `NamedTuple#map`; `ArrayLiteral`.

`select(&)`  
Similar to `Hash#select`; `NamedTupleLiteral`.

`select(*keys)`  
New named tuple with only the given keys (`SymbolLiteral | StringLiteral | MacroId`); `NamedTupleLiteral`.

`reject(&)`  
Similar to `Hash#reject`; `NamedTupleLiteral`.

`reject(*keys)`  
New named tuple without the given keys; `NamedTupleLiteral`.

`double_splat(trailing_string = nil)`  
Similar to `HashLiteral#double_splat`; `MacroId`.

`[](key)`  
Similar to `NamedTuple#[]`, but `NilLiteral` if *key* is undefined; `ASTNode`.

`[]=(key, value)`  
Adds or replaces a key; `ASTNode`.

`has_key?(key)`  
Similar to `NamedTuple#has_key?`; `BoolLiteral`.

### `RangeLiteral`

A range literal, e.g. `(1..5)`.

`begin`  
Similar to `Range#begin`; `ASTNode`.

`each(&)`  
Similar to `Range#each`; `NilLiteral`.

`end`  
Similar to `Range#end`; `ASTNode`.

`excludes_end?`  
Similar to `Range#excludes_end?`; `BoolLiteral`.

`map(&)`  
Like `Enumerable#map` for a range; only for ranges of integer `NumberLiteral`s; `ArrayLiteral`.

`to_a`  
Like `Enumerable#to_a` for a range; only for ranges of integer `NumberLiteral`s; `ArrayLiteral`.

### `RegexLiteral`

A regular expression literal, e.g. `/foo/i`.

`source`  
Similar to `Regex#source`; `StringLiteral | StringInterpolation`.

`options`  
Like `Regex#options`, but as symbols, e.g. `[:i, :m, :x]`; `ArrayLiteral(SymbolLiteral)`.

### `TupleLiteral`

A tuple literal, e.g. `{1, "a"}`. Its methods mirror `ArrayLiteral`'s, with tuple-preserving return types.

`any?(&)`, `all?(&)`  
Similar to `Enumerable#any?` / `#all?`; `BoolLiteral`.

`splat(trailing_string = nil)`  
Elements joined by commas, optional trailing string unless empty; `MacroId`.

`empty?`  
Similar to `Tuple#empty?`; `BoolLiteral`.

`find(&)`  
Similar to `Enumerable#find`; `ASTNode | NilLiteral`.

`first`  
Like `Tuple#first`, but `NilLiteral` when empty; `ASTNode | NilLiteral`.

`includes?(node)`  
Similar to `Enumerable#includes?(obj)`; `BoolLiteral`.

`join(separator)`  
Similar to `Enumerable#join`; `StringLiteral`.

`last`  
Like `Tuple#last`, but `NilLiteral` when empty; `ASTNode | NilLiteral`.

`size`  
Similar to `Tuple#size`; `NumberLiteral`.

`map(&)`, `map_with_index(&)`  
Similar to `Enumerable#map` / `#map_with_index`; `TupleLiteral`.

`each(&)`, `each_with_index(&)`  
Similar to `Tuple#each` / `Enumerable#each_with_index`; `NilLiteral`.

`select(&)`, `reject(&)`  
Similar to `Enumerable#select` / `#reject`; `TupleLiteral`.

`reduce(&)`, `reduce(memo, &)`  
Similar to `Enumerable#reduce`; `ASTNode`.

`shuffle`  
Similar to `Array#shuffle`; `TupleLiteral`.

`sort`, `sort_by(&)`  
Similar to `Array#sort` / `#sort_by`; `TupleLiteral`.

`uniq`  
Similar to `Array#uniq`; `TupleLiteral`.

`[](index)`  
Similar to `Tuple#[]?(Int)`; `ASTNode`.

`[](range)`  
Similar to `Tuple#[]?(Range)`; `TupleLiteral | NilLiteral`.

`[](start, count)`  
Like `Array#[]?(Int, Int)`, returning a `TupleLiteral`; `TupleLiteral | NilLiteral`.

`[]=(index, value)`  
Similar to `Array#[]=`; `ASTNode`.

`unshift(value)`, `push(value)`, `<<(value)`  
Similar to `Array#unshift` / `#push` / `#<<`; `TupleLiteral`.

`+(other)`, `-(other)`  
Similar to `Tuple#+` / `Array#-`; `TupleLiteral`.

`*(other)`  
Similar to `Tuple#*`; `TupleLiteral`.

## Expression nodes

### `MetaVar`

A fictitious node representing a variable or instance variable together with type information (produced e.g. by `TypeNode#instance_vars`).

`name`  
The variable's name; `MacroId`.

`type`  
The variable's type, if known; `TypeNode | NilLiteral`.

`default_value`  
The default value; `ASTNode`. A `NilLiteral` is returned both for "no default" and for a `nil` default — distinguish with `has_default_value?`.

`has_default_value?`  
Whether the variable has a default value (which may itself be `nil`); `BoolLiteral`.

`annotation(type)`  
The last `Annotation` of the given type attached to this variable, or `NilLiteral`.

`annotations(type)`  
All annotations of the given type attached to this variable; `ArrayLiteral(Annotation)`.

`annotations`  
All annotations attached to this variable; `ArrayLiteral(Annotation)`.

### `Annotation`

An annotation on top of a type or variable, e.g. `@[Field(name: "x")]`.

`name`  
The annotation's name; `Path`.

`[](index)`  
Value of a positional argument, or `NilLiteral` if out of bounds; `ASTNode`.

`[](name)`  
Value of a named argument (`SymbolLiteral | StringLiteral | MacroId`), or `NilLiteral` if absent; `ASTNode`.

`args`  
The positional arguments; `TupleLiteral`.

`named_args`  
The named arguments; `NamedTupleLiteral`.

### `Var`

A local variable or block argument.

`id`  
This var's name; `MacroId`.

### `Block`

A code block.

`body`  
The block's body, if any; `ASTNode`.

`args`  
The block's arguments; `ArrayLiteral(MacroId)`.

`splat_index`  
Index of the splat argument, if any; `NumberLiteral | NilLiteral`.

### `Expressions`

A group of expressions.

`expressions`  
The list of expressions in this node; `ArrayLiteral(ASTNode)`.

### `Call`

A method call.

`id`  
This call's name as an identifier; `MacroId`.

`name`  
The method name of this call; `MacroId`.

`receiver`  
This call's receiver, if any; `ASTNode | Nop`.

`global?`  
Whether this call refers to a global method (starts with `::`); `BoolLiteral`.

`args`  
This call's arguments; `ArrayLiteral`.

`named_args`  
This call's named arguments; `ArrayLiteral(NamedArgument)`.

`block`  
This call's block, if any; `Block | Nop`.

`block_arg`  
This call's block argument, if any; `ASTNode | Nop`.

### `NamedArgument`

A call's named argument.

`name`  
The argument's name; `MacroId`.

`value`  
The argument's value; `ASTNode`.

### `If`

An `if` expression. (`unless` expressions in regular code are normalized to `If`; see `MacroIf` for macro-level `{% unless %}` — that node records which keyword was used.)

`cond`  
The condition; `ASTNode`.

`then`  
The `then` clause's body; `ASTNode`.

`else`  
The `else` clause's body; `ASTNode`.

### `Assign`

An assignment expression.

`target`  
The target assigned to; `ASTNode`.

`value`  
The value being assigned; `ASTNode`.

### `MultiAssign`

A multiple-assignment expression.

`targets`  
The targets assigned to; `ArrayLiteral(ASTNode)`.

`values`  
The values being assigned; `ArrayLiteral(ASTNode)`.

### `InstanceVar`, `ClassVar`, `Global`

An instance variable, class variable, or global variable.

`name`  
The variable's name; `MacroId`.

### `ReadInstanceVar`

Access to an instance variable through a receiver: `obj.@var`.

`obj`  
The object whose variable is accessed; `ASTNode`.

`name`  
The instance variable's name; `MacroId`.

### `BinaryOp` (abstract), `And`, `Or`

A binary expression like `&&` or `||`.

`left`  
The left-hand side; `ASTNode`.

`right`  
The right-hand side; `ASTNode`.

### `Arg`

A `def` argument.

`name`  
The **external** name — for `def write(to file)` returns `to`; `MacroId`.

`internal_name`  
The **internal** name — for `def write(to file)` returns `file`; `MacroId`.

`default_value`  
The default value, if any; `ASTNode | Nop`.

`restriction`  
The type restriction, if any; `ASTNode | Nop`.

`annotation(type)`  
The last `Annotation` of the given type, or `NilLiteral`.

`annotations(type)`  
All annotations of the given type; `ArrayLiteral(Annotation)`.

`annotations`  
All annotations on this arg; `ArrayLiteral(Annotation)`.

### `Def`

A method definition.

`name`  
The method's name; `MacroId`.

`args`  
The method's arguments; `ArrayLiteral(Arg)`.

`splat_index`  
Index of the splat argument, if any; `NumberLiteral | NilLiteral`.

`double_splat`  
The double splat argument, if any; `Arg | Nop`.

`block_arg`  
The block argument, if any; `Arg | Nop`.

`accepts_block?`  
Whether this method can be called with a block; `BoolLiteral`.

`return_type`  
The declared return type, if any; `ASTNode | Nop`.

`free_vars`  
The method's free variables (empty if none); `ArrayLiteral(MacroId)`.

`body`  
The method's body; `ASTNode`.

`receiver`  
The receiver (e.g. `self`), or `Nop`; `ASTNode | Nop`.

`abstract?`  
Whether the method is declared `abstract`; `BoolLiteral`.

`visibility`  
`:public`, `:protected` or `:private`; `SymbolLiteral`.

`annotation(type)`  
The last `Annotation` of the given type on this method, or `NilLiteral`.

`annotations(type)`  
All annotations of the given type on this method; `ArrayLiteral(Annotation)`.

`annotations`  
All annotations on this method; `ArrayLiteral(Annotation)`.

### `Primitive`

A fictitious node representing the body of a `Def` marked with `@[Primitive]`.

`name`  
The primitive's name — identical to the `@[Primitive]` argument: `{{ Foo.methods.first.body.name }} # => :abc`; `SymbolLiteral`.

### `Macro`

A macro definition.

`name`  
The macro's name; `MacroId`.

`args`  
The macro's arguments; `ArrayLiteral(Arg)`.

`splat_index`  
Index of the splat argument, if any; `NumberLiteral | NilLiteral`.

`double_splat`  
The double splat argument, if any; `Arg | Nop`.

`block_arg`  
The block argument, if any; `Arg | Nop`.

`body`  
The macro's body; `ASTNode`.

`visibility`  
`:public`, `:protected` or `:private`; `SymbolLiteral`.

### `UnaryExpression` (abstract)

Base of unary expressions; subclasses: `Not` (`!`), `PointerOf` (`pointerof`), `SizeOf` (`sizeof`), `InstanceSizeOf` (`instance_sizeof`), `AlignOf` (`alignof`), `InstanceAlignOf` (`instance_alignof`), `Out` (`out`), `Splat` (`*exp`), `DoubleSplat` (`**exp`), and `MacroVerbatim`.

`exp`  
The expression the operation applies to; `ASTNode`.

### `OffsetOf`

An `offsetof` expression.

`type`  
The type used in the expression; `ASTNode`.

`offset`  
The offset argument used in the expression; `ASTNode`.

### `VisibilityModifier`

A visibility modifier (`private def foo`, …).

`visibility`  
`:public`, `:protected` or `:private`; `SymbolLiteral`.

`exp`  
The expression the modifier applies to; `ASTNode`.

### `IsA`

An `.is_a?` or `.nil?` call.

`receiver`  
The call's receiver; `ASTNode`.

`arg`  
The call's argument; `ASTNode`.

### `RespondsTo`

A `.responds_to?` call.

`receiver`  
The call's receiver; `ASTNode`.

`name`  
The method name being checked; `StringLiteral`.

### `Require`

A `require` statement.

`path`  
The argument of the `require`; `StringLiteral`.

### `When`

A `when` or `in` inside a `case` or `select`.

`conds`  
The conditions of this `when`; `ArrayLiteral`.

`body`  
The body of this `when`; `ASTNode`.

`exhaustive?`  
`true` for `in`, `false` for `when`; `BoolLiteral`.

### `Case`

A `case` expression.

`cond`  
The condition (target) of the `case`; `ASTNode`.

`whens`  
The `when`s; `ArrayLiteral(When)`.

`else`  
The `else`; `ASTNode`.

`exhaustive?`  
Whether this is an exhaustive `case ... in`; `BoolLiteral`.

### `Select`

A `select` expression.

`whens`  
The `when`s; `ArrayLiteral(When)`.

`else`  
The `else`; `ASTNode`.

### `ImplicitObj`

The implicit object in a `case ... when .bar?` condition. Adds no methods.

### `While`

A `while` expression. (`until` is normalized to `While` with a negated condition.)

`cond`  
The condition; `ASTNode`.

`body`  
The body; `ASTNode`.

### `Rescue`

A `rescue` clause inside an exception handler.

`body`  
The clause's body; `ASTNode`.

`types`  
The rescued exception types, if any; `ArrayLiteral | NilLiteral`.

`name`  
The variable name of the rescued exception, if any; `MacroId | Nop`.

### `ExceptionHandler`

A `begin ... end` expression with `rescue`/`else`/`ensure` clauses.

`body`  
The main body; `ASTNode`.

`rescues`  
The `rescue` clauses, if any; `ArrayLiteral(Rescue) | NilLiteral`.

`else`  
The `else` clause body, if any; `ASTNode | Nop`.

`ensure`  
The `ensure` clause body, if any; `ASTNode | Nop`.

### `ProcLiteral`

A proc literal: `->(arg : String) { puts arg }`.

`args`  
The proc's arguments; `ArrayLiteral(Arg)`.

`body`  
The proc's body; `ASTNode`.

`return_type`  
The declared return type, if any; `ASTNode | Nop`.

### `ProcPointer`

A proc pointer: `->my_var.some_method(String)`.

`args`  
The argument types; `ArrayLiteral(ASTNode)`.

`obj`  
The receiver, or `nil` if unattached; `ASTNode | NilLiteral`.

`name`  
The method this proc points to; `MacroId`.

`global?`  
Whether it refers to a global method (starts with `::` and has no receiver); `BoolLiteral`.

### `Self`

The `self` expression, in code or type names. Adds no methods.

### `ControlExpression` (abstract), `Return`, `Break`, `Next`

Base of control-flow expressions.

`exp`  
The argument, if any; `ASTNode | Nop`. Multiple arguments are wrapped in a single `TupleLiteral`.

### `Yield`

A `yield` expression.

`expressions`  
The arguments to the `yield`; `ArrayLiteral`.

`scope`  
The scope — the part after `with` in a `with ... yield` expression; `ASTNode | Nop`.

### `Include` / `Extend`

An `include` or `extend` statement.

`name`  
The name of the type being included/extended; `ASTNode`.

### `Alias`

An `alias` statement.

`name`  
The alias's name; `Path`.

`type`  
The type this alias is equivalent to; `ASTNode`.

### `Cast` / `NilableCast`

A cast call: `obj.as(to)` / `obj.as?(to)`.

`obj`  
The object being cast; `ASTNode`.

`to`  
The target type of the cast; `ASTNode`.

### `TypeOf`

A `typeof` expression.

`args`  
The arguments to the `typeof`; `ArrayLiteral(ASTNode)`.

## Definition nodes

### `ClassDef`

A class or struct definition.

`abstract?`  
Whether this defines an abstract class or struct; `BoolLiteral`.

`kind`  
The keyword used: `class` or `struct`; `MacroId`.

`name(generic_args: true)`  
The type's name. With *generic_args* true and a generic definition, returns a `Generic` whose arguments are `MacroId`s (possibly with a `Splat` at the splat index); otherwise a `Path`; `Path | Generic`.

`superclass`  
The superclass, or `Nop` if unspecified; `ASTNode`.

`body`  
The definition's body; `ASTNode`.

`type_vars`  
`MacroId`s of the generic type parameters (empty for non-generics); `ArrayLiteral`.

`splat_index`  
Splat index of the generic type parameters, or `nil` if not generic / no splat; `NumberLiteral | NilLiteral`.

`struct?`  
Whether this defines a struct (`false` for a class); `BoolLiteral`.

### `ModuleDef`

A module definition.

`kind`  
Always `module`; `MacroId`.

`name(generic_args: true)`  
Same contract as `ClassDef#name`; `Path | Generic`.

`body`  
The definition's body; `ASTNode`.

`type_vars`  
Generic type parameters (empty for non-generics); `ArrayLiteral`.

`splat_index`  
Splat index of the generic type parameters, or `nil`; `NumberLiteral | NilLiteral`.

### `EnumDef`

An enum definition.

`kind`  
Always `enum`; `MacroId`.

`name(generic_args: true)`  
The enum's name (*generic_args* has no effect; it exists for interface parity); `Path`.

`base_type`  
The enum's base type, or `Nop` if unspecified; `ASTNode`.

`body`  
The definition's body; `ASTNode`.

### `AnnotationDef`

An annotation definition.

`kind`  
Always `annotation`; `MacroId`.

`name(generic_args: true)`  
The annotation's name (*generic_args* has no effect); `Path`.

`body`  
Always `Nop` — annotation definitions cannot contain anything.

### `LibDef`

A lib definition.

`kind`  
Always `lib`; `MacroId`.

`name(generic_args: true)`  
The lib's name (*generic_args* has no effect); `Path`.

`body`  
The definition's body; `ASTNode`.

### `CStructOrUnionDef`

A struct or union definition inside a lib.

`union?`  
Whether this defines a C union; `BoolLiteral`.

`kind`  
`struct` or `union`; `MacroId`.

`name(generic_args: true)`  
The type's name (*generic_args* has no effect); `Path`.

`body`  
The definition's body; `ASTNode`.

### `FunDef`

A function declaration inside a lib, or a top-level C function definition.

`name`  
The function's name in Crystal; `MacroId`.

`real_name`  
The real C name, if any; `StringLiteral | Nop`.

`args`  
The parameters (excluding the variadic parameter); `ArrayLiteral(Arg)`.

`variadic?`  
Whether the function is variadic; `BoolLiteral`.

`return_type`  
The return type, if specified; `ASTNode | Nop`.

`body`  
The body, if any; `ASTNode | Nop`. Both lib funs and top-level funs may return `Nop` — use `has_body?` to distinguish.

`has_body?`  
Top-level funs have a body; lib funs do not; `BoolLiteral`.

### `TypeDef`

A typedef inside a lib: `type Foo = Bar`.

`name`  
The typedef's name; `Path`.

`type`  
The type this typedef is equivalent to; `ASTNode`.

### `ExternalVar`

An external variable declaration inside a lib.

`name`  
The variable's name in Crystal, without the leading `$`; `MacroId`.

`real_name`  
The real C name, if any; `StringLiteral | Nop`.

`type`  
The variable's type; `ASTNode`.

## Type grammar nodes

These nodes appear in type positions — restrictions, declarations, generic arguments — and in the result of `parse_type`.

### `Path`

A path to a constant or type: `Foo`, `Foo::Bar::Baz`.

`names`  
Each separate part of the path; `ArrayLiteral(MacroId)`.

`global?`  
Whether this is a global path (starts with `::`); `BoolLiteral`.

`global`  
**Deprecated** — use `global?`; `BoolLiteral`.

`resolve`  
Resolves to a `TypeNode` for a type, to the constant's value for a constant; compile-time error otherwise; `ASTNode`.

`resolve?`  
Like `resolve`, but returns `NilLiteral` on failure; `ASTNode | NilLiteral`.

`types`  
This path inside an array literal — lets you call `types` uniformly on any type grammar node (`Generic`, `Path` or `Union`); `ArrayLiteral(ASTNode)`.

### `Generic`

A generic instantiation: `Foo(T)`, `Foo::Bar::Baz(T)`.

`name`  
The path to the generic; `Path`.

`type_vars`  
The type arguments of the instantiation; `ArrayLiteral(ASTNode)`.

`named_args`  
The named arguments, if any; `NamedTupleLiteral | NilLiteral`.

`resolve`  
Resolves to a `TypeNode`; compile-time error otherwise; `ASTNode`.

`resolve?`  
Like `resolve`, but `NilLiteral` on failure; `ASTNode | NilLiteral`.

`types`  
This generic inside an array literal (uniform access, see `Path#types`); `ArrayLiteral(ASTNode)`.

### `ProcNotation`

The type of a proc or block argument: `String -> Int32`.

`inputs`  
The argument types (empty if none); `ArrayLiteral(ASTNode)`.

`output`  
The output type, or `nil` if there is no return type; `ASTNode | NilLiteral`.

`resolve`  
Resolves to a `TypeNode`; compile-time error otherwise; `ASTNode`.

`resolve?`  
Like `resolve`, but `NilLiteral` on failure; `ASTNode | NilLiteral`.

### `Union`

A type union: `(Int32 | String)`.

`types`  
The types of this union; `ArrayLiteral(ASTNode)`.

`resolve`  
Resolves to a `TypeNode`; compile-time error if any member can't be resolved; `ASTNode`.

`resolve?`  
Like `resolve`, but `NilLiteral` on failure; `ASTNode | NilLiteral`.

### `Metaclass`

A metaclass in a type expression: `T.class`.

`instance`  
The node representing the instance type of this metaclass; `ASTNode`.

`resolve`  
Resolves to a `TypeNode`; compile-time error otherwise; `ASTNode`.

`resolve?`  
Like `resolve`, but `NilLiteral` on failure; `ASTNode | NilLiteral`.

### `TypeDeclaration`

A type declaration: `x : Int32`.

`var`  
The variable part; `MacroId`.

`type`  
The type part; `ASTNode`.

`value`  
The assigned value, if any; `ASTNode | Nop`.

### `UninitializedVar`

An uninitialized declaration: `a = uninitialized Int32`.

`var`  
The variable part; `MacroId`.

`type`  
The type part; `ASTNode`.

## Macro-internal nodes

Nodes produced by parsing macro syntax itself.

### `MacroExpression`

A `{{ ... }}` or `{% ... %}` expression.

`exp`  
The expression inside this node; `ASTNode`.

`output?`  
Whether this node interpolates the result (`{{ }}`) rather than just evaluating it (`{% %}`); `BoolLiteral`.

### `MacroLiteral`

Free text that is part of a macro.

`value`  
The text of the literal; `MacroId`.

### `MacroIf`

An `{% if %}` / `{% unless %}` inside a macro.

`cond`  
The condition; `ASTNode`.

`then`  
The `then` branch; `ASTNode`.

`else`  
The `else` branch; `ASTNode`.

`is_unless?`  
Whether this node represents an `unless`; `BoolLiteral`.

### `MacroFor`

A `{% for x in exp %}` loop inside a macro.

`vars`  
The variables declared after `for`; `ArrayLiteral(Var)`.

`exp`  
The expression after `in`; `ASTNode`.

`body`  
The loop body; `ASTNode`.

### `MacroVar`

A macro fresh variable (`%var`, optionally indexed `%var{0}`).

`name`  
The fresh variable's name; `MacroId`.

`expressions`  
The associated indices of the fresh variable; `ArrayLiteral`.

### `MacroVerbatim`

A `{% verbatim do %} ... {% end %}` expression. A `UnaryExpression` — the inner expression is available via `exp`.

### `Underscore`

The `_` expression, in code (e.g. an assignment target) and in type names. Adds no methods.

### `MagicConstant`

A pseudo constant carrying source-location information: `__FILE__`, `__LINE__`, `__DIR__`. Usually resolved by the compiler; appears unresolved as a default parameter value. Adds no methods.

### `Asm`

An inline assembly expression.

`text`  
The template string; `StringLiteral`.

`outputs`  
The output operands; `ArrayLiteral(AsmOperand)`.

`inputs`  
The input operands; `ArrayLiteral(AsmOperand)`.

`clobbers`  
Clobbered register names; `ArrayLiteral(StringLiteral)`.

`volatile?`  
Whether there are side effects beyond `outputs`/`inputs`/`clobbers`; `BoolLiteral`.

`alignstack?`  
Whether stack alignment code is required; `BoolLiteral`.

`intel?`  
Whether the template uses Intel syntax (`false` = AT&T); `BoolLiteral`.

`can_throw?`  
Whether the expression might unwind the stack; `BoolLiteral`.

### `AsmOperand`

An output or input operand of an `Asm` node.

`constraint`  
The constraint string; `StringLiteral`.

`exp`  
The associated output or input argument; `ASTNode`.

## `MacroId`

A fictitious node representing an identifier like `foo`, `Bar` or `something_else`. The parser never creates these; you create them by calling `id` on a `StringLiteral`, `SymbolLiteral`, `Call`, `Var` or `Path`. This lets strings, symbols, variables and calls be treated uniformly when generating names.

`MacroId` supports the full [shared string method set](#string-like-nodes-stringliteral-symbolliteral-macroid) plus `>` and `<` comparisons.

## `TypeNode`

Represents an actual type in the program, like `Int32` or `String`. Obtained via `@type`, `@def`, resolving a `Path`/`Generic`/`Union`/`Metaclass`/`ProcNotation`, or type introspection methods.

### Kind predicates

`abstract?`  
Whether the type is abstract; `BoolLiteral`.

`union?`  
Whether this is a union type. See also `union_types`; `BoolLiteral`.

`nilable?`  
Whether `nil` is an instance of this type; `BoolLiteral`.

`module?`  
Whether this is a `module`; `BoolLiteral`.

`class?`  
Whether this is a `class`; `BoolLiteral`.

`struct?`  
Whether this is a `struct`; `BoolLiteral`.

### Name and structure

`name(generic_args: true)`  
Fully qualified name; without generic arguments if `generic_args: false`. `{{ Foo.name }} # => Foo(T)`; `MacroId`.

`type_vars`  
The type variables of a generic type (empty for non-generics); `ArrayLiteral(TypeNode)`.

`union_types`  
The types forming the union; for non-unions, this type in a single-element array — safe to call on any type; `ArrayLiteral(TypeNode)`.

`size`  
Number of elements in a tuple type or tuple metaclass type; compile error otherwise; `NumberLiteral`.

`keys`  
Keys of a named tuple type; compile error otherwise; `ArrayLiteral(MacroId)`.

`[](key)`  
The type for a key in a named tuple type (`SymbolLiteral | MacroId`); compile error otherwise; `TypeNode | NilLiteral`.

### Hierarchy and members

`ancestors`  
All ancestors of this type; `ArrayLiteral(TypeNode)`.

`superclass`  
The direct superclass; `TypeNode | NilLiteral`.

`subclasses`  
The direct subclasses; `ArrayLiteral(TypeNode)`.

`all_subclasses`  
All subclasses (reliable inside `macro finished`); `ArrayLiteral(TypeNode)`.

`includers`  
All types this type is directly included in; `ArrayLiteral(TypeNode)`.

`constants`  
Constants and types defined by this type; `ArrayLiteral(MacroId)`.

`constant(name)`  
A constant defined in this type: its value as an `ASTNode`, a `TypeNode` if it's a type, or `NilLiteral`.

`has_constant?(name)`  
Whether this type has the constant (`"DEFAULT_OPTIONS"` or `:DEFAULT_OPTIONS`); `BoolLiteral`.

`instance_vars`  
Instance variables of this type; `ArrayLiteral(MetaVar)`. Only from within methods — returns an empty list at top level.

`class_vars`  
Class variables of this type; `ArrayLiteral(MetaVar)`.

`methods`  
Instance methods defined by this type, excluding inherited ones; `ArrayLiteral(Def)`.

`all_methods`  
Instance methods including those inherited from ancestors and base types (`Reference`, `Value`, `Object`); `ArrayLiteral(Def)`.

`has_method?(name)`  
Whether this type has the method (`"default_options"` or `:default_options`); `BoolLiteral`.

`overrides?(type, method)`  
Whether this type overrides *method* from *type*: `{{ Bar.overrides?(Foo, "one") }}`; `BoolLiteral`.

### Annotations and visibility

`annotation(type)`  
The last `Annotation` of the given type on this type, or `NilLiteral`.

`annotations(type)`  
All annotations of the given type on this type; `ArrayLiteral(Annotation)`.

`annotations`  
All annotations on this type; `ArrayLiteral(Annotation)`.

`private?`  
Whether this type is private; `BoolLiteral`.

`public?`  
Whether this type is public; `BoolLiteral`.

`visibility`  
`:public` or `:private`; `SymbolLiteral`.

### Class/instance relationship and resolution

`class`  
The class of this type — e.g. `type.class.methods` gives class methods; `TypeNode`.

`instance`  
The instance type if this is a class type, or `self` otherwise. Opposite of `#class`; `TypeNode`.

`resolve`  
Returns `self` — lets you call `resolve` on any node that might already be a type; `TypeNode`.

`resolve?`  
Returns `self` — same purpose as `resolve`; `TypeNode`.

### Comparison operators

`<(other)`  
Whether *other* is an ancestor of this type; `BoolLiteral`.

`<=(other)`  
Whether this type is the same as *other* or *other* is an ancestor; `BoolLiteral`.

`>(other)`  
Whether this type is an ancestor of *other*; `BoolLiteral`.

`>=(other)`  
Whether *other* is the same as this type or this type is an ancestor of *other*; `BoolLiteral`.

### Memory layout

`has_inner_pointers?`  
Whether the type contains any inner pointers; `BoolLiteral`. Primitive types (except `Void`) do not; `Proc` and `Pointer` do; unions, structs, tuples and static arrays do if any member does; classes do. Types without inner pointers may use atomic allocation (`GC.malloc_atomic`): `Pointer(T).malloc` is atomic iff `T` has no inner pointers, and `T.allocate` is atomic iff `T` is a reference type and `ReferenceStorage(T)` has no inner pointers. Like `instance_vars`, must be called from within a method — results may be incorrect at top level.
