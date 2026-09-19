# Concurrency

## Concurrency vs. Parallelism

The definitions of "concurrency" and "parallelism" sometimes get mixed up, but they are not the same.
A concurrent system is one that can be in charge of many tasks, although not necessarily executing them at the same time. You can think of yourself being in the kitchen cooking: you chop an onion, put it to fry, and while it's being fried you chop a tomato, but you are not doing all of those things at the same time: you distribute your time between those tasks. Parallelism would be to stir fry onions with one hand while with the other one you chop a tomato.
Crystal supports both concurrency and parallelism: several tasks can be executed, and a bit of time will be spent on each of these, and two code paths may be executed at the same exact time.
A Crystal program by default executes a single fiber at a time, thus concurrent only, while parallelism is opt-in. See the documentation about parallelism for details.
The examples on this page assume that the runtime is concurrent only and that the program didn't opt-in to MT (Multithreading). The demonstrated properties are still valid with MT enabled, but the order of operations and the expected output may be slightly different because fibers may not run sequentially anymore.

## Fibers

To achieve concurrency, Crystal has fibers. A fiber is in a way similar to an operating system thread except that it's much more lightweight and its execution is managed internally by the process. So, a program will spawn multiple fibers and Crystal will make sure to execute them when the time is right.

## Event loop

For everything I/O related there's an event loop. Some time-consuming operations are delegated to it, and while the event loop waits for that operation to finish the program can continue executing other fibers. A simple example of this is waiting for data to come through a socket.

## Channels

Crystal has Channels inspired by CSP. They allow communicating data between fibers without sharing memory and without having to worry about locks, semaphores or other special structures.

## Execution of a program

When a program starts, it fires up a main fiber that will execute your top-level code. There, one can spawn many other fibers. The components of a program are:

*   **The Runtime Scheduler(s):** in charge of executing all fibers when the time is right.
*   **The Event Loop:** being in charge of async tasks, like for example files, sockets, pipes, signals and timers (like doing a sleep).
*   **Channels:** to communicate data between fibers. The Runtime Scheduler will coordinate fibers and channels for their communication.
*   **Garbage Collector:** to clean up "no longer used" memory.

## A Fiber

A fiber is an execution unit that is more lightweight than a thread. It's a small object that has an associated stack of 8MB, which is what is usually assigned to an operating system thread.
Fibers, unlike threads, are cooperative. Threads are pre-emptive: the operating system might interrupt a thread at any time and start executing another one. A fiber must explicitly tell the Runtime Scheduler to switch to another fiber. For example if there's I/O to be waited on, a fiber will tell the scheduler "Look, I have to wait for this I/O to be available, you continue executing other fibers and come back to me when that I/O is ready".
The advantage of being cooperative is that a lot of the overhead of doing a context switch (switching between threads) is gone.
A Fiber is much more lightweight than a thread: even though it's assigned 8MB, it starts with a small stack of 4KB.
On a 64-bit machine it lets us spawn millions and millions of fibers. In a 32-bit machine we can only spawn 512 fibers, which is not a lot. But because 32-bit machines are starting to become obsolete, we'll bet on the future and focus more on 64-bit machines.

## The Runtime Scheduler(s)

Each scheduler has a queue of:

*   **Fibers ready to be executed:** for example when you spawn a fiber, it's ready to be executed.
*   **The event loop:** when there are no other fibers ready to be executed, the event loop checks if there is any async operation that is ready, and then executes the fiber waiting for that operation.
*   **Fibers that voluntarily asked to wait:** this is done with `Fiber.yield`, which means "I can continue executing, but I'll give you some time to execute other fibers if you want".

## Communicating data

Accessing and modifying global data (constants, class variables) and shared data (closured variables) is unsafe. That's why the recommended mechanism to communicate data is using channels and sending messages between them. Internally, a channel implements all the locking mechanisms to avoid data races, but from the outside you use them as communication primitives, so you (the user) don't have to use locks.

# Sample code

## Spawning a fiber

To spawn a fiber you use `spawn` with a block:

```crystal
spawn do
  # ...
  socket.gets
  # ...
end

spawn do
  # ...
  sleep 5.seconds
  #  ...
end
```

Here we have two fibers: one reads from a socket and the other does a sleep. When the first fiber reaches the `socket.gets` line, it gets suspended, the Event Loop is told to continue executing this fiber when there's data in the socket, and the program continues with the second fiber. This fiber wants to sleep for 5 seconds, so the Event Loop is told to continue with this fiber in 5 seconds. If there aren't other fibers to execute, the Event Loop will wait until either of these events happen, without consuming CPU time.
The reason why `socket.gets` and `sleep` behave like this is because their implementations talk directly with the Runtime Scheduler and the Event Loop, there's nothing magical about it. In general, the standard library already takes care of doing all of this so you don't have to.
Note, however, that fibers don't get executed right away. For example:

```crystal
spawn do
  loop do
    puts "Hello!"
  end
end
```

Running the above code will usually produce no output and exit immediately. In rare cases, another thread may resume the fiber when parallelism is enabled.
The reason for this is that a fiber is not executed as soon as it is spawned. So, the main fiber, the one that spawns the above fiber, finishes its execution and the program exits.
One way to solve it is to do a sleep:

```crystal
spawn do
  loop do
    puts "Hello!"
  end
end

sleep 1.second
```

This program will now print "Hello!" for one second and then exit. This is because the `sleep` call will schedule the main fiber to be executed in a second, and then executes another "ready to execute" fiber, which in this case is the one above.
Another way is this:

```crystal
spawn do
  loop do
    puts "Hello!"
  end
end

Fiber.yield
```

This time `Fiber.yield` will tell the scheduler to execute the other fiber. This will usually print "Hello!" until the standard output blocks (the system call will tell us we have to wait until the output is ready), and then execution continues with the main fiber and the program exits. Here the standard output might never block so the program will continue executing forever. In rare cases, another thread might resume the fiber when parallelism is enabled, or another fiber be resumed and the program will exit normally, possibly printing nothing.
If we want to execute the spawned fiber for ever, we can use `sleep` without arguments:

```crystal
spawn do
  loop do
    puts "Hello!"
  end
end

sleep
```

Of course the above program can be written without `spawn` at all, just with a loop. `sleep` is more useful when spawning more than one fiber.

