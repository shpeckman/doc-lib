# Crystal's `private` and `protected`

A reference guide to method and type visibility in Crystal. Applies to Crystal 1.21.

Official docs: <https://crystal-lang.org/reference/latest/syntax_and_semantics/visibility.html>

---

## TL;DR

- Methods are **public by default**. There is no `public` keyword.
- **`private`** — callable only with *no receiver* (implicit self). The single exception: an explicit `self.` receiver is allowed.
- **`protected`** — callable on any receiver, but only from the scope of the same type, its descendants, or types in the same namespace.
- **Private constants/types** — reachable only via *relative* constant lookup inside their namespace tree; a fully qualified path is rejected even from inside the namespace.
- Both are **compile-time only** checks. No runtime cost, no security boundary.
- Mental model:

> **`private` = "no dot, ever."**
> **`protected` = "dots allowed, if the concrete self type and the method's defining type are the same, related by inheritance, or in the same namespace."**

### Quick reference

| Caller location                              | `private` | `protected` |
|----------------------------------------------|-----------|-------------|
| Same instance, no receiver / `self.`         | ✅         | ✅           |
| Another instance, same class                 | ❌         | ✅           |
| Subclass (implicit or `self.`)               | ✅         | ✅           |
| Unrelated class, same namespace              | ❌         | ✅           |
| Unrelated class / top level                  | ❌         | ❌           |
| Different instantiation of same generic type | ❌         | ✅           |

---

## 1. The default: public

Every method in Crystal is public unless marked otherwise. There is no `public` keyword — you only ever write the restrictive half of the spectrum.

```crystal
class Greeter
  def hello # public, like everything else
    "hi"
  end
end
```

---

## 2. `private` methods

### The rule

A `private` method can only be invoked **without a receiver** — nothing before the dot. The one exception is an explicit `self` receiver.

```crystal
class Person
  private def say(message)
    puts message
  end

  def say_hello
    say "hello"       # OK — no receiver (implicit self)
    self.say "hello"  # OK — explicit self is allowed
  end
end

Person.new.say "hello"
# Error: private method 'say' called for Person
```

### Consequences

**No "friend" access.** Unlike C++ or Java, one instance *cannot* call a private method on another instance of the same class — not even inside the class body. If you need instance-to-instance access, that's what `protected` is for.

**Subclasses can call them** — both implicitly and via explicit `self`:

```crystal
class Parent
  private def secret
    "parent secret"
  end
end

class Child < Parent
  def reveal
    self.secret # OK
  end
end

puts Child.new.reveal # => "parent secret"
```

**Works identically in structs, modules, and generics.** A private method in a module is callable implicitly by any includer:

```crystal
module Whisperer
  private def whisper
    "psst..."
  end

  def speak
    "speaks, then #{whisper}" # OK
  end
end

class Host
  include Whisperer
end

Host.new.whisper
# Error: private method 'whisper' called for Whisperer
# (note: the error names the MODULE that defines the method, not the includer)
```

---

## 3. `protected` methods

### The rule

A `protected` method may be called on an explicit receiver, but only from:

1. the scope of the **same type** the method is defined on,
2. the scope of its **descendants** (subclasses, including types), or
3. a type in the **same namespace** (class, module, etc.).

This is roughly Java's `protected` ("package-private + subclasses"), **not** Ruby's.

### Same type: instance-to-instance access

```crystal
class Wallet
  protected def balance
    100
  end

  def total_with(other : Wallet)
    balance + other.balance # OK — Wallet code touching another Wallet
  end
end

puts Wallet.new.total_with(Wallet.new) # => 200
```

### Same namespace: cross-type access

```crystal
module Shop
  class Register
    protected def open_drawer
      puts "drawer opened"
    end
  end

  class Cashier
    def work
      Register.new.open_drawer # OK — Cashier and Register share namespace Shop
    end
  end
end
```

**Nested namespaces count:** `Outer::Inner::Tool` can call protected methods of `Outer::Widget`, because `Tool` lives inside the `Outer` namespace tree.

**Modules confer access to all includers:** two unrelated classes that both `include` the same module can call each other's protected methods defined in that module:

```crystal
module Shielded
  protected def shield
    "raised shield"
  end
end

class Knight
  include Shielded

  def escort(m : Mage)
    "knight covers mage: #{m.shield}" # OK — both include Shielded
  end
end

class Mage
  include Shielded
end

puts Knight.new.escort(Mage.new) # => "knight covers mage: raised shield"
```

### Descendants: subclass scope

```crystal
module Engine
  class Base
    protected def crank
      "vroom"
    end
  end
end

class Car < Engine::Base
  def start
    "#{crank} | #{Engine::Base.new.crank}" # both OK — Car descends from Engine::Base
  end
end
```

Note this works even though `Car` lives in a **different namespace** — the inheritance rule and the namespace rule are independent.

### What's rejected

```crystal
class Thief
  def peek(w : Wallet)
    w.balance # Error: protected method 'balance' called for Wallet
  end
end

Wallet.new.balance # same error — top level (Program scope) is not in Wallet's scope
```

