class Array
  include Enumerable

  # The flow control for many of these methods is
  # pretty evil due to how MRI works. There is
  # also a lot of duplication of code due to very
  # subtle processing differences and, in some
  # cases, to avoid mutual dependency. Apologies.


  def self.[](*args)
    ary = allocate
    ary.replace args
    ary
  end

  # Try to convert obj into an array, using to_ary method.
  # Returns converted array or nil if obj cannot be converted
  # for any reason. This method is to check if an argument is an array.
  def self.try_convert(obj)
    Rubinius::Type.try_convert obj, Array, :to_ary
  end

  def initialize(size_or_array=undefined, obj=undefined)
    Rubinius.check_frozen

    if undefined.equal?(size_or_array)
      unless @total == 0
        @total = @start = 0
        @tuple = Rubinius::Tuple.new 8
      end

      return self
    end

    if undefined.equal?(obj)
      obj = nil
      ary = nil
      if size_or_array.kind_of? Integer
        # Do nothing, fall through to later case.
      elsif size_or_array.kind_of? Array
        ary = size_or_array
      elsif Rubinius::Type.object_respond_to_ary?(size_or_array)
        ary = Rubinius::Type.coerce_to size_or_array, Array, :to_ary
      end

      if ary
        @tuple = ary.tuple.dup
        @start = ary.start
        @total = ary.size

        return self
      end
    end

    size = Rubinius::Type.coerce_to size_or_array, Integer, :to_int
    raise ArgumentError, "size must be positive" if size < 0
    raise ArgumentError, "size must be <= #{Fixnum::MAX}" if size > Fixnum::MAX

    if block_given?
      @tuple = Rubinius::Tuple.new size
      @total = i = 0
      while i < size
        @tuple.put i, yield(i)
        @total = i += 1
      end
    else
      @total = size
      @tuple = Rubinius::Tuple.pattern size, obj
    end

    self
  end

  private :initialize

  # Replaces contents of self with contents of other,
  # adjusting size as needed.
  def replace(other)
    Rubinius.check_frozen

    other = Rubinius::Type.coerce_to other, Array, :to_ary

    @tuple = other.tuple.dup
    @total = other.total
    @start = other.start

    Rubinius::Type.infect(self, other)
    self
  end

  alias_method :initialize_copy, :replace
  private :initialize_copy

  def [](arg1, arg2=nil)
    case arg1

    # This is split out from the generic case and put first because
    # it is by far the most common case and we want to deal with it
    # immediately, even at the expensive of duplicate code with the
    # generic case below. In other words, don't refactor this unless
    # you preserve the same or better performance.
    when Fixnum
      start_idx = arg1

      # Convert negative indices
      start_idx += @total if start_idx < 0

      if arg2
        count = Rubinius::Type.coerce_to arg2, Fixnum, :to_int
      else
        return nil if start_idx >= @total

        begin
          return @tuple.at(@start + start_idx)

        # Tuple#at raises this if the index is negative or
        # past the end. This is faster than checking explicitly
        # since this is an exceptional case anyway.
        rescue Rubinius::ObjectBoundsExceededError
          return nil
        end
      end
    when Range
      start_idx = Rubinius::Type.coerce_to arg1.begin, Fixnum, :to_int
      # Convert negative indices
      start_idx += @total if start_idx < 0

      # Check here because we must detect this boundary
      # before we check the right index boundary cases
      return nil if start_idx < 0 or start_idx > @total

      right_idx = Rubinius::Type.coerce_to arg1.end, Fixnum, :to_int
      right_idx += @total if right_idx < 0
      right_idx -= 1 if arg1.exclude_end?

      return new_range(0, 0) if right_idx < start_idx

      count = right_idx - start_idx + 1

    # Slower, less common generic coercion case.
    else
      start_idx = Rubinius::Type.coerce_to arg1, Fixnum, :to_int

      # Convert negative indices
      start_idx += @total if start_idx < 0

      if arg2
        count = Rubinius::Type.coerce_to arg2, Fixnum, :to_int
      else
        return nil if start_idx >= @total

        begin
          return @tuple.at(@start + start_idx)

        # Tuple#at raises this if the index is negative or
        # past the end. This is faster than checking explicitly
        # since this is an exceptional case anyway.
        rescue Rubinius::ObjectBoundsExceededError
          return nil
        end
      end
    end

    # No need to go further
    return nil if count < 0

    # Check start boundaries
    if start_idx >= @total
      # Odd MRI boundary case
      return new_range(0, 0) if start_idx == @total
      return nil
    end

    return nil if start_idx < 0

    # Check count boundaries
    if start_idx + count > @total
      count = @total - start_idx
    end

    # Construct the subrange
    return new_range(@start + start_idx, count)
  end

  alias_method :slice, :[]

  def <<(obj)
    set_index(@total, obj)
    self
  end

  alias_method :__append__, :<<

  def *(multiplier)
    if multiplier.respond_to? :to_str
      return join(multiplier)

    else
      # Aaargh stupid MRI's stupid specific stupid error stupid types stupid
      multiplier = Rubinius::Type.coerce_to multiplier, Fixnum, :to_int

      raise ArgumentError, "Count cannot be negative" if multiplier < 0

      case @total
      when 0
        # Edge case
        out = self.class.allocate
        Rubinius::Type.infect(out, self)
        return out
      when 1
        # Easy case
        tuple = Rubinius::Tuple.pattern multiplier, at(0)
        out = self.class.allocate
        out.tuple = tuple
        out.total = multiplier
        Rubinius::Type.infect(out, self)
        return out
      end

      new_total = multiplier * @total
      new_tuple = Rubinius::Tuple.new(new_total)

      out = self.class.allocate
      out.tuple = new_tuple
      out.total = new_total
      Rubinius::Type.infect(out, self)

      offset = 0
      while offset < new_total
        new_tuple.copy_from @tuple, @start, @total, offset
        offset += @total
      end

      out
    end
  end

  def &(other)
    other = Rubinius::Type.coerce_to other, Array, :to_ary

    array = []
    im = Rubinius::IdentityMap.from other

    each { |x| array << x if im.delete x }

    array
  end

  def |(other)
    other = Rubinius::Type.coerce_to other, Array, :to_ary

    im = Rubinius::IdentityMap.from self, other
    im.to_array
  end

  def +(other)
    other = Rubinius::Type.coerce_to other, Array, :to_ary
    Array.new(self).concat(other)
  end

  def -(other)
    other = Rubinius::Type.coerce_to other, Array, :to_ary

    array = []
    im = Rubinius::IdentityMap.from other

    each { |x| array << x unless im.include? x }

    array
  end

  def <=>(other)
    other = Rubinius::Type.check_convert_type other, Array, :to_ary
    return 0 if equal? other
    return nil if other.nil?

    other_total = other.total
    Thread.detect_recursion self, other do
      i = 0
      total = other_total < @total ? other_total : @total

      while i < total
        diff = self[i] <=> other[i]
        return diff unless diff == 0

        i += 1
      end
    end

    # subtle: if we are recursing on that pair, then let's
    # no go any further down into that pair;
    # any difference will be found elsewhere if need be
    @total <=> other_total
  end

  def ==(other)
    return true if equal?(other)
    unless other.kind_of? Array
      return false unless other.respond_to? :to_ary
      return other == self
    end

    return false unless size == other.size

    Thread.detect_recursion self, other do
      md = @tuple
      od = other.tuple

      i = @start
      j = other.start

      total = i + @total

      while i < total
        return false unless md[i] == od[j]
        i += 1
        j += 1
      end
    end

    true
  end

  def assoc(obj)
    each do |x|
      if x.kind_of? Array and x.first == obj
        return x
      end
    end

    nil
  end

  def at(idx)
    Rubinius.primitive :array_aref
    idx = Rubinius::Type.coerce_to idx, Fixnum, :to_int

    total = @start + @total

    if idx < 0
      idx += total
    else
      idx += @start
    end

    return nil if idx >= total or idx < @start
    return @tuple.at(idx)
  end

  def clear
    Rubinius.check_frozen

    @tuple = Rubinius::Tuple.new(1)
    @total = 0
    @start = 0
    self
  end

  def combination(num)
    num = Rubinius::Type.coerce_to num, Fixnum, :to_int
    return to_enum(:combination, num) unless block_given?

    if num == 0
      yield []
    elsif num == 1
      each do |i|
        yield [i]
      end
    elsif num == size
      yield self.dup
    elsif num >= 0 && num < size
      stack = Rubinius::Tuple.pattern num + 1, 0
      chosen = Rubinius::Tuple.new num
      lev = 0
      done = false
      stack[0] = -1
      until done
        chosen[lev] = self.at(stack[lev+1])
        while lev < num - 1
          lev += 1
          chosen[lev] = self.at(stack[lev+1] = stack[lev] + 1)
        end
        yield chosen.to_a
        lev += 1
        begin
          done = lev == 0
          stack[lev] += 1
          lev -= 1
        end while stack[lev+1] + num == size + lev + 1
      end
    end
    self
  end

  def compact
    out = dup
    out.untaint if out.tainted?
    out.trust if out.untrusted?

    Array.new(out.compact! || out)
  end

  def compact!
    Rubinius.check_frozen

    if (deleted = @tuple.delete(@start, @total, nil)) > 0
      @total -= deleted
      reallocate_shrink()
      return self
    else
      return nil
    end
  end

  def concat(other)
    Rubinius.primitive :array_concat

    other = Rubinius::Type.coerce_to(other, Array, :to_ary)
    Rubinius.check_frozen

    return self if other.empty?

    concat other
  end

  def cycle(n=nil)
    return to_enum(:cycle, n) unless block_given?
    return nil if empty?

    # Don't use nil? because, historically, lame code has overridden that method
    if n.equal? nil
      while true
        each { |x| yield x }
      end
    else
      n = Rubinius::Type.coerce_to n, Fixnum, :to_int
      n.times do
        each { |x| yield x }
      end
    end
    nil
  end

  def delete(obj)
    key = undefined
    i = @start
    total = i + @total
    tuple = @tuple

    while i < total
      element = tuple.at i
      if element == obj
        # We MUST check frozen here, not at the top, because MRI
        # requires that #delete not raise unless an element would
        # be deleted.
        Rubinius.check_frozen
        tuple.put i, key
        last_matched_element = element
      end
      i += 1
    end

    deleted = @tuple.delete @start, @total, key
    if deleted > 0
      @total -= deleted
      reallocate_shrink()
      return last_matched_element
    end

    if block_given?
      yield
    else
      nil
    end
  end

  def delete_at(idx)
    Rubinius.check_frozen

    idx = Rubinius::Type.coerce_to idx, Fixnum, :to_int

    # Flip to positive and weed out out of bounds
    idx += @total if idx < 0
    return nil if idx < 0 or idx >= @total

    # Grab the object and adjust the indices for the rest
    obj = @tuple.at(@start + idx)

    # Shift style.
    if idx == 0
      @tuple.put @start, nil
      @start += 1
    else
      @tuple.copy_from(@tuple, @start+idx+1, @total-idx-1, @start+idx)
      @tuple.put(@start + @total - 1, nil)
    end

    @total -= 1
    obj
  end

  def delete_if
    return to_enum(:delete_if) unless block_given?

    Rubinius.check_frozen

    return self if empty?

    i = pos = @start
    total = i + @total
    tuple = @tuple

    while i < total
      x = tuple.at i
      unless yield x
        # Ok, keep the value, so stick it back into the array at
        # the insert position
        tuple.put pos, x
        pos += 1
      end

      i += 1
    end

    @total = pos - @start

    self
  end

  def each_index
    return to_enum(:each_index) unless block_given?

    i = 0
    total = @total

    while i < total
      yield i
      i += 1
    end

    self
  end

  # WARNING: This method does no boundary checking. It is expected that
  # the caller handle that, eg #slice!
  def delete_range(index, del_length)
    # optimize for fast removal..
    reg_start = index + del_length
    reg_length = @total - reg_start

    if reg_start <= @total
      # If we're removing from the front, also reset @start to better
      # use the Tuple
      if index == 0
        # Use a shift start optimization if we're only removing one
        # element and the shift started isn't already huge.
        if del_length == 1
          @start += 1
        else
          @tuple.copy_from @tuple, reg_start + @start, reg_length, 0
          @start = 0
        end
      else
        @tuple.copy_from @tuple, reg_start + @start, reg_length,
          @start + index
      end

      # TODO we leave the old references in the Tuple, we should
      # probably clear them out though.
      @total -= del_length
    end
  end

  private :delete_range

  def eql?(other)
    return true if equal? other
    return false unless other.kind_of?(Array)
    return false if @total != other.size

    Thread.detect_recursion self, other do
      i = 0
      each do |x|
        return false unless x.eql? other[i]
        i += 1
      end
    end

    true
  end

  def empty?
    @total == 0
  end

  def fetch(idx, default=undefined)
    orig = idx
    idx = Rubinius::Type.coerce_to(idx, Fixnum, :to_int)

    idx += @total if idx < 0

    if idx < 0 or idx >= @total
      if block_given?
        return yield(orig)
      end

      return default unless undefined.equal?(default)

      raise IndexError, "index #{idx} out of bounds"
    end

    at(idx)
  end

  def fill(a=undefined, b=undefined, c=undefined)
    Rubinius.check_frozen

    if block_given?
      unless undefined.equal?(c)
        raise ArgumentError, "wrong number of arguments"
      end
      one, two = a, b
    else
      if undefined.equal?(a)
        raise ArgumentError, "wrong number of arguments"
      end
      obj, one, two = a, b, c
    end

    if one.kind_of? Range
      raise TypeError, "length invalid with range" unless undefined.equal?(two)

      left = Rubinius::Type.coerce_to one.begin, Fixnum, :to_int
      left += size if left < 0
      raise RangeError, "#{one.inspect} out of range" if left < 0

      right = Rubinius::Type.coerce_to one.end, Fixnum, :to_int
      right += size if right < 0
      right += 1 unless one.exclude_end?
      return self if right <= left           # Nothing to modify

    elsif one and !undefined.equal?(one)
      left = Rubinius::Type.coerce_to one, Fixnum, :to_int
      left += size if left < 0
      left = 0 if left < 0

      if two and !undefined.equal?(two)
        begin
          right = Rubinius::Type.coerce_to two, Fixnum, :to_int
        rescue TypeError
          raise ArgumentError, "second argument must be a Fixnum"
        end

        return self if right == 0
        right += left
      else
        right = size
      end
    else
      left = 0
      right = size
    end

    total = @start + right

    if right > @total
      reallocate total
      @total = right
    end

    # Must be after the potential call to reallocate, since
    # reallocate might change @tuple
    tuple = @tuple

    i = @start + left

    if block_given?
      while i < total
        tuple.put i, yield(i-@start)
        i += 1
      end
    else
      while i < total
        tuple.put i, obj
        i += 1
      end
    end

    self
  end

  def first(n = undefined)
    return at(0) if undefined.equal?(n)

    n = Rubinius::Type.coerce_to n, Fixnum, :to_int
    raise ArgumentError, "Size must be positive" if n < 0

    Array.new self[0, n]
  end

  def flatten(level=-1)
    level = Rubinius::Type.coerce_to(level, Integer, :to_int)
    return self.dup if level == 0

    out = new_reserved size
    recursively_flatten(self, out, level)
    Rubinius::Type.infect(out, self)
    out
  end

  def flatten!(level=-1)
    Rubinius.check_frozen

    level = Rubinius::Type.coerce_to(level, Integer, :to_int)
    return nil if level == 0

    out = new_reserved size
    if recursively_flatten(self, out, level)
      replace(out)
      return self
    end

    nil
  end

  def hash
    hash_val = size
    mask = Fixnum::MAX >> 1

    # This is duplicated and manually inlined code from Thread for performance
    # reasons. Before refactoring it, please benchmark it and compare your
    # refactoring against the original.

    id = object_id
    objects = Thread.current.recursive_objects

    # If there is already an our version running...
    if objects.key? :__detect_outermost_recursion__

      # If we've seen self, unwind back to the outer version
      if objects.key? id
        raise Thread::InnerRecursionDetected
      end

      # .. or compute the hash value like normal
      begin
        objects[id] = true

        each { |x| hash_val = ((hash_val & mask) << 1) ^ x.hash }
      ensure
        objects.delete id
      end

      return hash_val
    else
      # Otherwise, we're the outermost version of this code..
      begin
        objects[:__detect_outermost_recursion__] = true
        objects[id] = true

        each { |x| hash_val = ((hash_val & mask) << 1) ^ x.hash }

        # An inner version will raise to return back here, indicating that
        # the whole structure is recursive. In which case, abondon most of
        # the work and return a simple hash value.
      rescue Thread::InnerRecursionDetected
        return size
      ensure
        objects.delete :__detect_outermost_recursion__
        objects.delete id
      end
    end

    return hash_val
  end

  def include?(obj)

    # This explicit loop is for performance only. Preferably,
    # this method would be implemented as:
    #
    #   each { |x| return true if x == obj }
    #
    # but the JIT will currently not inline the block into the
    # method that calls #include? which causes #include? to
    # execute about 3x slower. Since this is a very commonly
    # used method, this manual performance optimization is used.
    # Ideally, this will be removed when the JIT can handle the
    # block used here.

    i = @start
    total = i + @total
    tuple = @tuple

    while i < total
      return true if tuple.at(i) == obj
      i += 1
    end

    false
  end

  def find_index(obj=undefined)
    super
  end

  alias_method :index, :find_index

  def insert(idx, *items)
    Rubinius.check_frozen

    return self if items.length == 0

    # Adjust the index for correct insertion
    idx = Rubinius::Type.coerce_to idx, Fixnum, :to_int
    idx += (@total + 1) if idx < 0    # Negatives add AFTER the element
    raise IndexError, "#{idx} out of bounds" if idx < 0

    self[idx, 0] = items   # Cheat
    self
  end

  def inspect
    return "[]" if @total == 0
    comma = ", "
    result = "["

    return "[...]" if Thread.detect_recursion self do
      each_with_index do |element, index|
        temp = element.inspect
        result.force_encoding(temp.encoding) if index == 0
        result << temp << comma
      end
    end

    Rubinius::Type.infect(result, self)
    result.shorten!(2)
    result << "]"
    result
  end

  alias_method :to_s, :inspect

  def join(sep=nil)
    return "" if @total == 0

    out = ""
    raise ArgumentError, "recursive array join" if Thread.detect_recursion self do
      sep = sep.nil? ? $, : StringValue(sep)

      # We've manually unwound the first loop entry for performance
      # reasons.
      x = @tuple[@start]

      if str = String.try_convert(x)
        x = str
      elsif ary = Array.try_convert(x)
        x = ary.join(sep)
      else
        x = x.to_s
      end

      out.force_encoding(x.encoding)
      out << x

      total = @start + size()
      i = @start + 1

      while i < total
        out << sep if sep

        x = @tuple[i]

        if str = String.try_convert(x)
          x = str
        elsif ary = Array.try_convert(x)
          x = ary.join(sep)
        else
          x = x.to_s
        end

        out << x
        i += 1
      end
    end

    Rubinius::Type.infect(out, self)
  end

  def keep_if(&block)
    return to_enum :keep_if unless block_given?

    Rubinius.check_frozen

    replace select(&block)
  end

  def last(n=undefined)
    if undefined.equal?(n)
      return at(-1)
    elsif size < 1
      return []
    end

    n = Rubinius::Type.coerce_to n, Fixnum, :to_int
    return [] if n == 0

    raise ArgumentError, "count must be positive" if n < 0

    n = size if n > size
    Array.new self[-n..-1]
  end

  alias_method :collect, :map

  alias_method :collect!, :map!

  def nitems
    sum = 0
    each { |elem| sum += 1 unless elem.equal? nil }
    sum
  end

  def pack(directives)
    Rubinius.primitive :array_pack

    unless directives.kind_of? String
      return pack(StringValue(directives))
    end

    raise ArgumentError, "invalid directives string: #{directives}"
  end

  def permutation(num=undefined, &block)
    return to_enum(:permutation, num) unless block_given?

    if undefined.equal? num
      num = @total
    else
      num = Rubinius::Type.coerce_to num, Fixnum, :to_int
    end

    if num < 0 || @total < num
      # no permutations, yield nothing
    elsif num == 0
      # exactly one permutation: the zero-length array
      yield []
    elsif num == 1
      # this is a special, easy case
      each { |val| yield [val] }
    else
      # this is the general case
      perm = Array.new(num)
      used = Array.new(@total, false)

      if block
        # offensive (both definitions) copy.
        offensive = dup
        Rubinius.privately do
          offensive.__permute__(num, perm, 0, used, &block)
        end
      else
        __permute__(num, perm, 0, used, &block)
      end
    end

    self
  end

  def __permute__(num, perm, index, used, &block)
    # Recursively compute permutations of r elements of the set [0..n-1].
    # When we have a complete permutation of array indexes, copy the values
    # at those indexes into a new array and yield that array.
    #
    # num: the number of elements in each permutation
    # perm: the array (of size num) that we're filling in
    # index: what index we're filling in now
    # used: an array of booleans: whether a given index is already used
    #
    # Note: not as efficient as could be for big num.
    @total.times do |i|
      unless used[i]
        perm[index] = i
        if index < num-1
          used[i] = true
          __permute__(num, perm, index+1, used, &block)
          used[i] = false
        else
          yield values_at(*perm)
        end
      end
    end
  end
  private :__permute__

  def pop(many=undefined)
    Rubinius.check_frozen

    if undefined.equal?(many)
      return nil if @total == 0

      @total -= 1
      index = @start + @total

      elem = @tuple.at(index)
      @tuple.put index, nil

      elem
    else
      many = Rubinius::Type.coerce_to(many, Fixnum, :to_int)
      raise ArgumentError, "negative array size" if many < 0

      first = @total - many
      first = 0 if first < 0

      out = Array.new self[first, many]

      if many > @total
        @total = 0
      else
        @total -= many
      end

      return out
    end
  end

  # Implementation notes: We build a block that will generate all the
  # combinations by building it up successively using "inject" and starting
  # with one responsible to append the values.
  def product(*args)
    args.map! { |x| Rubinius::Type.coerce_to(x, Array, :to_ary) }

    # Check the result size will fit in an Array.
    sum = args.inject(size) { |n, x| n * x.size }

    if sum > Fixnum::MAX
      raise RangeError, "product result is too large"
    end

    # TODO rewrite this to not use a tree of Proc objects.

    # to get the results in the same order as in MRI, vary the last argument first
    args.reverse!

    result = []
    args.push self

    outer_lambda = args.inject(result.method(:push)) do |trigger, values|
      lambda do |partial|
        values.each do |val|
          trigger.call(partial.dup << val)
        end
      end
    end

    outer_lambda.call([])

    if block_given?
      block_result = self
      result.each { |v| block_result << yield(v) }
      block_result
    else
      result
    end
  end

  def push(*args)
    Rubinius.check_frozen

    return self if args.empty?

    concat args
  end

  def rassoc(obj)
    each do |elem|
      if elem.kind_of? Array and elem.at(1) == obj
        return elem
      end
    end

    nil
  end

  def reject(&block)
    return to_enum(:reject) unless block_given?
    Array.new(self).delete_if(&block)
  end

  def reject!(&block)
    return to_enum(:reject!) unless block_given?

    Rubinius.check_frozen

    was = size()
    delete_if(&block)

    return nil if was == size()
    self
  end

  def repeated_combination(combination_size, &block)
    combination_size = combination_size.to_i
    unless block_given?
      return Enumerator.new(self, :repeated_combination, combination_size)
    end

    if combination_size < 0
      # yield nothing
    else
      Rubinius.privately do
        dup.compile_repeated_combinations(combination_size, [], 0, combination_size, &block)
      end
    end

    return self
  end

  def compile_repeated_combinations(combination_size, place, index, depth, &block)
    if depth > 0
      (length - index).times do |i|
        place[combination_size-depth] = index + i
        compile_repeated_combinations(combination_size,place,index + i,depth-1, &block)
      end
    else
      yield place.map { |element| self[element] }
    end
  end

  private :compile_repeated_combinations

  def repeated_permutation(combination_size, &block)
    combination_size = combination_size.to_i
    unless block_given?
      return Enumerator.new(self, :repeated_permutation, combination_size)
    end

    if combination_size < 0
      # yield nothing
    elsif combination_size == 0
      yield []
    else
      Rubinius.privately do
        dup.compile_repeated_permutations(combination_size, [], 0, &block)
      end
    end

    return self
  end

  def compile_repeated_permutations(combination_size, place, index, &block)
    length.times do |i|
      place[index] = i
      if index < (combination_size-1)
        compile_repeated_permutations(combination_size, place, index + 1, &block)
      else
        yield place.map { |element| self[element] }
      end
    end
  end

  private :compile_repeated_permutations

  def reverse
    Array.new dup.reverse!
  end

  def reverse!
    Rubinius.check_frozen

    return self unless @total > 1

    @tuple.reverse! @start, @total

    return self
  end

  def reverse_each
    return to_enum(:reverse_each) unless block_given?

    stop = @start - 1
    i = stop + @total
    tuple = @tuple

    while i > stop
      yield tuple.at(i)
      i -= 1
    end

    self
  end

  def rindex(obj=undefined)
    if undefined.equal?(obj)
      return to_enum(:rindex, obj) unless block_given?

      i = @total - 1
      while i >= 0
        return i if yield @tuple.at(@start + i)

        # Compensate for the array being modified by the block
        i = @total if i > @total

        i -= 1
      end
    else
      stop = @start - 1
      i = stop + @total
      tuple = @tuple

      while i > stop
        return i - @start if tuple.at(i) == obj
        i -= 1
      end
    end
    nil
  end

  def rotate(n=1)
    n = Rubinius::Type.coerce_to(n, Integer, :to_int)
    return Array.new(self) if length == 1
    return []       if empty?

    ary = Array.new(self)
    idx = n % ary.size

    ary[idx..-1].concat ary[0...idx]
  end

  def rotate!(cnt=1)
    Rubinius.check_frozen

    return self if length == 0 || length == 1

    ary = rotate(cnt)
    replace ary
  end

  def sample(count=undefined, options=undefined)
    return at Kernel.rand(size) if undefined.equal? count

    if undefined.equal? options
      if o = Rubinius::Type.check_convert_type(count, Hash, :to_hash)
        options = o
        count = nil
      else
        options = nil
        count = Rubinius::Type.coerce_to count, Fixnum, :to_int
      end
    else
      count = Rubinius::Type.coerce_to count, Fixnum, :to_int
      options = Rubinius::Type.coerce_to options, Hash, :to_hash
    end

    if count and count < 0
      raise ArgumentError, "count must be greater than 0"
    end

    rng = options[:random] if options
    rng = Kernel unless rng and rng.respond_to? :rand

    unless count
      random = Rubinius::Type.coerce_to rng.rand, Fixnum, :to_int
      raise RangeError, "random value must be >= 0" if random < 0
      raise RangeError, "random value must be less than Array size" unless random < size

      return at random
    end

    count = size if count > size
    result = Array.new self

    count.times do |i|
      random = Rubinius::Type.coerce_to rng.rand, Fixnum, :to_int
      raise RangeError, "random value must be >= 0" if random < 0
      raise RangeError, "random value must be less than Array size" unless random < size

      result.tuple.swap i, random
    end

    return count == size ? result : result[0, count]
  end

  def select!(&block)
    return to_enum :select! unless block_given?

    Rubinius.check_frozen

    ary = select(&block)
    replace ary unless size == ary.size
  end

  def set_index(index, ent, fin=undefined)
    Rubinius.primitive :array_aset

    Rubinius.check_frozen

    ins_length = nil
    unless undefined.equal? fin
      ins_length = Rubinius::Type.coerce_to ent, Fixnum, :to_int
      ent = fin             # 2nd arg (ins_length) is the optional one!
    end

    # Normalise Ranges
    if index.kind_of? Range
      if ins_length
        raise ArgumentError, "Second argument invalid with a range"
      end

      last = Rubinius::Type.coerce_to index.last, Fixnum, :to_int
      last += @total if last < 0
      last += 1 unless index.exclude_end?

      index = Rubinius::Type.coerce_to index.first, Fixnum, :to_int

      if index < 0
        index += @total
        raise RangeError, "Range begin #{index-@total} out of bounds" if index < 0
      end

      # m..n, m > n allowed
      last = index if index > last

      ins_length = last - index
    else
      index = Rubinius::Type.coerce_to index, Fixnum, :to_int

      if index < 0
        index += @total
        raise IndexError,"Index #{index-@total} out of bounds" if index < 0
      end
    end

    if ins_length
      # ins_length < 0 not allowed
      raise IndexError, "Negative length #{ins_length}" if ins_length < 0

      # MRI seems to be forgiving here!
      space = @total - index
      if ins_length > space
        ins_length = space > 0 ? space : 0
      end

      replace_count = 0

      if ent.kind_of? Array
        replacement = ent
        replace_count = replacement.size
        replacement = replacement.first if replace_count == 1
      elsif ent.respond_to? :to_ary
        replacement = ent.to_ary
        replace_count = replacement.size
        replacement = replacement.first if replace_count == 1
      else
        replacement = ent
        replace_count = 1
      end

      new_total = (index > @total) ? index : @total
      if replace_count > ins_length
        new_total += replace_count - ins_length
      elsif replace_count < ins_length
        new_total -= ins_length - replace_count
      end

      if new_total > @tuple.size - @start
        # Expand the size just like #<< does.
        # MRI uses a straight realloc here to the exact size, but
        # realloc can easily include bumper data so it's pretty fast.
        # We simply compensate by using the same logic to reduce
        # having to copy data.
        new_tuple = Rubinius::Tuple.new(new_total + @tuple.size / 2)

        new_tuple.copy_from(@tuple, @start, index < @total ? index : @total, 0)

        case replace_count
        when 1
          new_tuple[index] = replacement
        when 0
          # nothing
        else
          new_tuple.copy_from(replacement.tuple, replacement.start,
                              replace_count, index)
        end

        if index < @total
          new_tuple.copy_from(@tuple, @start + index + ins_length,
                              @total - index - ins_length,
                              index + replace_count)
        end
        @start = 0
        @tuple = new_tuple
        @total = new_total
      else
        # Move the elements to the right
        if index < @total
          right_start = @start + index + ins_length
          right_len = @total - index - ins_length

          @tuple.copy_from(@tuple, right_start, right_len,
                           @start + index + replace_count)
        end

        case replace_count
        when 1
          @tuple[@start + index] = replacement
        when 0
          # nothing
        else
          @tuple.copy_from(replacement.tuple, replacement.start,
                              replace_count, @start + index)
        end

        @total = new_total
      end

      return ent
    else
      nt = @start + index + 1
      reallocate(nt) if @tuple.size < nt

      @tuple.put @start + index, ent
      if index >= @total - 1
        @total = index + 1
      end
      return ent
    end
  end

  alias_method :[]=, :set_index

  private :set_index

  # Some code depends on Array having it's own #select method,
  # not just using the Enumerable one. This alias achieves that.
  alias_method :select, :find_all

  def shift(n=undefined)
    Rubinius.check_frozen

    if undefined.equal?(n)
      return nil if @total == 0
      obj = @tuple.at @start
      @tuple.put @start, nil
      @start += 1
      @total -= 1

      obj
    else
      n = Rubinius::Type.coerce_to(n, Fixnum, :to_int)
      raise ArgumentError, "negative array size" if n < 0

      Array.new slice!(0, n)
    end
  end

  def shuffle(options = undefined)
    return dup.shuffle!(options) if instance_of? Array
    Array.new(self).shuffle!(options)
  end

  def shuffle!(options = undefined)
    Rubinius.check_frozen

    random_generator = Kernel

    unless undefined.equal? options
      options = Rubinius::Type.coerce_to options, Hash, :to_hash
      random_generator = options[:random] if options[:random].respond_to?(:rand)
    end

    size.times do |i|
      r = i + random_generator.rand(size - i)
      @tuple.swap(@start + i, @start + r)
    end
    self
  end

  def slice!(start, length=undefined)
    Rubinius.check_frozen

    if undefined.equal? length
      if start.kind_of? Range
        range = start
        out = self[range]

        range_start = Rubinius::Type.coerce_to range.begin, Fixnum, :to_int
        if range_start < 0
          range_start = range_start + @total
        end

        range_end = Rubinius::Type.coerce_to range.end, Fixnum, :to_int
        if range_end < 0
          range_end = range_end + @total
        elsif range_end >= @total
          range_end = @total - 1
        end

        range_length = range_end - range_start
        range_length += 1 unless range.exclude_end?

        if range_start < @total && range_start >= 0 && range_end < @total && range_end >= 0 && range_length > 0
          delete_range(range_start, range_length)
        end
      else
        # make sure that negative values are not passed through to the
        # []= assignment
        start = Rubinius::Type.coerce_to start, Integer, :to_int
        start = start + @total if start < 0

        # This is to match the MRI behaviour of not extending the array
        # with nil when specifying an index greater than the length
        # of the array.
        return out unless start >= 0 and start < @total

        out = @tuple.at start + @start

        # Check for shift style.
        if start == 0
          @tuple.put @start, nil
          @total -= 1
          @start += 1
        else
          delete_range(start, 1)
        end
      end
    else
      start = Rubinius::Type.coerce_to start, Fixnum, :to_int
      length = Rubinius::Type.coerce_to length, Fixnum, :to_int

      out = self[start, length]

      if start < 0
        start = @total + start
      end
      if start + length > @total
        length = @total - start
      end

      if start < @total && start >= 0
        delete_range(start, length)
      end
    end

    out
  end

  def drop(n)
    n = Rubinius::Type.coerce_to(n, Fixnum, :to_int)
    raise ArgumentError, "attempt to drop negative size" if n < 0

    return [] if @total == 0

    new_size = @total - n
    return [] if new_size <= 0

    new_range n, new_size
  end

  def sort(&block)
    Array.new dup.sort_inplace(&block)
  end

  def sort_by!(&block)
    Rubinius.check_frozen

    return to_enum :sort_by! unless block_given?

    replace sort_by(&block)
  end

  # Sorts this Array in-place. See #sort.
  #
  # The threshold for choosing between Insertion sort and Mergesort
  # is 13, as determined by a bit of quick tests.
  #
  # For results and methodology, see the commit message.
  def sort_inplace(&block)
    Rubinius.check_frozen

    return self unless @total > 1

    if (@total - @start) < 13
      if block
        isort_block! @start, (@start + @total), block
      else
        isort! @start, (@start + @total)
      end
    else
      if block
        mergesort_block! block
      else
        mergesort!
      end
    end

    self
  end

  protected :sort_inplace

  # Make a public alias. Only use sort_inplace internally to avoid
  # subclass overrides.

  # Alias used to avoid subclass overrides
  alias_method :sort!, :sort_inplace
  public :sort!

  def to_a
    if self.instance_of? Array
      self
    else
      Array.new(self)
    end
  end

  def to_ary
    self
  end

  def transpose
    return [] if empty?

    out = []
    max = nil

    each do |ary|
      ary = Rubinius::Type.coerce_to ary, Array, :to_ary
      max ||= ary.size

      # Catches too-large as well as too-small (for which #fetch would suffice)
      raise IndexError, "All arrays must be same length" if ary.size != max

      ary.size.times do |i|
        entry = (out[i] ||= [])
        entry << ary.at(i)
      end
    end

    out
  end

  def uniq(&block)
    dup.uniq!(&block) or dup
  end

  def uniq!(&block)
    Rubinius.check_frozen

    if block_given?
      im = Rubinius::IdentityMap.from(self, &block)
    else
      im = Rubinius::IdentityMap.from(self)
    end
    return if im.size == size

    array = im.to_array
    @tuple = array.tuple
    @start = array.start
    @total = array.total

    self
  end

  def unshift(*values)
    Rubinius.check_frozen

    return self if values.empty?

    if @start > values.size
      # fit the new values in between 0 and @start if possible
      @start -= values.size
      @tuple.copy_from(values.tuple, 0, values.size, @start)
    else
      new_tuple = Rubinius::Tuple.new @total + values.size
      new_tuple.copy_from values.tuple, 0, values.size, 0
      new_tuple.copy_from @tuple, @start, @total, values.size
      @start = 0
      @tuple = new_tuple
    end

    @total += values.size
    self
  end

  def values_at(*args)
    out = []

    args.each do |elem|
      # Cannot use #[] because of subtly different errors
      if elem.kind_of? Range
        finish = Rubinius::Type.coerce_to elem.last, Fixnum, :to_int
        start = Rubinius::Type.coerce_to elem.first, Fixnum, :to_int

        start += @total if start < 0
        next if start < 0

        finish += @total if finish < 0
        finish -= 1 if elem.exclude_end?

        next if finish < start

        start.upto(finish) { |i| out << at(i) }

      else
        i = Rubinius::Type.coerce_to elem, Fixnum, :to_int
        out << at(i)
      end
    end

    out
  end

  def zip(*others)
    out = Array.new(size) { [] }
    others = others.map do |ary|
      if ary.respond_to?(:to_ary)
        ary.to_ary
      else
        elements = []
        ary.each { |e| elements << e }
        elements
      end
    end

    size.times do |i|
      slot = out.at(i)
      slot << @tuple.at(@start + i)
      others.each { |ary| slot << ary.at(i) }
    end

    if block_given?
      out.each { |ary| yield ary }
      return nil
    end

    out
  end

  # Reallocates the internal Tuple to accommodate at least given size
  def reallocate(at_least)
    return if at_least < @tuple.size

    new_total = @tuple.size * 2

    if new_total < at_least
      new_total = at_least
    end

    new_tuple = Rubinius::Tuple.new new_total
    new_tuple.copy_from @tuple, @start, @total, 0

    @start = 0
    @tuple = new_tuple
  end

  private :reallocate

  def reallocate_shrink
    new_total = @tuple.size
    return if @total > (new_total / 3)

    # halve the tuple size until the total > 1/3 the size of the total
    begin
      new_total /= 2
    end while @total < (new_total / 6)

    new_tuple = Rubinius::Tuple.new(new_total)
    # position values in the middle somewhere
    new_start = (new_total - @total)/2
    new_tuple.copy_from @tuple, @start, @total, new_start

    @start = new_start
    @tuple = new_tuple
  end

  private :reallocate_shrink

  # Helper to recurse through flattening since the method
  # is not allowed to recurse itself. Detects recursive structures.
  def recursively_flatten(array, out, max_levels = -1)
    modified = false

    # Strict equality since < 0 means 'infinite'
    if max_levels == 0
      out.concat(array)
      return false
    end

    max_levels -= 1
    recursion = Thread.detect_recursion(array) do
      i = array.start
      total = i + array.total
      tuple = array.tuple

      while i < total
        o = tuple.at i

        if ary = Rubinius::Type.check_convert_type(o, Array, :to_ary)
          modified = true
          recursively_flatten(ary, out, max_levels)
        else
          out << o
        end

        i += 1
      end
    end

    raise ArgumentError, "tried to flatten recursive array" if recursion
    modified
  end

  private :recursively_flatten

  # Non-recursive sort using a temporary tuple for scratch storage.
  # This is a hybrid mergesort; it's hybrid because for short runs under
  # 8 elements long we use insertion sort and then merge those sorted
  # runs back together.
  def mergesort!
    width = 7
    @scratch = Rubinius::Tuple.new @tuple.size

    # do a pre-loop to create a bunch of short sorted runs; isort on these
    # 7-element sublists is more efficient than doing merge sort on 1-element
    # sublists
    left = @start
    finish = @total + @start
    while left < finish
      right = left + width
      right = right < finish ? right : finish
      last = left + (2 * width)
      last = last < finish ? last : finish

      isort!(left, right)
      isort!(right, last)

      left += 2 * width
    end

    # now just merge together those sorted lists from the prior loop
    width = 7
    while width < @total
      left = @start
      while left < finish
        right = left + width
        right = right < finish ? right : finish
        last = left + (2 * width)
        last = last < finish ? last : finish

        bottom_up_merge(left, right, last)
        left += 2 * width
      end

      @tuple, @scratch = @scratch, @tuple
      width *= 2
    end

    @scratch = nil
    self
  end
  private :mergesort!

  def bottom_up_merge(left, right, last)
    left_index = left
    right_index = right
    i = left

    while i < last
      if left_index < right && (right_index >= last || (@tuple.at(left_index) <=> @tuple.at(right_index)) <= 0)
        @scratch[i] = @tuple.at(left_index)
        left_index += 1
      else
        @scratch[i] = @tuple.at(right_index)
        right_index += 1
      end

      i += 1
    end
  end
  private :bottom_up_merge

  def mergesort_block!(block)
    width = 7
    @scratch = Rubinius::Tuple.new @tuple.size

    left = @start
    finish = @total + @start
    while left < finish
      right = left + width
      right = right < finish ? right : finish
      last = left + (2 * width)
      last = last < finish ? last : finish

      isort_block!(left, right, block)
      isort_block!(right, last, block)

      left += 2 * width
    end

    width = 7
    while width < @total
      left = @start
      while left < finish
        right = left + width
        right = right < finish ? right : finish
        last = left + (2 * width)
        last = last < finish ? last : finish

        bottom_up_merge_block(left, right, last, block)
        left += 2 * width
      end

      @tuple, @scratch = @scratch, @tuple
      width *= 2
    end

    @scratch = nil
    self
  end
  private :mergesort_block!

  def bottom_up_merge_block(left, right, last, block)
    left_index = left
    right_index = right
    i = left

    while i < last
      if left_index < right && (right_index >= last || block.call(@tuple.at(left_index), @tuple.at(right_index)) <= 0)
        @scratch[i] = @tuple.at(left_index)
        left_index += 1
      else
        @scratch[i] = @tuple.at(right_index)
        right_index += 1
      end

      i += 1
    end
  end
  private :bottom_up_merge_block

  # Insertion sort in-place between the given indexes.
  def isort!(left, right)
    i = left + 1

    tup = @tuple

    while i < right
      j = i

      while j > left
        jp = j - 1
        el1 = tup.at(jp)
        el2 = tup.at(j)

        unless cmp = (el1 <=> el2)
          raise ArgumentError, "comparison of #{el1.inspect} with #{el2.inspect} failed (#{j})"
        end

        break unless cmp > 0

        tup.put(j, el1)
        tup.put(jp, el2)

        j = jp
      end

      i += 1
    end
  end
  private :isort!

  # Insertion sort in-place between the given indexes using a block.
  def isort_block!(left, right, block)
    i = left + 1

    while i < right
      j = i

      while j > left
        block_result = block.call(@tuple.at(j - 1), @tuple.at(j))

        if block_result.nil?
          raise ArgumentError, 'block returned nil'
        elsif block_result > 0
          @tuple.swap(j, (j - 1))
          j -= 1
        else
          break
        end
      end

      i += 1
    end
  end
  private :isort_block!

  # Move to compiler runtime
  def __rescue_match__(exception)
    each { |x| return true if x === exception }
    false
  end
end
