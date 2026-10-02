# module Levenshtein

## Overview

Levenshtein distance methods.

> **NOTE:** To use Levenshtein, you must explicitly import it with `require "levenshtein"`

**Defined in:** `levenshtein.cr`

## Class Method Summary

* **`.distance(string1 : String, string2 : String) : Int32`**
Computes the levenshtein distance of two strings.

* **`.find(name, tolerance = nil, &) : String | Nil`**
Finds the best match for `name` among strings added within the given block.

* **`.find(name, all_names, tolerance = nil) : String | Nil`**
Finds the best match for `name` among strings provided in `all_names`.

---

## Class Method Detail

### `def self.distance(string1 : String, string2 : String) : Int32`

Computes the levenshtein distance of two strings.

```crystal
require "levenshtein"

Levenshtein.distance("algorithm", "altruistic") # => 6
Levenshtein.distance("hello", "hallo")          # => 1
Levenshtein.distance("こんにちは", "こんちは")           # => 1
Levenshtein.distance("hey", "hey")              # => 0

```

### `def self.find(name, tolerance = nil, &) : String | Nil`

Finds the best match for `name` among strings added within the given block. `tolerance` can be used to set maximum Levenshtein distance allowed.

```crystal
require "levenshtein"

best_match = Levenshtein.find("hello") do |l|
  l.test "hulk"
  l.test "holk"
  l.test "halka"
  l.test "ello"
end
best_match # => "ello"

```

### `def self.find(name, all_names, tolerance = nil) : String | Nil`

Finds the best match for `name` among strings provided in `all_names`. `tolerance` can be used to set maximum Levenshtein distance allowed.

```crystal
require "levenshtein"

Levenshtein.find("hello", ["hullo", "hel", "hall", "hell"], 2) # => "hullo"
Levenshtein.find("hello", ["hurlo", "hel", "hall"], 1)         # => nil

```

---

# class Levenshtein::Finder

## Overview

Finds the closest string to a given string amongst many strings.

```crystal
require "levenshtein"

finder = Levenshtein::Finder.new "hallo"
finder.test "hay"
finder.test "hall"
finder.test "hallo world"

finder.best_match # => "hall"

```

**Defined in:** `levenshtein.cr`

## Constructors

* **`.new(target : String, tolerance : Int | Nil = nil)`**

## Class Method Summary

* **`.find(name, tolerance = nil, &)`**
* **`.find(name, all_names, tolerance = nil) : String | Nil`**

## Instance Method Summary

* **`#best_match : String | Nil`**
* **`#test(name : String, value : String = name)`**

## Inherited Methods

* **Instance methods inherited from class `Reference`:** `==`, `dup`, `hash`, `initialize`, `inspect`, `object_id`, `pretty_print`, `same?`, `to_s`
* **Constructor methods inherited from class `Reference`:** `new`, `unsafe_construct`
* **Class methods inherited from class `Reference`:** `pre_initialize`
* **Instance methods inherited from class `Object`:** `!`, `!=`, `!~`, `==`, `===`, `=~`, `as`, `as?`, `class`, `dup`, `hash`, `in?`, `inspect`, `is_a?`, `itself`, `nil?`, `not_nil!`, `pretty_inspect`, `pretty_print`, `responds_to?`, `tap`, `to_json`, `to_pretty_json`, `to_s`, `to_yaml`, `try`, `unsafe_as`
* **Class methods inherited from class `Object`:** `from_json`, `from_yaml`
* **Macros inherited from class `Object`:** `class_getter`, `class_getter!`, `class_getter?`, `class_property`, `class_property!`, `class_property?`, `class_setter`, `def_clone`, `def_equals`, `def_equals_and_hash`, `def_hash`, `delegate`, `forward_missing_to`, `getter`, `getter!`, `getter?`, `property`, `property!`, `property?`, `setter`

---

## Constructor Detail

### `def self.new(target : String, tolerance : Int | Nil = nil)`

## Class Method Detail

### `def self.find(name, tolerance = nil, &)`

### `def self.find(name, all_names, tolerance = nil) : String | Nil`

## Instance Method Detail

### `def best_match : String | Nil`

### `def test(name : String, value : String = name)`