---

## 4. Beyond methods

### Private constants and types

`private` applies to `class`, `module`, `lib`, `enum`, `alias`, and constants. Such names are reachable **only through relative constant lookup from inside their namespace tree** — an explicitly qualified path is rejected everywhere, even inside the namespace itself (see §5.7):

```crystal
class Config
  private SECRET = 42

  def reveal
    SECRET # OK — relative lookup, inside the namespace
  end
end

Config::SECRET
# Error: private constant Config::SECRET referenced
```

This applies to enum **members** too:

```crystal
class Machine
  private enum State
    Off
    On
  end
end

Machine::State::On
# Error: private constant Machine::State::On referenced
```

### File-scoped private (top level)

At the top level, `private` means **visible in the current file only** — Crystal's idiom for per-file helpers, like C's `static` functions:

```crystal
# one.cr
private def helper
  "I'm private to one.cr"
end

private class Internal
end

def use_them
  helper # OK — same file
end
```

```crystal
# two.cr
require "./one"

use_them # OK — the public method works
helper   # Error: undefined local variable or method 'helper' for top-level
Internal # Error: undefined constant 'Internal'
```

### Private setters

Setter methods follow the same rules, and explicit `self.` is allowed:

```crystal
class Counter
  @value = 0

  private def value=(v : Int32)
    @value = v
  end

  def bump
    self.value = @value + 1 # OK
  end
end

Counter.new.value = 5
# Error: private method 'value=' called for Counter
```

⚠️ Watch out: inside a method, `value = 5` **without** `self.` creates a *local variable* — it does not call the setter. Private setters effectively force you to write `self.value = ...`, which is a nice side effect.

### Private constructors

`private def initialize` makes the type non-instantiable from outside — the factory pattern:

```crystal
class Token
  private def initialize(@id : Int32)
  end

  def self.mint
    new(42) # OK from a class method
  end
end

Token.new(7)
# Error: private method 'new' called for Token.class
# (note: the error is about `.new`, which becomes private along with initialize)
```

### Class methods and the class body

`private def self.x` / `protected def self.x` work, callable from class-method scope and from the class body (e.g. constant initializers):

```crystal
class Registry
  protected def self.entries
    3
  end

  SIZE = entries # OK — class body scope
end
```

---

## 5. Edge cases and gotchas

These behaviors are easy to get wrong; the docs do not spell all of them out.

### 5.1 Private class methods are NOT callable from instance methods

The "no receiver except `self`" rule is literal. Inside an instance method, `self` is an instance — so even `Vault.code`, written right there in the same class, fails:

```crystal
class Vault
  private def self.code
    777
  end

  def self.open
    "opened with #{code}" # OK — in class-method scope, self IS Vault
  end

  def peek
    Vault.code # Error: private method 'code' called for Vault.class
  end
end
```

### 5.2 Generics: all instantiations share `protected` access

Different instantiations of the same generic type count as "the same type" for protected:

```crystal
class Crate(T)
  def initialize(@v : T)
  end

  protected def raw
    @v
  end

  def combine_any(other : Crate(U)) forall U
    "#{raw}+#{other.raw}" # OK
  end
end

puts Crate.new(1).combine_any(Crate.new("two")) # => "1+two"
```

### 5.3 The abstract-class + override trap

The classic OO pattern "compare two shapes via a protected method" **does not compile** when the method is overridden per subclass:

```crystal
abstract class Shape
  protected abstract def area : Float64 # note: `protected abstract def` is legal

  def bigger_than?(other : Shape)
    area > other.area
  end
end

class Circle < Shape
  protected def area : Float64
    Math::PI * @r * @r
  end
  # ...
end

class Square < Shape
  protected def area : Float64
    @s * @s
  end
  # ...
end

Circle.new(1.5).bigger_than?(Square.new(1.0))
# Error: protected method 'area' called for Square
```

But each of these variants **works**:

| Variant                                                                                                                                              | Result |
|------------------------------------------------------------------------------------------------------------------------------------------------------|--------|
| Same concrete type both sides: `Circle.new.bigger_than?(Circle.new(1.0))`                                                                            | ✅      |
| Via virtual/ancestor-typed refs: `shapes = [c, s] of Shape; shapes[0].bigger_than?(shapes[1])`                                                       | ✅      |
| Method defined **concretely once in the parent**, inherited (not overridden) — e.g. `Dog` calling `sound` on a `Cat` where `sound` lives in `Animal` | ✅      |

**Why:** the protected check compares the *concrete self type* against the *type where the method is defined*. When self is `Circle` and the method found is `Square#area`, those are unrelated types → error. When the method is defined in the shared parent, any descendant scope qualifies.

**Practical takeaway:** this is why Crystal's own `Comparable` idiom keeps `<=>` public and pushes internals into a `protected getter`:

```crystal
class Temp
  include Comparable(Temp)

  protected getter celsius : Float64

  def initialize(@celsius : Float64)
  end

  def <=>(other : Temp) # public — required for Comparable
    celsius <=> other.celsius
  end
end

puts Temp.new(20.0) < Temp.new(25.0) # => true
Temp.new(20.0).celsius               # Error: protected method 'celsius' called for Temp
```

