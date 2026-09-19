# Fundamentals of C Bindings

## lib

A `lib` declaration groups C functions and types that belong to a library.

```crystal
@[Link("pcre")]
lib LibPCRE
end
```

Although not enforced by the compiler, a lib's name usually starts with `Lib`.

Attributes are used to pass flags to the linker to find external libraries:

*   `@[Link("pcre")]` will pass `-lpcre` to the linker, but the compiler will first try to use pkg-config.
*   `@[Link(ldflags: "...")]` will pass those flags directly to the linker, without modification. For example: `@[Link(ldflags: "-lpcre")]`. A common technique is to use backticks to execute commands: `@[Link(ldflags: "`pkg-config libpcre --libs`")]`.
*   `@[Link(framework: "Cocoa")]` will pass `-framework Cocoa` to the linker (only useful in macOS).

Attributes can be omitted if the library is implicitly linked, as in the case of libc.

## Reflection

Lib functions are visible in the macro language anywhere in the program using the method `TypeNode#methods`:

```crystal
lib LibFoo
  fun foo
end

{{ LibFoo.methods }} # => [fun foo]
```

## fun

A `fun` declaration inside a lib binds to a C function.

```crystal
lib C
  # In C: double cos(double x)
  fun cos(value : Float64) : Float64
end
```

Once you bind it, the function is available inside the C type as if it was a class method:

```crystal
C.cos(1.5) # => 0.0707372
```

You can omit the parentheses if the function doesn't have parameters (and omit them in the call as well):

```crystal
lib C
  fun getch : Int32
end

C.getch
```

If the return type is `Void` you can omit it:

```crystal
lib C
  fun srand(seed : UInt32)
end

C.srand(1_u32)
```

You can bind to variadic functions:

```crystal
lib X
  fun variadic(value : Int32, ...) : Int32
end

X.variadic(1, 2, 3, 4)
```

Note that there are no implicit conversions (except `to_unsafe`, which is explained later) when invoking a C function: you must pass the exact type that is expected. For integers and floats you can use the various `to_...` methods.

## Function names

Function names in a lib definition can start with an upper case letter. That's different from methods and function definitions outside a lib, which must start with a lower case letter.

Function names in Crystal can be different from the C name. The following example shows how to bind the C function name `SDL_Init` as `LibSDL.init` in Crystal.

```crystal
lib LibSDL
  fun init = SDL_Init(flags : UInt32) : Int32
end
```

The C name can be put in quotes to be able to write a name that is not a valid identifier:

```crystal
lib LLVMIntrinsics
  fun ceil_f32 = "llvm.ceil.f32"(value : Float32) : Float32
end
```

This can also be used to give shorter, nicer names to C functions, as these tend to be long and are usually prefixed with the library name.

## Types in C Bindings

The valid types to use in C bindings are:

*   Primitive types (`Int8`, ..., `Int64`, `UInt8`, ..., `UInt64`, `Float32`, `Float64`)
*   Pointer types (`Pointer(Int32)`, which can also be written as `Int32*`)
*   Static arrays (`StaticArray(Int32, 8)`, which can also be written as `Int32[8]`)
*   Function types (`Proc(Int32, Int32)`, which can also be written as `Int32 -> Int32`)
*   Other struct, union, enum, type or alias declared previously.
*   Void: the absence of a return value.
*   NoReturn: similar to Void, but the compiler understands that no code can be executed after that invocation.
*   Crystal structs marked with the `@[Extern]` annotation

Refer to the type grammar for the notation used in fun types.

The standard library defines the `LibC` lib with aliases for common C types, like `int`, `short`, `size_t`. Use them in bindings like this:

```crystal
lib MyLib
  fun my_fun(some_size : LibC::SizeT)
end
```

> **Note:** The C `char` type is `UInt8` in Crystal, so a `char*` or a `const char*` is `UInt8*`. The `Char` type in Crystal is a unicode codepoint so it is represented by four bytes, making it similar to an `Int32`, not to an `UInt8`. There's also the alias `LibC::Char` if in doubt.

---

# Types and Data Structures

## out

Consider the `waitpid` function:

```crystal
lib C
  fun waitpid(pid : Int32, status_ptr : Int32*, options : Int32) : Int32
end
```