## Spawning a call

You can also spawn by passing a method call instead of a block. To understand why this is useful, let's look at this example:

```crystal
i = 0
while i < 10
  spawn do
    puts(i)
  end
  i += 1
end

Fiber.yield
```

The above program prints "10" ten times. The problem is that there's only one variable `i` that all spawned fibers refer to, and when `Fiber.yield` is executed its value is 10.
To solve this, we can do this:

```crystal
i = 0
while i < 10
  proc = ->(x : Int32) do
    spawn do
      puts(x)
    end
  end
  proc.call(i)
  i += 1
end

Fiber.yield
```

Now it works because we are creating a Proc and we invoke it passing `i`, so the value gets copied and now the spawned fiber receives a copy.
To avoid all this boilerplate, the standard library provides a `spawn` macro that accepts a call expression and basically rewrites it to do the above. Using it, we end up with:

```crystal
i = 0
while i < 10
  spawn puts(i)
  i += 1
end

Fiber.yield
```

This is mostly useful with local variables that change at iterations. This doesn't happen with block arguments. For example, this works as expected:

```crystal
10.times do |i|
  spawn do
    puts i
  end
end

Fiber.yield
```

## Spawning a fiber and waiting for it to complete

We can use a channel for this:

```crystal
channel = Channel(Nil).new

spawn do
  puts "Before send"
  channel.send(nil)
  puts "After send"
end

puts "Before receive"
channel.receive
puts "After receive"
```

This prints:

```text
Before receive
Before send
After send
After receive
```

First, the program spawns a fiber but doesn't execute it yet. When we invoke `channel.receive`, the main fiber blocks and execution continues with the spawned fiber. Then `channel.send(nil)` is invoked. Note that this send does not occupy space in the channel because there is a receive invoked prior to the first send, send is not blocked. Fibers only switch out when blocked or executing to completion. So the spawned fiber will continue after send, and execution will switch back to main fiber once `puts "After send"` is executed.
The main fiber then resumes at `channel.receive`, which was waiting for a value. Then the main fiber continues executing and finishes.
In the above example we used `nil` just to communicate that the fiber ended, a scenario where `WaitGroup` would have been a more efficient choice. A better use of channels is to send values between fibers:

```crystal
channel = Channel(Int32).new

spawn do
  puts "Before first send"
  channel.send(1)
  puts "Before second send"
  channel.send(2)
end

puts "Before first receive"
value = channel.receive
puts value # => 1

puts "Before second receive"
value = channel.receive
puts value # => 2
```

Output:

```text
Before first receive
Before first send
Before second send
1
Before second receive
2
```

Note that when the program executes a receive, the current fiber blocks and execution continues with the other fiber. When `channel.send(1)` is executed, execution continues because send is non-blocking if the channel is not yet full. However, `channel.send(2)` does cause the fiber to block because the channel (which has a size of 1 by default) is full, so execution continues with the fiber that was waiting on that channel.
Here we are sending literal values, but the spawned fiber might compute this value by, for example, reading a file, or getting it from a socket. When this fiber will have to wait for I/O, other fibers will be able to continue executing code until I/O is ready, and finally when the value is ready and sent through the channel, the main fiber will receive it. For example:

```crystal
require "socket"

channel = Channel(String).new

spawn do
  server = TCPServer.new("0.0.0.0", 8080)
  socket = server.accept
  while line = socket.gets
    channel.send(line)
  end
end

spawn do
  while line = gets
    channel.send(line)
  end
end

3.times do
  puts channel.receive
end
```

The above program spawns two fibers. The first one creates a `TCPServer`, accepts one connection and reads lines from it, sending them to the channel. There's a second fiber reading lines from standard input. The main fiber reads the first 3 messages sent to the channel, either from the socket or stdin, then the program exits. The `gets` calls will block the fibers and tell the Event Loop to continue from there if data comes.
Likewise, we can wait for multiple fibers to complete execution, and gather their values:

```crystal
channel = Channel(Int32).new

10.times do |i|
  spawn do
    channel.send(i * 2)
  end
end

sum = 0
10.times do
  sum += channel.receive
end
puts sum # => 90
```

You can, of course, use receive inside a spawned fiber:

```crystal
channel = Channel(Int32).new

spawn do
  puts "Before send"
  channel.send(1)
  puts "After send"
end

spawn do
  puts "Before receive"
  puts channel.receive
  puts "After receive"
end

puts "Before yield"
Fiber.yield
puts "After yield"
```

Output:

```text
Before yield
Before send
Before receive
1
After receive
After send
After yield
```

Here `channel.send` is executed first, but since there's no one waiting for a value (yet), execution continues in other fibers. The second fiber is executed, there's a value on the channel, it's obtained, and execution continues, first with the first fiber, then with the main fiber, because `Fiber.yield` puts a fiber at the end of the execution queue.

## Buffered channels

The above examples use unbuffered channels: when sending a value, if a fiber is waiting on that channel then execution continues on that fiber.
With a buffered channel, invoking send won't switch to another fiber unless the buffer is full:

```crystal
# A buffered channel of capacity 2
channel = Channel(Int32).new(2)

spawn do
  puts "Before send 1"
  channel.send(1)
  puts "Before send 2"
  channel.send(2)
  puts "Before send 3"
  channel.send(3)
  puts "After send"
end

3.times do |i|
  puts channel.receive
end
```

Output:

```text
Before send 1
Before send 2
Before send 3
After send
1
2
3
```

Note that the first send does not occupy space in the channel. This is because there is a receive invoked prior to the first send whereas the other 2 send invocations take place before their respective receive. The number of send calls do not exceed the bounds of the buffer and so the send fiber runs uninterrupted to completion.
Here's an example where all space in the buffer gets occupied:

```crystal
# A buffered channel of capacity 1
channel = Channel(Int32).new(1)

spawn do
  puts "Before send 1"
  channel.send(1)
  puts "Before send 2"
  channel.send(2)
  puts "Before send 3"
  channel.send(3)
  puts "End of send fiber"
end

3.times do |i|
  puts channel.receive
end
```

Output:

```text
Before send 1
Before send 2
Before send 3
1
2
3
```