### 5.4 Overriding visibility in subclasses

- **Widening** (parent `private` → child public) works: the child's redefinition simply replaces the method.
- **Narrowing** (parent public → child `private`) also works — and it is *airtight*. Even calling through a parent-typed reference with virtual dispatch is blocked:

```crystal
class Base
  def whoami
    "base"
  end
end

class Shy < Base
  private def whoami
    "shy"
  end
end

Shy.new.whoami          # Error: private method 'whoami' called for Shy
Shy.new.as(Base).whoami # Error: private method 'whoami' called for Shy
```

### 5.5 Method captures (procs) follow visibility

```crystal
class Greeter
  private def hello(name : String)
    "hi #{name}"
  end

  def callback
    ->hello(String) # OK — capturing your own private method
  end
end

g = Greeter.new
f = ->g.hello(String)
# Error: private method 'hello' called for Greeter
```

### 5.6 Private methods are invisible inside `with self yield` blocks

The failure is not even a visibility error — the block is compiled at its definition site, where the method simply doesn't exist:

```crystal
class Speaker
  private def emit(msg)
    "speaker says #{msg}"
  end

  def run(& : -> String)
    with self yield
  end
end

Speaker.new.run { emit("hello") }
# Error: undefined method 'emit' for top-level
```

Don't rely on private helpers inside DSL-style blocks.

### 5.7 Private constants and types require *relative* paths

A private type or constant is resolved through ordinary lexical constant lookup. If you spell out a qualified path that traverses the private name, the reference is rejected — **even when it sits inside the owning namespace itself**:

```crystal
module VT
  private enum Act : UInt8
    Exec
  end

  def self.go
    Act::Exec # OK — relative lookup
  end
end

module VT::Inner
  def self.go
    Act::Exec # OK — relative lookup from a nested namespace
  end
end

module VT
  def self.broken
    VT::Act::Exec # Error: private constant VT::Act::Exec referenced
  end
end
```

Note that the last one fails *inside `VT` itself*. The real rule is not "inside vs outside the namespace" but "relative vs qualified": any path that explicitly traverses the private constant is rejected, wherever it appears.

**Practical consequence:** when you make an existing type private, you must also de-qualify every internal reference to it (`VT::St::Gnd` → `St::Gnd`). Code elsewhere that already uses relative names — including code in nested namespaces and compact-form definitions like `module VT::Inner` — keeps compiling unchanged.

---

## 6. Compiler error reference

| Situation                                                            | Message                                                     |
|----------------------------------------------------------------------|-------------------------------------------------------------|
| Private method with a receiver                                       | `private method 'say' called for Person`                    |
| Private setter from outside                                          | `private method 'value=' called for Counter`                |
| Private constructor via `.new`                                       | `private method 'new' called for Token.class`               |
| Module's private method from outside                                 | `private method 'whisper' called for Whisperer`             |
| Protected method from unrelated type / top level                     | `protected method 'balance' called for Wallet`              |
| Protected getter from outside                                        | `protected method 'celsius' called for Temp`                |
| Protected override across sibling types                              | `protected method 'area' called for Square`                 |
| Private constant from outside                                        | `private constant Config::SECRET referenced`                |
| Private enum member from outside                                     | `private constant Machine::State::On referenced`            |
| Qualified path to a private constant, even from inside its namespace | `private constant VT::Act::Exec referenced`                 |
| File-private method from another file                                | `undefined local variable or method 'helper' for top-level` |
| File-private type from another file                                  | `undefined constant 'Internal'`                             |

---

## 7. The rule, precisely

**`private` methods** — the call must have *no receiver*, or the receiver must be exactly `self`. Nothing else matters: not the class you're in, not inheritance, not modules. This rule is uniform across instance methods, class methods, setters, and constructors.

**`private` constants and types** — reachable only via *relative* constant lookup from within the owning namespace tree (nesting counts). A qualified path that explicitly traverses the private name is rejected everywhere, including inside the namespace itself.

**`protected`** — explicit receivers are allowed, and the check is between the **concrete self type** at the call site and the **type where the method is defined**. Access is granted when any of these holds:

1. the two types are the same (all instantiations of one generic type count as the same);
2. the self type is a descendant of (or includes) the defining type;
3. the two types share a namespace (nesting counts).

Corollaries that fall out of this:

- Private methods can't be called on *anyone else*, period — no friend access.
- Private class methods are unreachable from instance methods (the receiver would be the class, not `self`).
- Privatizing an existing type forces de-qualification of internal references (`VT::St` → `St`); relative references from nested namespaces keep working.
- Protected methods defined once in a parent are freely usable across the whole hierarchy; protected methods *overridden per subclass* are locked to each concrete sibling.
- Visibility is enforced per method definition — subclasses can widen or narrow it, and narrowing survives virtual dispatch.
- None of it exists at runtime. It's purely a compile-time contract.