The documentation of the function says:
> The status information from the child process is stored in the object that `status_ptr` points to, unless `status_ptr` is a null pointer.

We can use this function like this:

```crystal
status_ptr = uninitialized Int32

C.waitpid(pid, pointerof(status_ptr), options)
```

In this way we pass a pointer of `status_ptr` to the function for it to fill its value.

There's a simpler way to write the above by using an `out` parameter:

```crystal
C.waitpid(pid, out status_ptr, options)
```

The compiler will automatically declare a `status_ptr` variable of type `Int32`, because the parameter's type is `Int32*`.

This will work for any fun parameter, as long as its type is a pointer (and, of course, as long as the function does fill the value the pointer is pointing to).

## to_unsafe

If a type defines a `to_unsafe` method, when passing it to C the value returned by this method will be passed. For example:

```crystal
lib C
  fun exit(status : Int32) : NoReturn
end

class IntWrapper
  def initialize(@value : Int32)
  end

  def to_unsafe
    @value
  end
end

wrapper = IntWrapper.new(1)
C.exit(wrapper) # wrapper.to_unsafe is passed to C function which has type Int32
```

This is very useful for defining wrappers of C types without having to explicitly transform them to their wrapped values.

For example, the `String` class implements `to_unsafe` to return `UInt8*`:

```crystal
lib C
  fun printf(format : UInt8*, ...) : Int32
end

a = 1
b = 2
C.printf "%d + %d = %d\n", a, b, a + b
```

## struct

A `struct` declaration inside a lib declares a C struct.

```crystal
lib C
  # In C:
  #
  #  struct TimeZone {
  #    int minutes_west;
  #    int dst_time;
  #  };
  struct TimeZone
    minutes_west : Int32
    dst_time : Int32
  end
end
```

You can also specify many fields of the same type:

```crystal
lib C
  struct TimeZone
    minutes_west, dst_time : Int32
  end
end
```

Recursive structs work just like you expect them to:

```crystal
lib C
  struct LinkedListNode
    prev, _next : LinkedListNode*
  end

  struct LinkedList
    head : LinkedListNode*
  end
end
```

Structs that are defined inside a lib can be included, like modules, internally in other lib defined structs, for example:

```crystal
lib Lib
  struct Foo
    x : Int32
    y : Int16
  end

  struct Bar
    include Foo
    z : Int8
  end
end

Lib::Bar.new # => Lib::Bar(@x=0, @y=0, @z=0)
```

To create an instance of a struct use `new`:

```crystal
tz = C::TimeZone.new
```

This allocates the struct on the stack.

A C struct starts with all its fields set to "zero": integers and floats start at zero, pointers start with an address of zero, etc.

To avoid this initialization you can use `uninitialized`:

```crystal
tz = uninitialized C::TimeZone
tz.minutes_west # => some garbage value
```

You can set and get its properties:

```crystal
tz = C::TimeZone.new
tz.minutes_west = 1
tz.minutes_west # => 1
```

If the assigned value is not exactly the same as the property's type, `to_unsafe` will be tried.

You can also initialize some fields with a syntax similar to named arguments:

```crystal
tz = C::TimeZone.new minutes_west: 1, dst_time: 2
tz.minutes_west # => 1
tz.dst_time     # => 2
```

A C struct is passed by value (as a copy) to functions and methods, and also passed by value when it is returned from a method:

```crystal
def change_it(tz)
  tz.minutes_west = 1
end

tz = C::TimeZone.new
change_it tz
tz.minutes_west # => 0
```

Refer to the type grammar for the notation used in struct field types.

## union

A `union` declaration inside a lib declares a C union:

```crystal
lib U
  # In C:
  #
  #  union IntOrFloat {
  #    int some_int;
  #    double some_float;
  #  };
  union IntOrFloat
    some_int : Int32
    some_float : Float64
  end
end
```

To create an instance of a union use `new`:

```crystal
value = U::IntOrFloat.new
```

This allocates the union on the stack.

A C union starts with all its fields set to "zero": integers and floats start at zero, pointers start with an address of zero, etc.

To avoid this initialization you can use `uninitialized`:

```crystal
value = uninitialized U::IntOrFloat
value.some_int # => some garbage value
```

You can set and get its properties:

```crystal
value = U::IntOrFloat.new
value.some_int = 1
value.some_int   # => 1
value.some_float # => 4.94066e-324
```

If the assigned value is not exactly the same as the property's type, `to_unsafe` will be tried.

A C union is passed by value (as a copy) to functions and methods, and also passed by value when it is returned from a method:

```crystal
def change_it(value)
  value.some_int = 1
end

value = U::IntOrFloat.new
change_it value
value.some_int # => 0
```

Refer to the type grammar for the notation used in union field types.

## enum

An `enum` declaration inside a lib declares a C enum:

```crystal
lib X
  # In C:
  #
  #  enum SomeEnum {
  #    Zero,
  #    One,
  #    Two,
  #    Three,
  #  };
  enum SomeEnum
    Zero
    One
    Two
    Three
  end
end
```

As in C, the first member of the enum has a value of zero and each successive value is incremented by one.

To use a value:

```crystal
X::SomeEnum::One # => One
```

You can specify the value of a member:

```crystal
lib X
  enum SomeEnum
    Ten       = 10
    Twenty    = 10 * 2
    ThirtyTwo = 1 << 5
  end
end
```

As you can see, some basic math is allowed for a member value: `+`, `-`, `*`, `/`, `&`, `|`, `<<`, `>>` and `%`.

The type of an enum member is `Int32` by default. It's an error to specify a different type in a constant value.

```crystal
lib X
  enum SomeEnum
    A = 1_u32 # Error: enum value must be an Int32
  end
end
```

However, you can change this default type:

```crystal
lib X
  enum SomeEnum : Int8
    Zero
    Two  = 2
  end
end

X::SomeEnum::Zero # => 0_i8
X::SomeEnum::Two  # => 2_i8
```

You can use an enum as a type in a fun parameter or struct or union members:

```crystal
lib X
  enum SomeEnum
    One
    Two
  end

  fun some_fun(value : SomeEnum)
end
```

---

# Variables, Constants, and Aliases

## Variables

Variables exposed by a C library can be declared inside a lib declaration using a global-variable-like declaration:

```crystal
lib C
  $errno : Int32
  $buffer : UInt8[256]
end
```

Then it can be get and set:

```crystal
C.errno # => some value
C.errno = 0
C.errno # => 0

C.buffer # => StaticArray(UInt8, 256)
C.buffer = StaticArray(UInt8, 256).new(0_u8)
```

A variable can be marked as thread local with an annotation:

```crystal
lib C
  @[ThreadLocal]
  $errno : Int32
end
```

Refer to the type grammar for the notation used in external variables types.

## Constants

You can also declare constants inside a lib declaration:

```crystal
@[Link("pcre")]
lib PCRE
  INFO_CAPTURECOUNT = 2
end

PCRE::INFO_CAPTURECOUNT # => 2
```

## type

A `type` declaration inside a lib declares a kind of C typedef, but stronger:

```crystal
lib X
  type MyInt = Int32
end
```

Unlike C, `Int32` and `MyInt` are not interchangeable:

```crystal
lib X
  type MyInt = Int32

  fun some_fun(value : MyInt)
end

X.some_fun 1 # Error: argument 'value' of 'X#some_fun' must be X::MyInt, not Int32
```

Thus, a type declaration is useful for opaque types that are created by the C library you are wrapping. An example of this is the C `FILE` type, which you can obtain with `fopen`.

Refer to the type grammar for the notation used in typedef types.

## alias

An `alias` declaration inside a lib declares a C typedef:

```crystal
lib X
  alias MyInt = Int32
end
```

Now `Int32` and `MyInt` are interchangeable:

```crystal
lib X
  alias MyInt = Int32

  fun some_fun(value : MyInt)
end

X.some_fun 1 # OK
```

An alias is most useful to avoid writing long types over and over, but also to declare a type based on compile-time flags:

```crystal
lib C
  {% if flag?(:x86_64) %}
    alias SizeT = Int64
  {% else %}
    alias SizeT = Int32
  {% end %}

  fun memcmp(p1 : Void*, p2 : Void*, size : C::SizeT) : Int32
end
```

Refer to the type grammar for the notation used in alias types.

---

# Advanced Concepts and Unsafe Code

## Callbacks

You can use function types in C declarations:

```crystal
lib X
  # In C:
  #
  #    void callback(int (*f)(int));
  fun callback(f : Int32 -> Int32)
end
```

Then you can pass a function (a `Proc`) like this:

```crystal
f = ->(x : Int32) { x + 1 }
X.callback(f)
```

If you define the function inline in the same call you can omit the parameter types, the compiler will add the types for you based on the fun signature:

```crystal
X.callback ->(x) { x + 1 }
```

Note, however, that functions passed to C can't form closures. If the compiler detects at compile-time that a closure is being passed, an error will be issued:

```crystal
y = 2
X.callback ->(x) { x + y } # Error: can't send closure to C function
```

If the compiler can't detect this at compile-time, an exception will be raised at runtime.

Refer to the type grammar for the notation used in callbacks and procs types.

If you want to pass `NULL` instead of a callback, just pass `nil`:

```crystal
# Same as callback(NULL) in C
X.callback nil
```

## Passing a closure to a C function

Most of the time a C function that allows setting a callback also provides a parameter for custom data. This custom data is then sent as an argument to the callback. For example, suppose a C function that invokes a callback at every tick, passing that tick:

```crystal
lib LibTicker
  fun on_tick(callback : (Int32, Void* ->), data : Void*)
end
```

To properly define a wrapper for this function we must send the `Proc` as the callback data, and then convert that callback data to the `Proc` and finally invoke it.

```crystal
module Ticker
  # The callback for the user doesn't have a Void*
  @@box : Pointer(Void)?

  def self.on_tick(&callback : Int32 ->)
    # Since Proc is a {Void*, Void*}, we can't turn that into a Void*, so we
    # "box" it: we allocate memory and store the Proc there
    boxed_data = Box.box(callback)

    # We must save this in Crystal-land so the GC doesn't collect it (*)
    @@box = boxed_data

    # We pass a callback that doesn't form a closure, and pass the boxed_data as
    # the callback data
    LibTicker.on_tick(->(tick, data) {
      # Now we turn data back into the Proc, using Box.unbox
      data_as_callback = Box(typeof(callback)).unbox(data)
      # And finally invoke the user's callback
      data_as_callback.call(tick)
    }, boxed_data)
  end
end

Ticker.on_tick do |tick|
  puts tick
end
```

Note that we save the boxed callback in `@@box`. The reason is that if we don't do it, and our code doesn't reference it anymore, the GC will collect it. The C library will of course store the callback, but Crystal's GC has no way of knowing that.

## Raises annotation

If a C function executes a user-provided callback that might raise, it must be annotated with the `@[Raises]` annotation.

The compiler infers this annotation for a method if it invokes a method that is marked as `@[Raises]` or raises (recursively).

However, some C functions accept callbacks to be executed by other C functions. For example, suppose a fictitious library:

```crystal
lib LibFoo
  fun store_callback(callback : ->)
  fun execute_callback
end

LibFoo.store_callback -> { raise "OH NO!" }
LibFoo.execute_callback
```

If the callback passed to `store_callback` raises, then `execute_callback` will raise. However, the compiler doesn't know that `execute_callback` can potentially raise because it is not marked as `@[Raises]` and the compiler has no way to figure this out. In these cases you have to manually mark such functions:

```crystal
lib LibFoo
  fun store_callback(callback : ->)

  @[Raises]
  fun execute_callback
end
```

If you don't mark them, `begin/rescue` blocks that surround this function's calls won't work as expected.

## Unsafe code

These parts of the language are considered unsafe:

*   Code involving raw pointers: the `Pointer` type and `pointerof`.
*   The `allocate` class method.
*   Code involving C bindings.
*   Uninitialized variable declaration.

"Unsafe" means that memory corruption, segmentation faults and crashes are possible to achieve. For example:

```crystal
a = 1
ptr = pointerof(a)
ptr[100_000] = 2 # undefined behaviour, probably a segmentation fault
```

However, regular code usually never involves pointer manipulation or uninitialized variables. And C bindings are usually wrapped in safe wrappers that include null pointers and bounds checks.

No language is 100% safe: some parts will inevitably be low-level, interface with the operating system and involve pointer manipulation. But once you abstract that and operate on a higher level, and assume (after mathematical proof or thorough testing) that the lower grounds are safe, you can be confident that your entire codebase is safe.