Note that "End of send fiber" does not appear in the output because we receive the 3 send calls which means `3.times` runs to completion and in turn unblocks the main fiber which executes to completion.
Here's the same snippet as the one we just saw - with the addition of a `Fiber.yield` call at the very bottom:

```crystal
# A buffered channel of capacity 1
channel = Channel(Int32).new(1)

spawn do
  puts "Before send 1"
  channel.send(1)
  puts "Before send 2"
  channel.send(2)
  puts "Before send 3"
  channel.send(3)
  puts "End of send fiber"
end

3.times do |i|
  puts channel.receive
end

Fiber.yield
```

Output:

```text
Before send 1
Before send 2
Before send 3
1
2
3
End of send fiber
```

With the addition of a `Fiber.yield` call at the end of the snippet we see the "End of send fiber" message in the output which would have otherwise been missed due to the main fiber executing to completion.

# Parallelism

Parallelism is the ability to run multiple fibers simultaneously.
In Crystal, a program is concurrent by default, hence runs multiple fibers sequentially, one at a time. Parallelism is opt‑in and manually enabled by resizing the default execution context or starting additional contexts.
This guide assumes you are already familiar with the concurrency model of Crystal.

## Execution contexts

There are different ways to spread an application to leverage many CPU cores.

*   Sometimes we need a fiber to own a thread, notably GUI and game loops.
*   Sometimes we need a set of fibers to run concurrently.
*   Sometimes we need fibers to autoscale to as many CPU cores as possible.

Execution Contexts define how to orchestrate fibers across one or many threads. Ultimately, we plan to make the interface public, so you may write your own models.
Execution contexts are the runtime's building block for orchestrating how a set of fibers will run through a common interface. Contexts run in parallel of each other, and each context has its own rules to run fibers.
The overall interface is merely:

*   Start context(s);
*   Spawn fibers inside a specific context (`context.spawn`), or into the current context (`spawn`);

There are three built‑in execution context types: concurrent, parallel, and isolated.

### Concurrent

Fibers spawned into a concurrent context run concurrently to each other, and will never run in parallel. Keep in mind that they will run in parallel with fibers running in other contexts!
A fiber doing CPU heavy computation in a concurrent context will block other fibers in the same context from progressing, but doesn't impact fibers in other contexts.

Example:

```crystal
ctx = Fiber::ExecutionContext::Concurrent.new("SINGLE")
ctx.spawn { puts "fiber 1" }
ctx.spawn { puts "fiber 2" }
```

Everything stated in the Concurrency guide is true inside a concurrent context due to fibers only running sequentially.

### Parallel

Fibers spawned in a parallel context run both concurrently and in parallel with each other (if parallelism is greater than 1), in addition to fibers running in other contexts.
Parallel contexts auto-scale up to their maximum parallelism. The execution will remain sequential until there are blocked fibers, which will start more schedulers (parallelism increases) until they have nothing left to do (parallelism decreases).
A fiber doing CPU heavy computation in a parallel context won't block other fibers in the context from progressing.
That said, many simultaneously blocking fibers can reach the maximum parallelism of the context, and will start blocking other fibers from progressing! We recommend not creating more blocking fibers than necessary, to use counting semaphores, and to keep some room for other fibers that still need to run in the context, or start more contexts.

Example:

```crystal
ctx = Fiber::ExecutionContext::Parallel.new("MULTI", maximum: 4)
ctx.spawn { puts "fiber 1" }
ctx.spawn { puts "fiber 2" }
```

You can notice that the interface is almost identical to Concurrent. The only difference is that the `SINGLE` context will have one scheduler that can run one fiber at a time (parallelism of 1), while `MULTI` will have up to four schedulers, and is capable to run four fibers at the same time (parallelism of 4).
Everything stated in the Concurrency guide is true inside a parallel context, with slight differences in the actual runtime due to fibers running in parallel to each other.

### Isolated

An isolated context spawns a single fiber to a thread. The fiber owns the thread for its whole lifetime — the thread may be reused after the fiber terminates. The fiber can block the thread however it wants (it owns it) with no impact on your application. The OS will preempt the thread as needed.

Example:

```crystal
ctx = Fiber::ExecutionContext::Isolated.new("GUI") do
  GUI.blocking_main_loop
end
ctx.wait
```

An isolated context can't spawn more fibers inside the context (by design), but the fiber can still spawn more fibers into other contexts. Since it can be complex and cumbersome to retain a reference to a specific context, fibers will be spawned into the default context or a "spawn context" defined at creation:

```crystal
workers = Fiber::ExecutionContext::Concurrent.new("workers")

main = Fiber::ExecutionContext::Isolated.new("GUI", spawn_context: workers) do
  spawn { puts "running in workers context" }
end

main.wait
```

### Default

All programs run in the default context, which is a parallel context with a default parallelism of 1 so it behaves like a concurrent context until programs opt-in to multithreading at runtime.

Example:

```crystal
Fiber::ExecutionContext.default.resize(4)
```

Instead of hardcoding 4 you may use a CLI argument such as `--threads 4` or default to how many logical CPU the current system has (`System.cpu_count`).
Once resized to a parallelism greater than 1, the default context will no longer behave like a concurrent, but be a truly parallel context. Parallelism won't increase immediately, but will start increasing and decreasing as needed.
Resizing the default context is optional. You may prefer to keep it concurrent and instead start additional contexts.

## Relationship with system threads

The term "parallelism" doesn't refer to how many system threads have been started and are currently running, or waiting. The term refers to the maximum number of fibers that can run Crystal code in parallel. Said differently, there can only be up to *parallelism* schedulers running, but there can be more threads.
For example, one thread can be waiting on a blocking system call while the scheduler continues to run in another thread. Parallelism is still one because only one fiber is running Crystal code, though there are two system threads.
When the thread waiting on the system call returns, or when an isolated context terminates, the thread doesn't exit immediately, but enters the thread pool and suspends itself for a few minutes, after which it will finally exit. During that time window, the thread may be picked by any execution context to resume a concurrent or parallel scheduler or to start an isolated context.

> NOTE: The isolated context owns its system thread for its lifetime only. The thread may have been taken from the thread pool and will return to it when the context terminates.

These behaviors mean thread locals must be avoided. We cannot recommend enough to never use the `@[ThreadLocal]` annotation (stdlib barely does), and to be very careful when integrating with an external C library, where you may consider to start an isolated context or to back up and restore the thread local state around lib calls.

