<!-- macros.md -->

# Crystal Macros

A complete reference for Crystal's compile-time macro system: the language (syntax, scoping, hooks, special variables) and the full macro method API exposed through the fictitious `Crystal::Macros` module.

Targets Crystal 1.21.

---

## Table of Contents

1. [Overview](#overview)
2. [Defining and Calling Macros](#defining-and-calling-macros)
3. [Interpolation](#interpolation)
4. [Directives](#directives)
5. [Truthiness](#truthiness)
6. [Special Macro Variables](#special-macro-variables)
7. [Macro Defs](#macro-defs)
8. [Hooks](#hooks)
9. [Fresh Variables](#fresh-variables)
10. [Constants and Type Resolution](#constants-and-type-resolution)
11. [Annotations](#annotations)
12. [Nested Macros and `verbatim`](#nested-macros-and-verbatim)
13. [Comments and Documentation](#comments-and-documentation)
14. [Top-Level Macro Methods](#top-level-macro-methods)
15. [AST Node Reference](#ast-node-reference)
16. [Pitfalls](#pitfalls)

---

## Overview

Macros are methods that receive AST nodes at compile time and produce code that is pasted into the program.

The generated output must be valid Crystal on its own before it is merged into the surrounding code.

```crystal
macro define_method(name, content)
  def {{name.id}}
    {{content}}
  end
end

define_method foo, 1

foo # => 1
```

Two syntactic forms drive everything:

| Form        | Purpose                                                      |
|-------------|--------------------------------------------------------------|
| `{{ ... }}` | Evaluate an expression and paste its result into the output. |
| `{% ... %}` | Evaluate an expression or control structure without pasting. |

Both forms work inside `macro` bodies and also directly in top-level code, class bodies, and method bodies.

---

## Defining and Calling Macros

### Scope and Visibility

- **Top level:** a macro defined at the top level is visible everywhere.
- **Private:** a `private` top-level macro is visible only in the file that defines it.
- **Classes and modules:** macros defined inside a class or module are visible in that scope.
- **Ancestors:** macro lookup also walks the ancestor chain (superclasses and included modules).
- **Qualified calls:** a macro defined in a type can be invoked from outside it with a type prefix.

```crystal
class Foo
  macro emphasize(value)
    "***#{ {{value}} }***"
  end

  def yield_with_self(&)
    with self yield
  end
end

Foo.emphasize(10)                         # => "***10***"
Foo.new.yield_with_self { emphasize(10) } # => "***10***"
```

### Parameters

Macro parameters receive AST nodes, not values.

| Parameter kind | Syntax            | Receives                                 |
|----------------|-------------------|------------------------------------------|
| Positional     | `macro m(a)`      | The node as written                      |
| Default value  | `macro m(a = 1)`  | The default node when omitted            |
| Splat          | `macro m(*args)`  | A `TupleLiteral` of nodes                |
| Named-only     | `macro m(*, key)` | The node passed as `key: ...`            |
| Double splat   | `macro m(**opts)` | A `NamedTupleLiteral` of named arguments |
| Block          | `macro m(&block)` | A `Block` node                           |

```crystal
macro define_dummy_methods(*names)
  {% for name, index in names %}
    def {{name.id}}
      {{index}}
    end
  {% end %}
end

define_dummy_methods foo, bar, baz

foo # => 0
baz # => 2
```

### Blocks

A block passed to a macro can be pasted with `{{yield}}`, or captured and inspected through `&block`.

```crystal
macro timed(&block)
  %start = Time.monotonic
  {{block.body}}
  puts Time.monotonic - %start
end

timed do
  heavy_work
end
```

`Block` exposes `body`, `args`, and `splat_index`.

---

## Interpolation

`{{ expr }}` pastes the resulting node as-is.

A `SymbolLiteral` pastes as `:foo` and a `StringLiteral` pastes as `"foo"`. Use `.id` whenever you need a bare identifier.

```crystal
macro getter_for(name)
  def {{name.id}}
    @{{name.id}}
  end
end

getter_for :value
getter_for "value"
getter_for value
```

### Splatting

| Syntax                        | Output                                           |
|-------------------------------|--------------------------------------------------|
| `{{*tuple_or_array}}`         | Elements joined by commas                        |
| `{{node.splat}}`              | Same, as a method call                           |
| `{{node.splat(", ")}}`        | Joined, plus a trailing string only if non-empty |
| `{{hash_or_nt.double_splat}}` | `k: v` pairs joined by commas                    |

```crystal
macro println(*values)
  print {{*values}}, '\n'
end

println 1, 2, 3
```

---

## Directives

### Assignment

Macro variables live only within the current macro evaluation.

```crystal
{% names = %w(a b c) %}
{% total = names.size * 2 %}
```

### Conditionals

```crystal
{% if flag?(:linux) %}
  LIB = "libfoo.so"
{% elsif flag?(:darwin) %}
  LIB = "libfoo.dylib"
{% else %}
  LIB = "foo.dll"
{% end %}

{% unless flag?(:release) %}
  DEBUG = true
{% end %}
```

A suffix form and a ternary are also valid inside an expression:

```crystal
{% raise "need at least one" if names.empty? %}
{{ names.size > 1 ? "many".id : "one".id }}
```

### Iteration

`for` loops accept these iteration targets:

| Target              | Loop variables                      |
|---------------------|-------------------------------------|
| `ArrayLiteral`      | `element` or `element, index`       |
| `TupleLiteral`      | `element` or `element, index`       |
| `RangeLiteral`      | `number`                            |
| `HashLiteral`       | `key, value` or `key, value, index` |
| `NamedTupleLiteral` | `key, value` or `key, value, index` |

```crystal
macro define_constants(count)
  {% for i in (1..count) %}
    PI_{{i.id}} = Math::PI * {{i}}
  {% end %}
end

{% for key, value in {foo: 10, bar: 20} %}
  def {{key.id}}
    {{value}}
  end
{% end %}
```

### `begin`

`{% begin %} ... {% end %}` wraps a region so that the macro emits it as one unit. It is required when a loop must produce fragments, such as `when` branches, that are only valid inside an enclosing construct.

```crystal
{% begin %}
  case value
  {% for klass in [Int32, String] %}
    when {{klass}}
      "is {{klass}}"
  {% end %}
  end
{% end %}
```

### Blocks in Macro Code

Collection methods accept blocks using the short `&.` form or the full `do |x| ... end` / `{ |x| ... }` form.

```crystal
{{ @type.instance_vars.map(&.name.stringify) }}
{{ names.select { |n| n.starts_with?("a") } }}
```

---

## Truthiness

| Falsey                         | Truthy          |
|--------------------------------|-----------------|
| `Nop`                          | Everything else |
| `NilLiteral`                   |                 |
| `BoolLiteral` with value false |                 |

`&&`, `||`, and `!` work in macro expressions with the same semantics as at runtime.

---

## Special Macro Variables

| Variable     | Type                               | Meaning                                                               |
|--------------|------------------------------------|-----------------------------------------------------------------------|
| `@type`      | `TypeNode`                         | The current scope's *instance* type, even inside class methods.       |
| `@top_level` | `TypeNode`                         | The top-level namespace.                                              |
| `@def`       | `Def \| NilLiteral`                | The enclosing method, or nil when outside a method.                   |
| `@caller`    | `ArrayLiteral(Call) \| NilLiteral` | The macro call stack, newest first; nil outside a macro and in hooks. |

The `@caller` array currently only ever contains a single element.

```crystal
macro add_describe
  def describe
    "Class is: " + {{ @type.stringify }}
  end
end

A_CONSTANT = 0

{% if @top_level.has_constant?("A_CONSTANT") %}
  puts "defined"
{% end %}

module Foo
  def Foo.boo(arg1, arg2)
    {% @def.receiver %}
    {% @def.name %}
    {% @def.args %}
  end
end

macro where
  {{ @caller.first.line_number }}
end
```

---

## Macro Defs

A regular `def` becomes a *macro def* when its body contains a macro expression that references `@type`. It is then instantiated separately for each concrete type that calls it.

```crystal
class Object
  def instance_vars_names
    {{ @type.instance_vars.map &.name.stringify }}
  end
end

class Person
  def initialize(@name : String, @age : Int32)
  end
end

Person.new("John", 30).instance_vars_names # => ["name", "age"]
```

A macro def's parameters are ordinary runtime parameters. Their values cannot be inspected at compile time, so any comparison against them has to happen at runtime:

```crystal
class Object
  def has_instance_var?(name) : Bool
    {{ @type.instance_vars.map &.name.stringify }}.includes? name
  end
end
```

`TypeNode#instance_vars` and `TypeNode#has_inner_pointers?` are only reliable inside method bodies such as macro defs.

---

## Hooks

Hooks are specially named macros that the compiler invokes automatically.

| Hook                   | Trigger                                                 | `@type`       | Multiple definitions |
|------------------------|---------------------------------------------------------|---------------|----------------------|
| `inherited`            | A subclass is defined                                   | The subclass  | Stack                |
| `included`             | The module is included                                  | The includer  | Stack                |
| `extended`             | The module is extended                                  | The extender  | Stack                |
| `method_added(method)` | A method is defined in the current scope                | Current scope | Stack                |
| `method_missing(call)` | A call does not resolve                                 | Current scope | Override             |
| `finished`             | Parsing is complete, so all types and methods are known | Current scope | Stack                |

When hooks **stack**, every definition runs, in the order it was defined. When a hook is **overridden**, only the last definition in a given context runs.

`method_missing` and `method_added` apply only to the type they are defined in and its descendants. When defined outside any type, they apply only at the top level.

```crystal
class Parent
  macro inherited
    def lineage
      "{{@type.name.id}} < Parent"
    end
  end
end

class Child < Parent
end

Child.new.lineage # => "Child < Parent"

macro method_missing(call)
  print "Got ", {{call.name.id.stringify}}, " with ", {{call.args.size}}, " arguments", '\n'
end

macro method_added(method)
  {% puts "Method added: #{method.name}" %}
end
```

`finished` runs only after every reopening of the type has been processed:

```crystal
class Foo
  macro finished
    {% puts @type.methods.map &.name %}
  end
end

class Foo
  def bar
  end
end
```

This prints `[bar]`, even though `bar` is defined after the hook.

---

## Fresh Variables

Generated code is parsed in the caller's scope, so a plain local variable in a macro can clobber the caller's variables.

```crystal
macro update_x
  x = 1
end

x = 0
update_x
x # => 1
```

`%name` declares a variable whose generated name is guaranteed to be unique:

```crystal
macro dont_update_x
  %x = 1
  puts %x
end

x = 0
dont_update_x
x # => 0
```

`%name{k1, k2, ...}` declares a distinct fresh variable for each key tuple, which lets a loop create one variable per element:

```crystal
macro declare(*names)
  {% for name, index in names %}
    %var{index} = {{index}}
  {% end %}
  {% for name, index in names %}
    puts %var{index}
  {% end %}
end
```

---

## Constants and Type Resolution

Macros can read constants directly. A constant that names a type yields a `TypeNode`.

```crystal
VALUES = [1, 2, 3]

{% for value in VALUES %}
  puts {{value}}
{% end %}
```

To turn a string into a type or constant, use `parse_type` followed by `resolve` or `resolve?`:

```crystal
MY_CONST = 1234

struct Some::Namespace::Foo; end

{{ parse_type("Some::Namespace::Foo").resolve.struct? }} # => true
{{ parse_type("MY_CONST").resolve }}                     # => 1234
```

`Path`, `Generic`, `Union`, `Metaclass`, and `ProcNotation` all provide `resolve`, which raises a compile-time error on failure, and `resolve?`, which returns `NilLiteral` instead. `TypeNode#resolve` returns `self`, so calling `resolve` is always safe on any of these nodes.

---

## Annotations

Annotations attach compile-time metadata that macros can read back.

```crystal
annotation Column
end

class User
  @[Column(name: "user_name", 1)]
  @name : String = ""

  def columns
    {% begin %}
      {
        {% for ivar in @type.instance_vars %}
          {% if ann = ivar.annotation(Column) %}
            {{ivar.name.stringify}} => {{ann[:name]}},
          {% end %}
        {% end %}
      }
    {% end %}
  end
end
```

Annotations can be read from several node types:

| Node       | Methods                                          |
|------------|--------------------------------------------------|
| `TypeNode` | `annotation(T)`, `annotations(T)`, `annotations` |
| `MetaVar`  | `annotation(T)`, `annotations(T)`, `annotations` |
| `Def`      | `annotation(T)`, `annotations(T)`, `annotations` |
| `Arg`      | `annotation(T)`, `annotations(T)`, `annotations` |

`annotation(T)` returns the last matching annotation, or `NilLiteral` if there is none.

An `Annotation` node exposes these methods:

| Method       | Returns             | Description                                        |
|--------------|---------------------|----------------------------------------------------|
| `name`       | `Path`              | Annotation type name                               |
| `[](index)`  | `ASTNode`           | Positional argument, `NilLiteral` if out of bounds |
| `[](name)`   | `ASTNode`           | Named argument, `NilLiteral` if absent             |
| `args`       | `TupleLiteral`      | All positional arguments                           |
| `named_args` | `NamedTupleLiteral` | All named arguments                                |

---

## Nested Macros and `verbatim`

A macro can generate other macros. Escape the inner macro's expressions with a backslash (`\{{ }}`, `\{% %}`) so the outer macro does not evaluate them.

```crystal
macro define_greeters(*names)
  {% for name in names %}
    macro greet_{{name.id}}(greeting)
      "\{{greeting.id}} {{name.id}}"
    end
  {% end %}
end

define_greeters alice, bob

greet_alice "hello" # => "hello alice"
```

`{% verbatim do %} ... {% end %}` passes its contents through without evaluation, so no escaping is needed. The trade-off is that the outer macro's variables are not visible inside the block. To use one, hand it over through an escaped assignment:

```crystal
macro define_greeters(*names)
  {% for name in names %}
    macro greet_{{name.id}}(greeting)
      \{% name = {{name.stringify}} %}
      {% verbatim do %}
        "{{greeting.id}} {{name.id}}"
      {% end %}
    end
  {% end %}
end
```

---

## Comments and Documentation

Macro expressions are evaluated inside comments too.

This makes generated documentation possible:

```crystal
{% for name, index in ["foo", "bar"] %}
  # Returns {{index}}.
  def {{name.id}}
    {{index}}
  end
{% end %}
```

The same rule has a side effect: a macro directive cannot be disabled by commenting it out.

```crystal
macro a
  # {% if false %}
  puts 42
  # {% end %}
end
```

Calling `a` prints nothing, because the commented-out `if false` is still evaluated.

To merge the documentation written on a macro call into the generated code, combine `@caller` with `doc_comment`:

```crystal
macro gen_method(name)
  # {{ @caller.first.doc_comment }}
  #
  # Comment added via macro expansion.
  def {{name.id}}
  end
end

# Comment on macro call.
gen_method foo
```

`doc` and `doc_comment` return empty results outside the `crystal docs` command.

---

## Top-Level Macro Methods

These methods can be called anywhere inside `{{ }}` or `{% %}`.

### Environment and Build

| Method                     | Returns                       | Description                                                             |
|----------------------------|-------------------------------|-------------------------------------------------------------------------|
| `flag?(name)`              | `BoolLiteral`                 | Whether a compile-time flag is set for the target.                      |
| `host_flag?(name)`         | `BoolLiteral`                 | Whether a flag is set for the host, which matters when cross-compiling. |
| `env(name)`                | `StringLiteral \| NilLiteral` | Environment variable value at compile time.                             |
| `compare_versions(v1, v2)` | `NumberLiteral`               | Semver comparison, returning `-1`, `0`, or `1`.                         |
| `skip_file`                | `Nop`                         | Skips the rest of the current file.                                     |

```crystal
{% skip_file unless flag?(:linux) %}
{% if compare_versions(Crystal::VERSION, "1.10.0") >= 0 %}
{% end %}
```

### Files and Processes

| Method                 | Returns                       | Description                                                      |
|------------------------|-------------------------------|------------------------------------------------------------------|
| `read_file(path)`      | `StringLiteral`               | Reads a file; any failure is a compile-time error.               |
| `read_file?(path)`     | `StringLiteral \| NilLiteral` | Reads a file, returning nil on I/O failure.                      |
| `file_exists?(path)`   | `BoolLiteral`                 | Whether the file exists.                                         |
| `` `command` ``        | `MacroId`                     | Runs a shell command and returns its stdout; errors if it fails. |
| `system(command)`      | `MacroId`                     | Same as the backtick form.                                       |
| `run(filename, *args)` | `MacroId`                     | Compiles and runs a Crystal program, returning its stdout.       |

Relative paths passed to `read_file` resolve against the current working directory. Use `"#{__DIR__}/file"` to make them relative to the source file instead.

The compiler may cache the executable built by `run`. That makes `run` programs that change between compilations, or that are slow, a poor fit.

```crystal
DATA = {{ read_file("#{__DIR__}/data.txt") }}
GIT_SHA = {{ `git rev-parse HEAD`.stringify.chomp }}
```

### Types and Layout

| Method               | Returns                                        | Description                                      |
|----------------------|------------------------------------------------|--------------------------------------------------|
| `parse_type(string)` | `Path \| Generic \| ProcNotation \| Metaclass` | Parses a type expression; resolve it afterwards. |
| `sizeof(Type)`       | `NumberLiteral`                                | Size in bytes of a *stable* type.                |
| `alignof(Type)`      | `NumberLiteral`                                | Alignment in bytes of a *stable* type.           |

`sizeof` and `alignof` take a constant that names the type. They do not accept a `typeof` expression or any value that is only known during macro evaluation.

All Crystal types are stable except the following:

- structs
- `ReferenceStorage` instances
- modules (their metaclasses are stable)
- uninstantiated generics
- `StaticArray`, `Tuple`, and `NamedTuple` instances with unstable elements
- unions containing unstable types

### Diagnostics and Debugging

| Method                     | Returns      | Description                                                     |
|----------------------------|--------------|-----------------------------------------------------------------|
| `raise(message)`           | `NoReturn`   | Compile-time error.                                             |
| `warning(message)`         | `NilLiteral` | Compile-time warning.                                           |
| `puts(*exps)` / `p` / `pp` | `Nop`        | Prints nodes at compile time.                                   |
| `print(*exps)`             | `Nop`        | Prints nodes without a trailing newline.                        |
| `p!(*exps)` / `pp!`        | `Nop`        | Prints each expression followed by its value.                   |
| `debug(format = true)`     | `Nop`        | Prints the current macro's output buffer, formatted by default. |

`ASTNode#raise` and `ASTNode#warning` behave the same, but also point the diagnostic at that node's source location.

---

## AST Node Reference

All return types are macro AST node types. "Similar to `X`" means the method mirrors the runtime method of the same name.

### ASTNode

These methods are available on every node.

| Method                    | Returns                       | Description                                                |
|---------------------------|-------------------------------|------------------------------------------------------------|
| `id`                      | `MacroId`                     | Node as an identifier.                                     |
| `stringify`               | `StringLiteral`               | Source text as a string literal.                           |
| `symbolize`               | `SymbolLiteral`               | Source text as a symbol literal.                           |
| `class_name`              | `StringLiteral`               | AST class name, e.g. `"StringLiteral"`.                    |
| `filename`                | `StringLiteral \| NilLiteral` | Source file.                                               |
| `line_number`             | `NumberLiteral \| NilLiteral` | Start line, 1-based.                                       |
| `column_number`           | `NumberLiteral \| NilLiteral` | Start column, 1-based.                                     |
| `end_line_number`         | `NumberLiteral \| NilLiteral` | End line.                                                  |
| `end_column_number`       | `NumberLiteral \| NilLiteral` | End column.                                                |
| `==(other)` / `!=(other)` | `BoolLiteral`                 | Textual equality.                                          |
| `is_a?(NodeType)`         | `BoolLiteral`                 | AST node type check; the argument is never a program type. |
| `nil?`                    | `BoolLiteral`                 | True for `NilLiteral` and `Nop`.                           |
| `raise(message)`          | `NoReturn`                    | Error pointing at this node.                               |
| `warning(message)`        | `NilLiteral`                  | Warning pointing at this node.                             |
| `doc`                     | `StringLiteral`               | Attached doc comment; only populated under `crystal docs`. |
| `doc_comment`             | `MacroId`                     | Doc comment with each line prefixed by `#`.                |

The stub file declares the location methods as returning `StringLiteral | NilLiteral`. The official reference's `@caller.first.line_number` example evaluates to a bare number (`# => 9`), so the table lists `NumberLiteral`.

### Literals

#### Nop, NilLiteral, BoolLiteral

These have no methods beyond `ASTNode`. `Nop` is an empty node whose text is the empty string, for example the missing `else` branch of an `if`.

#### NumberLiteral

| Method                                | Returns         | Description                                |
|---------------------------------------|-----------------|--------------------------------------------|
| `+ - * // % & \| ^ ** << >>` (binary) | `NumberLiteral` | Arithmetic and bitwise operators.          |
| `+ - ~` (unary)                       | `NumberLiteral` | Unary operators.                           |
| `< <= > >=`                           | `BoolLiteral`   | Comparison.                                |
| `<=>`                                 | `NumberLiteral` | Three-way comparison.                      |
| `zero?`                               | `BoolLiteral`   | Whether the value is 0.                    |
| `kind`                                | `SymbolLiteral` | Literal type, e.g. `:i32`, `:u16`, `:f64`. |
| `to_number`                           | `MacroId`       | Value without its type suffix.             |

`/` is not available in macros; use `//` for division.

#### CharLiteral

| Method | Returns         | Description                     |
|--------|-----------------|---------------------------------|
| `id`   | `MacroId`       | The character as an identifier. |
| `ord`  | `NumberLiteral` | Codepoint.                      |

#### StringLiteral, SymbolLiteral, MacroId

All three share these string methods. `Self` below means the receiver's own class.

| Method                              | Returns                       | Description                                                          |
|-------------------------------------|-------------------------------|----------------------------------------------------------------------|
| `id`                                | `MacroId`                     | Contents as an identifier.                                           |
| `[](range)`                         | `Self`                        | Substring.                                                           |
| `=~(regex)`                         | `BoolLiteral`                 | Regex match test.                                                    |
| `+(str_or_char)`                    | `Self`                        | Concatenation.                                                       |
| `camelcase(*, lower = false)`       | `Self`                        | Similar to `String#camelcase`.                                       |
| `capitalize`                        | `Self`                        | Similar to `String#capitalize`.                                      |
| `chars`                             | `ArrayLiteral(CharLiteral)`   | Characters.                                                          |
| `chomp`                             | `Self`                        | Removes a trailing newline.                                          |
| `count(char)`                       | `NumberLiteral`               | Occurrences of a character.                                          |
| `downcase` / `upcase`               | `Self`                        | Case conversion.                                                     |
| `empty?`                            | `BoolLiteral`                 | Empty check.                                                         |
| `starts_with?(s)` / `ends_with?(s)` | `BoolLiteral`                 | Prefix and suffix tests; accept a string or char.                    |
| `includes?(s)`                      | `BoolLiteral`                 | Substring or char test.                                              |
| `gsub(regex, replacement)`          | `Self`                        | Regex replace.                                                       |
| `gsub(regex) { \|match, groups\| }` | `Self`                        | Block replace; `$~` and `$1` are not supported.                      |
| `match(regex)`                      | `HashLiteral \| NilLiteral`   | Capture hash in the same shape as `MatchData#to_h`.                  |
| `scan(regex)`                       | `ArrayLiteral(HashLiteral)`   | One capture hash per match.                                          |
| `size`                              | `NumberLiteral`               | Length.                                                              |
| `lines`                             | `ArrayLiteral(StringLiteral)` | Split on newlines.                                                   |
| `split`                             | `ArrayLiteral(StringLiteral)` | Split on whitespace.                                                 |
| `split(string \| char \| regex)`    | `ArrayLiteral(StringLiteral)` | Split on a separator.                                                |
| `strip`                             | `Self`                        | Trim whitespace.                                                     |
| `titleize`                          | `Self`                        | Similar to `String#titleize`.                                        |
| `underscore`                        | `Self`                        | Similar to `String#underscore`.                                      |
| `tr(from, to)`                      | `Self`                        | Character translation.                                               |
| `to_i(base = 10)`                   | `NumberLiteral`               | Integer parse.                                                       |
| `to_utf16`                          | `ASTNode`                     | Experimental: a `Slice(UInt16)` literal expression, null-terminated. |

`split(ASTNode)` is deprecated in favour of `split(StringLiteral)`.

`StringLiteral` and `MacroId` additionally support `<` and `>` for lexical comparison. `StringLiteral` also supports `*(n)` for repetition.

#### StringInterpolation

| Method        | Returns                 | Description                                                                                       |
|---------------|-------------------------|---------------------------------------------------------------------------------------------------|
| `expressions` | `ArrayLiteral(ASTNode)` | The parts in order: string literals for plain text, arbitrary nodes for interpolated expressions. |

#### ArrayLiteral and TupleLiteral

Both share this API. Methods that return a collection return an `ArrayLiteral` on arrays and a `TupleLiteral` on tuples.

| Method                             | Returns                         | Description                                         |
|------------------------------------|---------------------------------|-----------------------------------------------------|
| `any? { }` / `all? { }`            | `BoolLiteral`                   | Predicate tests.                                    |
| `find { }`                         | `ASTNode \| NilLiteral`         | First element matching the block.                   |
| `map { }` / `map_with_index { }`   | collection                      | Transform each element.                             |
| `select { }` / `reject { }`        | collection                      | Filter elements.                                    |
| `reduce { }` / `reduce(memo) { }`  | `ASTNode`                       | Fold.                                               |
| `each { }` / `each_with_index { }` | `NilLiteral`                    | Iterate.                                            |
| `sort` / `sort_by { }`             | collection                      | Sort.                                               |
| `uniq` / `shuffle`                 | collection                      | Deduplicate or shuffle.                             |
| `first` / `last`                   | `ASTNode \| NilLiteral`         | Nil when empty.                                     |
| `size` / `empty?`                  | `NumberLiteral` / `BoolLiteral` | Size queries.                                       |
| `includes?(node)`                  | `BoolLiteral`                   | Membership test.                                    |
| `join(sep)`                        | `StringLiteral`                 | Join elements into a string.                        |
| `splat(trailing = nil)`            | `MacroId`                       | Comma-joined; appends `trailing` only if non-empty. |
| `[](index)`                        | `ASTNode`                       | Element access, `NilLiteral` if out of bounds.      |
| `[](range)` / `[](start, count)`   | collection \| `NilLiteral`      | Slice.                                              |
| `[]=(index, value)`                | `ASTNode`                       | In-place assignment.                                |
| `push` / `<<` / `unshift`          | collection                      | Mutating append and prepend.                        |
| `+(other)` / `-(other)` / `*(n)`   | collection                      | Concatenate, difference, repeat.                    |

`ArrayLiteral` has three additional methods:

| Method  | Returns          | Description                           |
|---------|------------------|---------------------------------------|
| `clear` | `ArrayLiteral`   | Empties the array.                    |
| `of`    | `ASTNode \| Nop` | The `String` in `[] of String`.       |
| `type`  | `Path \| Nop`    | The receiver type in `MyArray{1, 2}`. |

#### HashLiteral

| Method                            | Returns                       | Description                                 |
|-----------------------------------|-------------------------------|---------------------------------------------|
| `[](key)`                         | `ASTNode`                     | Value for the key, `NilLiteral` if missing. |
| `[]=(key, value)`                 | `ASTNode`                     | Assignment.                                 |
| `has_key?(key)`                   | `BoolLiteral`                 | Key test.                                   |
| `keys` / `values`                 | `ArrayLiteral`                | Keys or values.                             |
| `to_a`                            | `ArrayLiteral(TupleLiteral)`  | Key-value pairs.                            |
| `size` / `empty?` / `clear`       | various                       | Size queries and clearing.                  |
| `each { }` / `map { }`            | `NilLiteral` / `ArrayLiteral` | Iteration.                                  |
| `select { }` / `reject { }`       | `HashLiteral`                 | Filter by block.                            |
| `select(*keys)` / `reject(*keys)` | `HashLiteral`                 | Keep or drop the given keys.                |
| `double_splat(trailing = nil)`    | `MacroId`                     | `k => v` pairs joined by commas.            |
| `of_key` / `of_value`             | `ASTNode \| Nop`              | The types in `{} of K => V`.                |
| `type`                            | `Path \| Nop`                 | The receiver type in `MyHash{...}`.         |

#### NamedTupleLiteral

`NamedTupleLiteral` has the same API as `HashLiteral` except that it has no `clear`, `of_key`, `of_value`, or `type`. It adds `each_with_index { }`.

Keys may be given as a `SymbolLiteral`, `StringLiteral`, or `MacroId`. `select` and `reject` return a `NamedTupleLiteral`.

#### RangeLiteral

| Method          | Returns        | Description                               |
|-----------------|----------------|-------------------------------------------|
| `begin` / `end` | `ASTNode`      | Bounds.                                   |
| `excludes_end?` | `ASTNode`      | Whether the range was written with `...`. |
| `each { }`      | `NilLiteral`   | Iterate; integer ranges only.             |
| `map { }`       | `ArrayLiteral` | Transform; integer ranges only.           |
| `to_a`          | `ArrayLiteral` | Expand; integer ranges only.              |

#### RegexLiteral

| Method    | Returns                                | Description                 |
|-----------|----------------------------------------|-----------------------------|
| `source`  | `StringLiteral \| StringInterpolation` | Pattern source.             |
| `options` | `ArrayLiteral(SymbolLiteral)`          | Flags, e.g. `[:i, :m, :x]`. |

### Variables

| Node              | Method                                           | Returns                         | Description                                         |
|-------------------|--------------------------------------------------|---------------------------------|-----------------------------------------------------|
| `Var`             | `id`                                             | `MacroId`                       | Variable name.                                      |
| `InstanceVar`     | `name`                                           | `MacroId`                       | Name without the `@`.                               |
| `ReadInstanceVar` | `obj`, `name`                                    | `ASTNode`, `MacroId`            | Parts of `obj.@var`.                                |
| `ClassVar`        | `name`                                           | `MacroId`                       | Class variable name.                                |
| `Global`          | `name`                                           | `MacroId`                       | Global variable name.                               |
| `MetaVar`         | `name`                                           | `MacroId`                       | Typed variable, as returned by `instance_vars`.     |
|                   | `type`                                           | `TypeNode \| NilLiteral`        | Declared or inferred type.                          |
|                   | `default_value`                                  | `ASTNode`                       | Default value, or `NilLiteral` when there is none.  |
|                   | `has_default_value?`                             | `BoolLiteral`                   | Distinguishes "no default" from a default of `nil`. |
|                   | `annotation(T)`, `annotations(T)`, `annotations` | see [Annotations](#annotations) |                                                     |

### Calls and Arguments

**Call**

| Method       | Returns                       | Description                        |
|--------------|-------------------------------|------------------------------------|
| `name`, `id` | `MacroId`                     | Method name.                       |
| `receiver`   | `ASTNode \| Nop`              | Explicit receiver, if any.         |
| `global?`    | `BoolLiteral`                 | Whether the call starts with `::`. |
| `args`       | `ArrayLiteral`                | Positional arguments.              |
| `named_args` | `ArrayLiteral(NamedArgument)` | Named arguments.                   |
| `block`      | `Block \| Nop`                | Block passed to the call.          |
| `block_arg`  | `ASTNode \| Nop`              | The `&block` argument.             |

**NamedArgument**

| Method  | Returns   | Description     |
|---------|-----------|-----------------|
| `name`  | `MacroId` | Argument name.  |
| `value` | `ASTNode` | Argument value. |

**Block**

| Method        | Returns                       | Description                   |
|---------------|-------------------------------|-------------------------------|
| `body`        | `ASTNode`                     | Block body.                   |
| `args`        | `ArrayLiteral(MacroId)`       | Block parameter names.        |
| `splat_index` | `NumberLiteral \| NilLiteral` | Index of the splat parameter. |

**Arg**

| Method                                           | Returns                         | Description                                 |
|--------------------------------------------------|---------------------------------|---------------------------------------------|
| `name`                                           | `MacroId`                       | External name (`to` in `write(to file)`).   |
| `internal_name`                                  | `MacroId`                       | Internal name (`file` in `write(to file)`). |
| `default_value`                                  | `ASTNode \| Nop`                | Default value, if any.                      |
| `restriction`                                    | `ASTNode \| Nop`                | Type restriction, if any.                   |
| `annotation(T)`, `annotations(T)`, `annotations` | see [Annotations](#annotations) |                                             |

### Control Flow and Expressions

| Node                                                                                                        | Methods                                                                                     |
|-------------------------------------------------------------------------------------------------------------|---------------------------------------------------------------------------------------------|
| `Expressions`                                                                                               | `expressions : ArrayLiteral(ASTNode)`                                                       |
| `If`                                                                                                        | `cond`, `then`, `else`                                                                      |
| `Case`                                                                                                      | `cond`, `whens : ArrayLiteral(When)`, `else`, `exhaustive?` (true for `case ... in`)        |
| `When`                                                                                                      | `conds : ArrayLiteral`, `body`, `exhaustive?` (true for `in`)                               |
| `Select`                                                                                                    | `whens : ArrayLiteral(When)`, `else`                                                        |
| `While`                                                                                                     | `cond`, `body`                                                                              |
| `Assign`                                                                                                    | `target`, `value`                                                                           |
| `MultiAssign`                                                                                               | `targets`, `values`                                                                         |
| `And`, `Or`                                                                                                 | `left`, `right`                                                                             |
| `Not`, `PointerOf`, `SizeOf`, `InstanceSizeOf`, `AlignOf`, `InstanceAlignOf`, `Out`, `Splat`, `DoubleSplat` | `exp`                                                                                       |
| `OffsetOf`                                                                                                  | `type`, `offset`                                                                            |
| `Return`, `Break`, `Next`                                                                                   | `exp : ASTNode \| Nop`; multiple values are wrapped in a `TupleLiteral`                     |
| `Yield`                                                                                                     | `expressions : ArrayLiteral`, `scope : ASTNode \| Nop` (the object after `with`)            |
| `ExceptionHandler`                                                                                          | `body`, `rescues : ArrayLiteral(Rescue) \| NilLiteral`, `else`, `ensure`                    |
| `Rescue`                                                                                                    | `body`, `types : ArrayLiteral \| NilLiteral`, `name : MacroId \| Nop`                       |
| `Cast`, `NilableCast`                                                                                       | `obj`, `to`                                                                                 |
| `IsA`                                                                                                       | `receiver`, `arg`                                                                           |
| `RespondsTo`                                                                                                | `receiver`, `name : StringLiteral`                                                          |
| `TypeOf`                                                                                                    | `args : ArrayLiteral(ASTNode)`                                                              |
| `VisibilityModifier`                                                                                        | `visibility : SymbolLiteral`, `exp`                                                         |
| `Require`                                                                                                   | `path : StringLiteral`                                                                      |
| `ProcLiteral`                                                                                               | `args : ArrayLiteral(Arg)`, `body`, `return_type : ASTNode \| Nop`                          |
| `ProcPointer`                                                                                               | `args`, `obj : ASTNode \| NilLiteral`, `name : MacroId`, `global?`                          |
| `TypeDeclaration`                                                                                           | `var : MacroId`, `type`, `value : ASTNode \| Nop`                                           |
| `UninitializedVar`                                                                                          | `var : MacroId`, `type`                                                                     |
| `Asm`                                                                                                       | `text`, `outputs`, `inputs`, `clobbers`, `volatile?`, `alignstack?`, `intel?`, `can_throw?` |
| `AsmOperand`                                                                                                | `constraint : StringLiteral`, `exp`                                                         |
| `Self`, `Underscore`, `ImplicitObj`, `MagicConstant`                                                        | No methods beyond `ASTNode`                                                                 |

### Definitions

**Def**

| Method                                           | Returns                         | Description                                    |
|--------------------------------------------------|---------------------------------|------------------------------------------------|
| `name`                                           | `MacroId`                       | Method name.                                   |
| `args`                                           | `ArrayLiteral(Arg)`             | Parameters.                                    |
| `splat_index`                                    | `NumberLiteral \| NilLiteral`   | Index of the splat parameter.                  |
| `double_splat`                                   | `Arg \| Nop`                    | The `**` parameter.                            |
| `block_arg`                                      | `Arg \| Nop`                    | The `&` parameter.                             |
| `accepts_block?`                                 | `BoolLiteral`                   | Whether the method can be called with a block. |
| `return_type`                                    | `ASTNode \| Nop`                | Declared return type.                          |
| `free_vars`                                      | `ArrayLiteral(MacroId)`         | The `forall` variables.                        |
| `body`                                           | `ASTNode`                       | Method body.                                   |
| `receiver`                                       | `ASTNode \| Nop`                | The `self` in `def self.foo`.                  |
| `abstract?`                                      | `BoolLiteral`                   | Whether the method is abstract.                |
| `visibility`                                     | `SymbolLiteral`                 | `:public`, `:protected`, or `:private`.        |
| `annotation(T)`, `annotations(T)`, `annotations` | see [Annotations](#annotations) |                                                |

A `Primitive` node represents the body of an `@[Primitive]` def; its `name` returns a `SymbolLiteral`.

**Macro**

`Macro` nodes have `name`, `args`, `splat_index`, `double_splat`, `block_arg`, `body`, and `visibility`, with the same meanings as on `Def`.

**Type definitions**

| Node                | Methods                                                                                                                                |
|---------------------|----------------------------------------------------------------------------------------------------------------------------------------|
| `ClassDef`          | `abstract?`, `kind` (`class` or `struct`), `name(*, generic_args = true)`, `superclass`, `body`, `type_vars`, `splat_index`, `struct?` |
| `ModuleDef`         | `kind`, `name(*, generic_args = true)`, `body`, `type_vars`, `splat_index`                                                             |
| `EnumDef`           | `kind`, `name`, `base_type`, `body`                                                                                                    |
| `AnnotationDef`     | `kind`, `name`, `body` (always `Nop`)                                                                                                  |
| `LibDef`            | `kind`, `name`, `body`                                                                                                                 |
| `CStructOrUnionDef` | `union?`, `kind`, `name`, `body`                                                                                                       |
| `FunDef`            | `name`, `real_name`, `args`, `variadic?`, `return_type`, `body`, `has_body?` (true for top-level funs)                                 |
| `TypeDef`           | `name : Path`, `type`                                                                                                                  |
| `ExternalVar`       | `name`, `real_name`, `type`                                                                                                            |
| `Alias`             | `name : Path`, `type`                                                                                                                  |
| `Include`, `Extend` | `name`                                                                                                                                 |

### Type Expressions

| Node           | Methods                                                                                                           |
|----------------|-------------------------------------------------------------------------------------------------------------------|
| `Path`         | `names : ArrayLiteral(MacroId)`, `global?`, `resolve`, `resolve?`, `types` (the path itself, wrapped in an array) |
| `Generic`      | `name : Path`, `type_vars`, `named_args : NamedTupleLiteral \| NilLiteral`, `resolve`, `resolve?`, `types`        |
| `Union`        | `types`, `resolve`, `resolve?`                                                                                    |
| `Metaclass`    | `instance`, `resolve`, `resolve?`                                                                                 |
| `ProcNotation` | `inputs : ArrayLiteral(ASTNode)`, `output : ASTNode \| NilLiteral`, `resolve`, `resolve?`                         |

`Path.deprecated global` is superseded by `global?`.

### Macro-Internal Nodes

| Node              | Methods                                                                |
|-------------------|------------------------------------------------------------------------|
| `MacroExpression` | `exp`, `output?` (true for `{{ }}`, false for `{% %}`)                 |
| `MacroLiteral`    | `value : MacroId`                                                      |
| `MacroIf`         | `cond`, `then`, `else`, `is_unless?`                                   |
| `MacroFor`        | `vars : ArrayLiteral(Var)`, `exp`, `body`                              |
| `MacroVar`        | `name : MacroId`, `expressions : ArrayLiteral` (the keys of `%v{...}`) |
| `MacroVerbatim`   | `exp`                                                                  |
| `MacroId`         | String methods, plus `<` and `>`                                       |

### TypeNode

`TypeNode` represents a real program type. It is what `@type`, `@top_level`, resolved paths, and type-valued constants produce.

**Kind predicates**

| Method                            | Returns         |
|-----------------------------------|-----------------|
| `abstract?`, `union?`, `nilable?` | `BoolLiteral`   |
| `module?`, `class?`, `struct?`    | `BoolLiteral`   |
| `private?`, `public?`             | `BoolLiteral`   |
| `visibility`                      | `SymbolLiteral` |

**Identity**

| Method                         | Returns                  | Description                                                               |
|--------------------------------|--------------------------|---------------------------------------------------------------------------|
| `name(*, generic_args = true)` | `MacroId`                | Fully qualified name, e.g. `Foo(T)`, or `Foo` with `generic_args: false`. |
| `type_vars`                    | `ArrayLiteral(TypeNode)` | Generic arguments.                                                        |
| `union_types`                  | `ArrayLiteral(TypeNode)` | Union members, or `[self]` for a non-union.                               |
| `class`                        | `TypeNode`               | The metaclass.                                                            |
| `instance`                     | `TypeNode`               | The instance type of a metaclass, otherwise `self`.                       |
| `resolve`, `resolve?`          | `TypeNode`               | Return `self`.                                                            |

**Hierarchy**

| Method                     | Returns                  | Description                                    |
|----------------------------|--------------------------|------------------------------------------------|
| `superclass`               | `TypeNode \| NilLiteral` | Direct parent.                                 |
| `ancestors`                | `ArrayLiteral(TypeNode)` | All ancestors.                                 |
| `subclasses`               | `ArrayLiteral(TypeNode)` | Direct subclasses.                             |
| `all_subclasses`           | `ArrayLiteral(TypeNode)` | All descendants.                               |
| `includers`                | `ArrayLiteral(TypeNode)` | Types that include this module directly.       |
| `<`, `<=`, `>`, `>=`       | `BoolLiteral`            | Subtype relations.                             |
| `overrides?(type, method)` | `BoolLiteral`            | Whether `self` overrides `method` from `type`. |

**Members**

| Method                                           | Returns                         | Description                                        |
|--------------------------------------------------|---------------------------------|----------------------------------------------------|
| `instance_vars`                                  | `ArrayLiteral(MetaVar)`         | Instance variables; only reliable inside a method. |
| `class_vars`                                     | `ArrayLiteral(MetaVar)`         | Class variables.                                   |
| `constants`                                      | `ArrayLiteral(MacroId)`         | Constant and nested type names.                    |
| `constant(name)`                                 | `ASTNode`                       | The value, a `TypeNode`, or `NilLiteral`.          |
| `has_constant?(name)`                            | `BoolLiteral`                   | Constant presence.                                 |
| `methods`                                        | `ArrayLiteral(Def)`             | Own instance methods.                              |
| `all_methods`                                    | `ArrayLiteral(Def)`             | Instance methods, including inherited ones.        |
| `has_method?(name)`                              | `BoolLiteral`                   | Method presence.                                   |
| `annotation(T)`, `annotations(T)`, `annotations` | see [Annotations](#annotations) |                                                    |

**Tuple and NamedTuple types**

| Method    | Returns                  | Description               |
|-----------|--------------------------|---------------------------|
| `size`    | `NumberLiteral`          | Element count.            |
| `keys`    | `ArrayLiteral(MacroId)`  | Named tuple keys.         |
| `[](key)` | `TypeNode \| NilLiteral` | Named tuple element type. |

**Memory**

| Method                | Returns       | Description                                                                                                                |
|-----------------------|---------------|----------------------------------------------------------------------------------------------------------------------------|
| `has_inner_pointers?` | `BoolLiteral` | Whether the type contains inner pointers; types without them may use atomic GC allocations. Only reliable inside a method. |

To get class methods, go through the metaclass:

```crystal
{{ Foo.class.methods.map &.name }}
```

---

## Pitfalls

**Generated code must be complete.** A macro region cannot emit fragments such as bare `when` branches or a `def` without its `end`. Wrap the enclosing construct in `{% begin %} ... {% end %}` so the whole thing is generated together.

**Use `.id` for identifiers.** Interpolating a symbol or string pastes it with its quoting intact (`:foo`, `"foo"`), which is not a valid identifier.

**Local variable capture.** A plain local variable in generated code can overwrite the caller's variable of the same name. Use `%fresh` variables instead.

**Comments do not disable macros.** Macro directives inside comments are still evaluated.

**Evaluation order.** Reflection results reflect only what has been processed so far. Use the `finished` hook, or a macro def, when you need complete type information.

**Context-sensitive results.** `instance_vars` and `has_inner_pointers?` require method context. `doc` and `doc_comment` require `crystal docs`.

**Compile-time side effects.** Backtick commands, `system`, and `run` execute on every compilation. Keep them fast and deterministic, because `run` executables may be cached.