## Thread safety issues

Ideally an application would use communication only (e.g. Channel) but sometimes an application needs global and shared data. The problem is that accessing, replacing and mutating shared data will corrupt this data in a parallel environment.

### Shared variables

When we think of shared variables to be protected, we mostly think of globals as detailed in the next sections, but a simple local variable may be accessed from multiple fibers, making it a shared variable. For example:

```crystal
foo = 1

5.times do
  spawn { p foo }
end
```

The above example is safe because the `foo` variable is first initialized, then fibers are spawned that only read its value, and the variable is never replaced nor its value is mutated. The following example, however, will eventually corrupt the variable's value, because multiple fibers mutate the array, possibly in parallel:

```crystal
foo = [] of Int32

5.times do
  spawn(name: "consumer") do
    loop { p foo.pop? }
  end

  spawn(name: "producer") do
    loop { foo.push(rand(Int32)) }
  end
end
```

Since the `foo` variable is shared, its accesses must be protected.
You can start a concurrent context and spawn the fibers there, so the fibers will never run in parallel, but you must ensure that there isn't another fiber that can mutate the array from another context.
You can't parallelize the execution, though, which is likely fine for I/O bound fibers, but CPU bound fibers would benefit from parallelism. In that case you may protect the variable with a `Sync::Exclusive(T)` object. I'm using an exclusive lock rather than a shared lock because we only mutate the array (i.e. only writes), but if the usage was more towards regular reads and seldom writes, then a `Sync::Shared(T)` would be a much more efficient choice.

```crystal
foo = [] of Int32

5.times do
  spawn(name: "consumer") do
    loop do
      value = foo.lock &.pop?
      p value
    end
  end

  spawn(name: "producer") do
    loop do
      value = rand(Int32)
      foo.lock &.push(value)
    end
  end
end
```

That being said, the proper solution for a multiple producers and consumers problem, is to just use a Channel instead:

```crystal
channel = Channel(Int32).new(16)

5.times do
  spawn(name: "consumer") do
    loop do
      p channel.receive
    end
  end

  spawn(name: "producer") do
    loop do
      channel.send rand(Int32)
    end
  end
end
```

### Constants

Constants are always safely initialized once. You don't have to protect their initialization. Crystal takes care of that.
Constants can't be replaced after initialization (unique value), but the value itself can be mutable, for example an Array or a Hash.
A constant value must either be read-only after its initialization, or be protected by a `Sync` object, for example `Sync::Mutex` or `Sync::RWLock`.

### Class variables

Class variables are always safely initialized once. You don't have to protect their initialization. Crystal takes care of that.
Unlike constants, class variables can be replaced by another value at runtime, and the value itself may be mutable, for example be an Array or a Hash.
A class variable must either be read-only after its initialization, or be protected by a `Sync` object, for example `Sync::Exclusive(T)` or `Sync::Shared(T)`.
If a class variable is larger than a register (e.g. Int128), a mixed union (e.g. `Int32 | Int64 | Nil`) or is a struct with more than one property (or a property larger than a register), then writing to the class variable must be protected, otherwise different threads may read incomplete, and thus invalid values. For example:

```crystal
module Foo
  @@bar = Sync::Shared(Int128).new(Int128::MIN)

  spawn { loop { @@bar.set(rand(Int128)) } }
  spawn { loop { puts @@bar.get } }
end
```

# class Fiber

**Inherits:** `Reference` < `Object`

## Overview

A `Fiber` is a light-weight execution unit managed by the Crystal runtime. It is conceptually similar to an operating system thread but with less overhead and completely internal to the Crystal process. The runtime includes a scheduler which schedules execution of fibers.
A Fiber has a stack size of 8 MiB which is usually also assigned to an operating system thread. But only 4KiB are actually allocated at first so the memory footprint is very small.
Communication between fibers is usually passed through `Channel`.

### Cooperative

Fibers are cooperative. That means execution can only be drawn from a fiber when it offers it. It can't be interrupted in its execution at random.
In order to make concurrency work, fibers must make sure to occasionally provide hooks for the scheduler to swap in other fibers. IO operations like reading from a file descriptor are natural implementations for this and the developer does not need to take further action on that. When IO access can't be served immediately by a buffer, the fiber will automatically wait and yield execution. When IO is ready it's going to be resumed through the event loop.
When a computation-intensive task has none or only rare IO operations, a fiber should explicitly offer to yield execution from time to time using `Fiber.yield` to break up tight loops. The frequency of this call depends on the application and concurrency model.

### Event loop

The event loop is responsible for keeping track of sleeping fibers waiting for notifications that IO is ready or a timeout reached. When a fiber can be woken, the event loop enqueues it in the scheduler.

## Constructors

### `.current : Fiber`
Returns the current fiber.

### `.new(name : String | Nil = nil, execution_context : ExecutionContext = ExecutionContext.current, &proc : -> ) : self`
Creates a new Fiber instance. When the fiber is executed, it runs `proc` in its context. `name` is an optional and used only as an internal reference.

## Class Methods

### `.suspend : Nil`
Suspends execution of the current fiber indefinitely. Unlike `Fiber.yield` the current fiber is not automatically reenqueued and can only be resumed with an explicit call to `#enqueue`. This is equivalent to sleep without a time. This method is meant to be used in concurrency primitives. It's particularly useful if the fiber needs to wait for something to happen (for example an IO event, a message is ready in a channel, etc.) which triggers a re-enqueue.

### `.yield : Nil`
Yields to the scheduler and allows it to swap execution to other waiting fibers. This is equivalent to `sleep 0.seconds`. It gives the scheduler an option to interrupt the current fiber's execution. If no other fibers are ready to be resumed, it immediately resumes the current fiber. This method is particularly useful to break up tight loops which are only computation intensive and don't offer natural opportunities for swapping fibers as with IO operations.

```crystal
counter = 0
spawn name: "status" do
  loop do
    puts "Status: #{counter}"
    sleep(2.seconds)
  end
end

while counter < Int32::MAX
  counter += 1
  if counter % 1_000_000 == 0
    # Without this, there would never be an opportunity to resume the status fiber
    Fiber.yield
  end
end
```

## Instance Methods

### `#dead? : Bool`
The fiber's proc has terminated, and the fiber is now considered dead. The fiber is impossible to resume, ever.

### `#enqueue : Nil`
Adds this fiber to the scheduler's runnables queue for the current thread. This signals to the scheduler that the fiber is eligible for being resumed the next time it has the opportunity to reschedule to another fiber. There are no guarantees when that will happen.

### `#execution_context : ExecutionContext`
Returns the execution context this fiber belongs to.

### `#execution_context=(execution_context : ExecutionContext)`
Sets the execution context.

### `#execution_context? : ExecutionContext | Nil`
Returns the execution context or nil if not set.

### `#inspect(io : IO) : Nil`
Appends a String representation of this object which includes its class name, its object address and the values of all instance variables.

### `#name : String | Nil`
### `#name=(name : String | Nil)`
The name of the fiber, used as internal reference.

### `#resumable? : Bool`
The fiber's proc is currently not running and fully saved its context. The fiber can be resumed safely.

### `#resume : Nil`
Immediately resumes execution of this fiber. There are no provisions for resuming the current fiber (where this method is called). Unless it is explicitly added for rescheduling (for example using `#enqueue`) the current fiber won't ever reach any instructions after the call to this method.

```crystal
fiber = Fiber.new do
  puts "in fiber"
end
fiber.resume
puts "never reached"
```

### `#running? : Bool`
The fiber's proc is currently running or didn't fully save its context. The fiber can't be resumed.

### `#to_s(io : IO) : Nil`
Appends a short String representation of this object which includes its class name and its object address.

# module Fiber::ExecutionContext

## Overview

An execution context creates and manages a dedicated pool of one or more schedulers where fibers will be running in. Each context manages the rules to run, suspend and swap fibers internally.
An execution context groups fibers together. Instead of associating a fiber to a specific system thread, we associate a fiber to an execution context, abstracting which system thread(s) the fibers will run on.
Applications can create any number of execution contexts in parallel. Fibers running in any context can communicate and synchronize with any other fiber running in any context through the usual synchronization primitives such as `Channel`, `WaitGroup` or `Sync`.
When spawning a fiber with `::spawn`, it spawns into the execution context of the current fiber, so child fibers execute in the same context as their parent, unless told otherwise (see `ExecutionContext#spawn`).
Fibers are scoped to the execution context they are spawned into. Once spawned, a fiber cannot move to another execution context, and is always resumed in the same execution context.

### Context types

The standard library provides a number of execution context implementations for common use cases.

*   **`ExecutionContext::Concurrent`:** Fully concurrent with limited parallelism. Fibers run concurrently to each other, never in parallel (only one fiber at a time).
*   **`ExecutionContext::Parallel`:** Fully concurrent, fully parallel. Fibers running in this context can be resumed by multiple system threads in this context.
*   **`ExecutionContext::Isolated`:** Single fiber in a single system thread without concurrency. Useful for tasks that can block thread execution for a long time (e.g., CPU heavy computation) or must be reactive (e.g., a GUI or game loop).

### The default execution context

The Crystal runtime starts a default execution context exposed as `Fiber::ExecutionContext.default`. This is where the main fiber is running. Its parallelism is set to 1 for backwards compatibility reasons. You can increase the parallelism at any time using `Parallel#resize`.

```crystal
count = Fiber::ExecutionContext.default_workers_count
Fiber::ExecutionContext.default.resize(count)
```

### Relationship with system threads

Execution contexts control when and how fibers run, and on which system thread they execute. The term *parallelism* is the maximum number of fibers that can run in parallel (maximum number of schedulers) but there can be less or more system threads running in practice, for example when a fiber is blocked on a syscall.

## Constructors

### `.current : ExecutionContext`
Returns the `ExecutionContext` the current fiber is running in.

## Class Methods

### `.current? : ExecutionContext | Nil`
Returns the current execution context or nil.

### `.default : ExecutionContext::Parallel`
Returns the default `ExecutionContext` for the process, automatically started when the program started. The parallelism can be changed using `Parallel#resize`.

### `.default_workers_count : Int32`
Returns the default maximum parallelism. Respects the `CRYSTAL_WORKERS` environment variable if present and valid, and otherwise defaults to the number of logical CPUs available to the process or on the computer.

### `.each(&) : Nil`
Iterates all execution contexts.

### `.thread_keepalive : Time::Span`
### `.thread_keepalive=(thread_keepalive : Time::Span)`
How long a parked thread will be kept waiting in the thread pool. Defaults to 5 minutes.

## Instance Methods

### `#spawn(*, name : String | Nil = nil, &block : -> ) : Fiber`
Creates a new fiber then enqueues it to the execution context. May be called from any `ExecutionContext` (i.e. must be thread-safe).

# class Fiber::ExecutionContext::Concurrent

**Inherits:** `Fiber::ExecutionContext::Parallel` < `Reference` < `Object`

## Overview

Concurrent-only execution context. Fibers running in the same context can only run concurrently and never in parallel to each other. However, they still run in parallel to fibers running in other execution contexts.
A blocking fiber blocks the entire context, and thus all the other fibers in the context.

```crystal
require "wait_group"

consumers = Fiber::ExecutionContext::Concurrent.new("consumers")
channel = Channel(Int32).new(64)
wg = WaitGroup.new(32)

result = 0
32.times do
  consumers.spawn do
    while value = channel.receive?
      # safe, but only for this example:
      result = result + value
    end
  ensure
    wg.done
  end
end

1024.times { |i| channel.send(i) }
channel.close

# wait for all workers to be done
wg.wait

p result # => 523776
```

## Constructors

### `.new(name : String) : self`
Creates a Concurrent context. The context will only really start when a fiber is spawned into it.

## Instance Methods

### `#resize(maximum : Int32) : Nil`
Always raises an `ArgumentError` exception because a concurrent context cannot be resized.

# class Fiber::ExecutionContext::Isolated

**Inherits:** `Reference` < `Object`

## Overview

Isolated execution context to run a single fiber. Concurrency and parallelism are disabled. The context guarantees that the fiber will always run on the same system thread until it terminates; the fiber owns the system thread for its whole lifetime.

```crystal
gtk = Fiber::ExecutionContext::Isolated.new("Gtk") do
  Gtk.main
end
gtk.wait
```

## Constructors

### `.new(name : String, spawn_context : ExecutionContext = ExecutionContext.default, &func : -> )`
Starts a new thread named `name` to execute `func`. Once `func` returns the thread will terminate.

## Instance Methods

### `#inspect(io : IO) : Nil`
### `#name : String`
### `#running? : Bool`

### `#spawn(*, name : String | Nil = nil, &block : -> ) : Fiber`
Instantiates a fiber and enqueues it into the scheduler's local queue.

### `#status : String`
Returns the current status of the scheduler. For example "running", "event-loop" or "parked".

### `#to_s(io : IO) : Nil`

### `#wait : Nil`
Blocks the calling fiber until the isolated context fiber terminates. Returns immediately if the isolated fiber has already terminated. Re-raises unhandled exceptions raised by the fiber.

```crystal
ctx = Fiber::ExecutionContext::Isolated.new("test") do
  raise "fail"
end
ctx.wait # => re-raises "fail"
```

# class Fiber::ExecutionContext::Parallel

**Inherits:** `Reference` < `Object`

## Overview

Parallel execution context. Fibers running in the same context run both concurrently and in parallel to each other. 
The context internally keeps a number of fiber schedulers, each scheduler runs on a system thread, so multiple schedulers can run in parallel. The actual parallelism is dynamic.

```crystal
require "wait_group"

consumers = Fiber::ExecutionContext::Parallel.new("consumers", 8)
channel = Channel(Int32).new(64)
wg = WaitGroup.new(32)

result = Atomic.new(0)
32.times do
  consumers.spawn do
    while value = channel.receive?
      result.add(value)
    end
  ensure
    wg.done
  end
end

1024.times { |i| channel.send(i) }
channel.close

# wait for all workers to be done
wg.wait

p result.get # => 523776
```

## Constructors

### `.new(name : String, maximum : Int32) : self`
Starts a Parallel context with a maximum parallelism. The context starts with an initial parallelism of zero.

### `.new(name : String, size : Range(Nil, Int32)) : self` (DEPRECATED)
### `.new(name : String, size : Range(Int32, Int32)) : self` (DEPRECATED)
Use `Fiber::ExecutionContext::Parallel.new(String, Int32)` instead.

## Instance Methods

### `#capacity : Int32`
The maximum number of schedulers that can be started, aka how many fibers can run in parallel or maximum parallelism of the context.

### `#inspect(io : IO) : Nil`
### `#name : String`

### `#resize(maximum : Int32) : Nil`
Resizes the context to the new maximum parallelism. The new maximum can grow or shrink as needed.

### `#to_s(io : IO) : Nil`

# class Fiber::ExecutionContext::Parallel::Scheduler

**Inherits:** `Reference` < `Object`

## Overview

Individual scheduler for the parallel execution context. The execution context itself doesn't run the fibers. The fibers actually run in the schedulers. Each scheduler in the context increases the parallelism by one.

## Instance Methods

### `#inspect(io : IO) : Nil`
### `#name : String`
### `#status : String`
Returns the current status of the scheduler.
### `#to_s(io : IO) : Nil`

# class Channel(T)

**Inherits:** `Reference` < `Object`  
**Includes:** `Iterator(T)`

## Overview

A `Channel` enables concurrent communication between fibers.

They allow communicating data between fibers without sharing memory and without having to worry about locks, semaphores, or other special structures.

```crystal
channel = Channel(Int32).new

spawn do
  channel.send(0)
  channel.send(1)
end

channel.receive # => 0
channel.receive # => 1
```

> **NOTE:** Although a `Channel(Nil)` or any other nilable types like `Channel(Int32?)` are valid, they are discouraged since receiving a `nil` as data from certain methods or constructs will be indistinguishable from a closed channel.

## Constructors

### `.new(capacity : Int32 = 0)`
Creates a new channel. If `capacity` is 0, the channel is unbuffered. If `capacity` is greater than 0, the channel acts as a buffered channel with the specified capacity.

## Class Methods

### `.receive_first(channels : Enumerable(Channel))`
### `.receive_first(*channels)`
Receives the first available value from any of the provided channels.

### `.send_first(value, channels : Enumerable(Channel)) : Nil`
### `.send_first(value, *channels) : Nil`
Sends the value to the first available channel among the provided channels.

## Instance Methods

### `#close : Bool`
Closes the channel. The method prevents any new value from being sent to the channel.

If the channel has buffered values, then subsequent calls to `#receive` will succeed and consume the buffer until it is empty.

All fibers blocked in `#send` or `#receive` will be awakened with `Channel::ClosedError`. All subsequent calls to `#send` will consider the channel closed. Subsequent calls to `#receive` will consider the channel closed if the buffer is empty.

Calling `#close` on a closed channel does not have any effect.

**Returns:** `true` when the channel was successfully closed, or `false` if it was already closed.

### `#closed? : Bool`
Returns `true` if the channel is closed, `false` otherwise.

### `#inspect(io : IO) : Nil`
Appends a String representation of this object which includes its class name, its object address, and the values of all instance variables.

### `#next : T | Stop`
Returns the next element in this iterator, or `Iterator::Stop::INSTANCE` if there are no more elements.

### `#pretty_print(pp)`
Pretty prints the channel for debugging purposes.

### `#receive : T`
Receives a value from the channel. If there is a value waiting, then it is returned immediately. Otherwise, this method blocks until a value is sent to the channel.

Raises `ClosedError` if the channel is closed or closes while waiting for receive.

```crystal
channel = Channel(Int32).new
spawn do
  channel.send(1)
end
channel.receive # => 1
```

### `#receive? : T | Nil`
Receives a value from the channel. If there is a value waiting, it is returned immediately. Otherwise, this method blocks until a value is sent to the channel.

Returns `nil` if the channel is closed or closes while waiting for receive.

### `#send(value : T) : self`
Sends a value to the channel. If the channel has spare capacity, then the method returns immediately. Otherwise, this method blocks the calling fiber until another fiber calls `#receive` on the channel.

Raises `ClosedError` if the channel is closed or closes while waiting on a full channel.

# class Channel::ClosedError

**Inherits:** `Exception` < `Reference` < `Object`

## Overview
Exception raised when attempting to operate on a closed channel, such as sending to a closed channel or receiving from an empty, closed channel.

## Constructors

### `.new(msg = "Channel is closed")`
Creates a new `ClosedError` exception with an optional custom message.

# module Sync

## Overview

Synchronization primitives to build concurrent-safe and parallel-safe data structures, so we can embrace concurrency and parallelism with more serenity.
Communication through a Channel should be preferred whenever possible, but sometimes we need to protect critical sections manually, for example to build higher level constructs, or to protect a mutable global constant:

* `Sync::Mutex` to protect critical sections using mutual exclusion.
* `Sync::RWLock` to protect critical sections using shared access and mutual exclusion.
* `Sync::ConditionVariable` to synchronize critical sections together.
* `Sync::Exclusive(T)` to protect a value `T` using mutual exclusion.
* `Sync::Shared(T)` to protect a value `T` using a mix of shared access and mutual exclusion.

# class Sync::ConditionVariable

**Inherits:** `Reference` < `Object`

## Overview

Suspend a fiber until notified.
A `ConditionVariable` can be associated to any `Lockable`.
While one `Lockable` can be associated to multiple `ConditionVariable`s, one `ConditionVariable` can only be associated to a single `Lockable` (one-to-many relation).
Condition variables may only be preferred over `WaitGroup` or `Channel(T)` for specific scenarios that need to wake a single fiber (signal) or all waiting fibers (broadcast). For example:

* Prefer `Channel(T)` to pass a local resource around over a `Mutex` and `ConditionVariable` to protect a global resource, but sometimes you don't need to pass a value and only need to repeatedly signal one or multiple workers, in which case a condition variable might be useful.
* Prefer `WaitGroup(T)` if you need to wait for a task to complete, or for a set of workers to be ready (specific lifetimes), but sometimes you want to repeatedly or sporadically notify one or many workers that may be added or removed concurrently (unbounded lifetimes), in which case a condition variable might be useful.

## Constructors

### `.new(lock : Lockable)`

## Instance Methods

### `#broadcast : Nil`
Wakes up all waiting fibers at once.
You can wake a single waiting fiber with `#signal`.

### `#signal : Nil`
Wakes up one waiting fiber.
For `RWLock` and `Shared(T)` all readers can acquire, thus multiple readers might be woken at once, but only one writer can acquire, thus only one reader will be woken at a time.
You can wake all waiting fibers with `#broadcast`.

### `#wait : Nil`
Blocks the calling fiber until the condition variable is signaled.
The lock must be held upon calling. Releases lock before waiting, so any other fiber can acquire the lock while the calling fiber is waiting. The lock is re-acquired before returning.
A `RWLock` and `Shared(T)` can be held in either read or write mode, the lock will be reacquired in the same mode (read or write) before returning.
The calling fiber will be woken by `#signal` or `#broadcast`.

# class Sync::Error

**Inherits:** `Exception` < `Reference` < `Object`

## Overview

Raised when a sync check fails. For example when trying to unlock an unlocked mutex. See `#message` for details.

# class Sync::Error::Deadlock

**Inherits:** `Sync::Error` < `Exception` < `Reference` < `Object`

## Overview

Raised when a lock would result in a deadlock. For example when trying to re-lock a checked mutex.

# class Sync::Exclusive(T)

**Inherits:** `Reference` < `Object`  
**Includes:** `Sync::Lockable`

## Overview

Safely share a value `T` across fibers and execution contexts using a `Mutex`, so only one critical section can access the value at any time.

For example:

```crystal
require "sync/exclusive"

class Queue
  @@running : Sync::Exclusive.new([] of Queue)

  def self.on_started(queue)
    @@running.lock(&.push(queue))
  end

  def self.on_stopped(queue)
    @@running.lock(&.delete(queue))
  end

  def self.each(&)
    @@running.lock do |list|
      list.each { |queue| yield queue }
    end
  end
end
```

Consider an `Exclusive(T)` if your workload mostly needs to own the value, and most, if not all, critical sections need to mutate the inner state of the value for example.

## Constructors

### `.new(value : T, type : Type = :checked)`

## Instance Methods

### `#get : T`
Locks the mutex and returns the value. Unlocks before returning.
Always acquires the lock, so reading the value is synchronized in relation with the other methods. However, safely accessing the returned value entirely depends on the safety of `T`.
Prefer `#lock(&.dup)` or `#lock(&.clone)` to get a shallow or deep copy of the value instead.

> **WARNING:** Breaks the mutual exclusion guarantee since the returned value outlives the lock, the value can be accessed concurrently to the synchronized methods.

### `#lock(& : T -> _) : _`
Locks the mutex and yields the value. The lock is released before returning.
The value is owned for the duration of the block, and can be safely mutated.

> **WARNING:** The value mustn't be retained and accessed after the block has returned.

### `#replace(& : T -> T) : Nil`
Locks the mutex, yields the value and eventually replaces the value with the one returned by the block. The lock is released before returning.
The current value is now owned: it can be safely retained and mutated even after the block returned.

> **WARNING:** The new value mustn't be retained and accessed after the block has returned.

### `#set(value : T) : Nil`
Locks the mutex and sets the value. Unlocks the mutex before returning.
Always acquires and releases the lock, so writing the value is always synchronized with the other methods.

### `#unsafe_get : T`
Returns the value without any synchronization.

> **WARNING:** Breaks the mutual exclusion constraint! Should only be called after acquiring the lock.

### `#unsafe_set(value : T) : T`
Sets the value without any synchronization.

> **WARNING:** Breaks the mutual exclusion constraint! Should only be called after acquiring the lock.

# module Sync::Lockable

## Overview

General type to abstract lockable types such as `Sync::Mutex` and `Sync::RWLock` to be used interchangeably by other types, for example `Sync::ConditionVariable`.

# class Sync::Mutex

**Inherits:** `Reference` < `Object`  
**Includes:** `Sync::Lockable`

## Overview

A mutual exclusion lock to protect critical sections.
A single fiber can acquire the lock at a time. No other fiber can acquire the lock while a fiber holds it.
This lock can for example be used to protect the access to some resources, with the guarantee that only one section of code can ever read, write or mutate said resources.

> **NOTE:** Consider `Exclusive(T)` to protect a value `T` with a `Mutex`.

## Constructors

### `.new(type : Type = :checked)`

## Instance Methods

### `#lock : Nil`
Acquires the exclusive lock.

### `#synchronize(& : -> _) : _`
Acquires the exclusive lock for the duration of the block. The lock will be released automatically before returning, or if the block raises an exception.

### `#unlock : Nil`
Releases the exclusive lock.

# class Sync::RWLock

**Inherits:** `Reference` < `Object`  
**Includes:** `Sync::Lockable`

## Overview

A multiple readers and exclusive writer lock to protect critical sections.

Multiple fibers can acquire the shared lock (read) to allow some critical sections to run concurrently. However a single fiber can acquire the exclusive lock at a time to protect a single critical section to ever run in parallel. When the lock has been acquired in exclusive mode, no other fiber can lock it, be it in shared or exclusive mode.

For example, the shared mode can allow to read one or many resources, albeit the resources must be safe to be accessed in such manner, while the exclusive mode allows to safely replace or mutate the resources with the guarantee that nothing else is accessing said resources.

The implementation doesn't favor readers or writers in particular.

> **NOTE:** Consider `Shared(T)` to protect a value `T` with a `RWLock`.

## Constructors

### `.new(type : Type = :checked)`

## Instance Methods

### `#lock_read : Nil`
Acquires the shared (read) lock.

Multiple fibers can acquire the shared (read) lock at the same time. Blocks the calling fiber if the exclusive (write) lock is held.

> **WARNING:** the shared lock is technically reentrant but any attempt to relock read can result in a deadlock if another fiber is trying to lock write!

### `#lock_write : Nil`
Acquires the exclusive (write) lock. Blocks the calling fiber while the shared or exclusive (write) lock is held.

### `#read(& : -> _) : _`
Acquires the shared (read) lock for the duration of the block.

Multiple fibers can acquire the shared (read) lock at the same time. The block will never run concurrently to an exclusive (write) lock.

> **WARNING:** the shared lock is technically reentrant but any attempt to relock read can result in a deadlock if another fiber is trying to lock write!

### `#try_lock_read? : Bool`
Tries to acquire the shared (read) lock without blocking. Returns true when acquired, otherwise returns false immediately.

### `#try_lock_write? : Bool`
Tries to acquire the exclusive (write) lock without blocking. Returns true when acquired, otherwise returns false immediately.

### `#unlock_read : Nil`
Releases the shared (read) lock.

Every fiber that locked must unlock to actually release the reader lock (so a writer can lock). If a fiber locked multiple times (reentrant behavior) then it must unlock that many times.

### `#unlock_write : Nil`
Releases the exclusive (write) lock.

### `#write(& : -> _) : _`
Acquires the exclusive (write) lock for the duration of the block.

Only one fiber can acquire the exclusive (write) lock at the same time. The block will never run concurrently to a shared (read) lock or another exclusive (write) lock.

# class Sync::Shared(T)

**Inherits:** `Reference` < `Object`  
**Includes:** `Sync::Lockable`

## Overview

Safely share a value `T` across fibers and execution contexts using a `RWLock` to control when the access to a value can be shared (read-only) or must be exclusive (replace or mutate the value).

For example:

```crystal
require "sync/shared"

class Queue
  @@running : Sync::Shared.new([] of Queue)

  def self.on_started(queue)
    @@running.lock(&.push(queue))
  end

  def self.on_stopped(queue)
    @@running.lock(&.delete(queue))
  end

  def self.each(&)
    @@running.shared do |list|
      list.each { |queue| yield queue }
    end
  end
end
```

Consider a `Shared(T)` if your workload mostly consists of immutable reads of the value, with only seldom writes or inner mutations of the value's inner state.

## Constructors

### `.new(value : T, type : Type = :checked)`

## Instance Methods

### `#get : T`
Locks in shared mode and returns the value. Unlocks before returning.
Always acquires the lock, so reading the value is synchronized in relation with the other methods. However, safely accessing the returned value entirely depends on the safety of `T`.
Prefer `#shared(&.dup)` or `#shared(&.clone)` to get a shallow or deep copy of the value instead.

> **WARNING:** Breaks the shared/exclusive guarantees since the returned value outlives the lock, the value can be accessed concurrently to the synchronized methods.

### `#lock(& : T -> _) : _`
Locks in exclusive mode and yields the value. The lock is released before returning.
The value is owned in exclusive mode for the duration of the block, as such it can be safely mutated.

> **WARNING:** The value mustn't be retained and accessed after the block has returned.

### `#replace(& : T -> T) : Nil`
Locks in exclusive mode, yields the current value and eventually replaces the value with the one returned by the block. The lock is released before returning.
The current value is now owned: it can be safely retained and mutated even after the block returned.

> **WARNING:** The new value mustn't be retained and accessed after the block has returned.

### `#set(value : T) : Nil`
Locks in exclusive mode and sets the value.

### `#shared(& : T -> _) : _`
Locks in shared mode and yields the value. The lock is released before returning.
The value is owned in shared mode for the duration of the block, and thus shouldn't be mutated for example, unless `T` can be safely mutated (it should be `Sync::Safe`).

> **WARNING:** The value mustn't be retained and accessed after the block has returned.

### `#unsafe_get : T`
Returns the value without any synchronization.

> **WARNING:** Breaks the safety constraints! Should only be called after acquiring the exclusive lock.

### `#unsafe_set(value : T) : T`
Sets the value without any synchronization.

> **WARNING:** Breaks the safety constraints! Should only be called after acquiring the exclusive lock.

# enum Sync::Type

**Inherits:** `Enum` < `Value` < `Object`

## Enum Members

* **`Unchecked = 0`**
  The lock doesn't do any checks. Trying to relock will cause a deadlock, unlocking from any fiber is undefined behavior.

* **`Checked = 1`**
  The lock checks whether the current fiber owns the lock. Trying to relock will raise a `Error::Deadlock` exception, unlocking when unlocked or while another fiber holds the lock will raise an `Error`.

* **`Reentrant = 2`**
  Same as `Checked` with the difference that the lock allows the same fiber to re-lock as many times as needed, then must be unlocked as many times as it was re-locked.

## Instance Methods

### `#checked? : Bool`
Returns true if this enum value equals `Checked`.

### `#reentrant? : Bool`
Returns true if this enum value equals `Reentrant`.

### `#unchecked? : Bool`
Returns true if this enum value equals `Unchecked`.