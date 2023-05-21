import Kernel, except: [to_string: 1]

defmodule Macro do
  @moduledoc ~S"""
  Functions for manipulating AST and implementing macros.

  Macros are compile-time constructs that receive Elixir's AST as input
  and return Elixir's AST as output.

  Many of the functions in this module exist precisely to work with Elixir
  AST, to traverse, query, and transform it.

  Let's see a simple example that shows the difference between functions
  and macros:

      defmodule Example do
        defmacro macro_inspect(value) do
          IO.inspect(value)
          value
        end

        def fun_inspect(value) do
          IO.inspect(value)
          value
        end
      end

  Now let's give it a try:

      import Example

      macro_inspect(1)
      #=> 1
      #=> 1

      fun_inspect(1)
      #=> 1
      #=> 1

  So far they behave the same, as we are passing an integer as argument.
  But let's see what happens when we pass an expression:

      macro_inspect(1 + 2)
      #=> {:+, [line: 3], [1, 2]}
      #=> 3

      fun_inspect(1 + 2)
      #=> 3
      #=> 3

  The macro receives the representation of the code given as argument,
  while a function receives the result of the code given as argument.
  A macro must return a superset of the code representation. See
  `t:input/0` and `t:output/0` for more information.

  To learn more about Elixir's AST and how to build them programmatically,
  see `quote/2`.

  > #### Evaluating code {: .tip}
  >
  > The functions in this module do not evaluate code. In fact,
  > evaluating code from macros is often an anti-pattern. For code
  > evaluation, see the `Code` module.

  ## Custom Sigils

  Macros are also commonly used to implement custom sigils.

  Sigils start with `~` and are followed by one lowercase letter or by one
  or more uppercase letters, and then a separator
  (see the [Syntax Reference](syntax-reference.md)). One example is
  `~D[2020-10-13]` to define a date.

  To create a custom sigil, define a macro with the name `sigil_{identifier}`
  that takes two arguments. The first argument will be the string, the second
  will be a charlist containing any modifiers. If the sigil is lower case
  (such as `sigil_x`) then the string argument will allow interpolation.
  If the sigil is one or more upper case letters (such as `sigil_X` and
  `sigil_EXAMPLE`) then the string will not be interpolated.

  Valid modifiers are ASCII letters and digits. Any other character will
  cause a syntax error.

  Single-letter sigils are typically reserved to the language. Multi-letter
  sigils are uppercased and extensively used by the community to embed
  alternative markups and data-types within Elixir source code.

  The module containing the custom sigil must be imported before the sigil
  syntax can be used.

  ### Examples

  As an example, let's define a sigil `~x` and sigil `~X` which
  return its contents as a string. However, if the `r` modifier
  is given, it reverses the string instead:

      defmodule MySigils do
        defmacro sigil_x(term, [?r]) do
          quote do
            unquote(term) |> String.reverse()
          end
        end

        defmacro sigil_x(term, _modifiers) do
          term
        end

        defmacro sigil_X(term, [?r]) do
          quote do
            unquote(term) |> String.reverse()
          end
        end

        defmacro sigil_X(term, _modifiers) do
          term
        end
      end

      import MySigils

      ~x(with #{"inter" <> "polation"})
      #=> "with interpolation"

      ~x(with #{"inter" <> "polation"})r
      #=> "noitalopretni htiw"

      ~X(without #{"interpolation"})
      #=> "without \#{"interpolation"}"

      ~X(without #{"interpolation"})r
      #=> "}\"noitalopretni\"{# tuohtiw"

  """

  alias Code.Identifier

  @typedoc "Abstract Syntax Tree (AST)"
  @type t :: input

  @typedoc "The inputs of a macro"
  @type input ::
          input_expr
          | {input, input}
          | [input]
          | atom
          | number
          | binary

  @typep input_expr :: {input_expr | atom, metadata, atom | [input]}

  @typedoc "The output of a macro"
  @type output ::
          output_expr
          | {output, output}
          | [output]
          | atom
          | number
          | binary
          | captured_remote_function
          | pid

  @typep output_expr :: {output_expr | atom, metadata, atom | [output]}

  @typedoc """
  A keyword list of AST metadata.

  The metadata in Elixir AST is a keyword list of values. Any key can be used
  and different parts of the compiler may use different keys. For example,
  the AST received by a macro will always include the `:line` annotation,
  while the AST emitted by `quote/2` will only have the `:line` annotation if
  the `:line` option is provided.

  The following metadata keys are public:

    * `:context` - Defines the context in which the AST was generated.
      For example, `quote/2` will include the module calling `quote/2`
      as the context. This is often used to distinguish regular code from code
      generated by a macro or by `quote/2`.

    * `:counter` - The variable counter used for variable hygiene. In terms of
      the compiler, each variable is identified by the combination of either
      `name` and `metadata[:counter]`, or `name` and `context`.

    * `:generated` - Whether the code should be considered as generated by
      the compiler or not. This means the compiler and tools like Dialyzer may not
      emit certain warnings.

    * `:if_undefined` - How to expand a variable that is undefined. Set it to
      `:apply` if you want a variable to become a nullary call without warning
      or `:raise`

    * `:keep` - Used by `quote/2` with the option `location: :keep` to annotate
      the file and the line number of the quoted source.

    * `:line` - The line number of the AST node.

    * `:from_brackets` - Used to determine whether a call to `Access.get/3` is from
      bracket syntax or a function call.

  The following metadata keys are enabled by `Code.string_to_quoted/2`:

    * `:closing` - contains metadata about the closing pair, such as a `}`
      in a tuple or in a map, or such as the closing `)` in a function call
      with parens. The `:closing` does not delimit the end of expression if
      there are `:do` and `:end` metadata  (when `:token_metadata` is true)
    * `:column` - the column number of the AST node (when `:columns` is true)
    * `:delimiter` - contains the opening delimiter for sigils, strings,
      and charlists as a string (such as `"{"`, `"/"`, `"'"`, and the like)
    * `:format` - set to `:keyword` when an atom is defined as a keyword
    * `:do` - contains metadata about the `do` location in a function call with
      `do`-`end` blocks (when `:token_metadata` is true)
    * `:end` - contains metadata about the `end` location in a function call with
      `do`-`end` blocks (when `:token_metadata` is true)
    * `:end_of_expression` - denotes when the end of expression effectively
      happens. Available for all expressions except the last one inside a
      `__block__` (when `:token_metadata` is true)
    * `:indentation` - indentation of a sigil heredoc

  The following metadata keys are private:

    * `:alias` - Used for alias hygiene.
    * `:ambiguous_op` - Used for improved error messages in the compiler.
    * `:imports` - Used for import hygiene.
    * `:var` - Used for improved error messages on undefined variables.

  Do not rely on them as they may change or be fully removed in future versions
  of the language. They are often used by `quote/2` and the compiler to provide
  features like hygiene, better error messages, and so forth.

  If you introduce custom keys into the AST metadata, please make sure to prefix
  them with the name of your library or application, so that they will not conflict
  with keys that could potentially be introduced by the compiler in the future.
  """
  @type metadata :: keyword

  @typedoc "A captured remote function in the format of &Mod.fun/arity"
  @type captured_remote_function :: fun

  @doc """
  Breaks a pipeline expression into a list.

  The AST for a pipeline (a sequence of applications of `|>/2`) is similar to the
  AST of a sequence of binary operators or function applications: the top-level
  expression is the right-most `:|>` (which is the last one to be executed), and
  its left-hand and right-hand sides are its arguments:

      quote do: 100 |> div(5) |> div(2)
      #=> {:|>, _, [arg1, arg2]}

  In the example above, the `|>/2` pipe is the right-most pipe; `arg1` is the AST
  for `100 |> div(5)`, and `arg2` is the AST for `div(2)`.

  It's often useful to have the AST for such a pipeline as a list of function
  applications. This function does exactly that:

      Macro.unpipe(quote do: 100 |> div(5) |> div(2))
      #=> [{100, 0}, {{:div, [], [5]}, 0}, {{:div, [], [2]}, 0}]

  We get a list that follows the pipeline directly: first the `100`, then the
  `div(5)` (more precisely, its AST), then `div(2)`. The `0` as the second
  element of the tuples is the position of the previous element in the pipeline
  inside the current function application: `{{:div, [], [5]}, 0}` means that the
  previous element (`100`) will be inserted as the 0th (first) argument to the
  `div/2` function, so that the AST for that function will become `{:div, [],
  [100, 5]}` (`div(100, 5)`).
  """
  @spec unpipe(t()) :: [t()]
  def unpipe(expr) do
    :lists.reverse(unpipe(expr, []))
  end

  defp unpipe({:|>, _, [left, right]}, acc) do
    unpipe(right, unpipe(left, acc))
  end

  defp unpipe(other, acc) do
    [{other, 0} | acc]
  end

  @doc """
  Pipes `expr` into the `call_args` at the given `position`.

  This function can be used to implement `|>` like functionality. For example,
  `|>` itself is implemented as:

      defmacro left |> right do
        Macro.pipe(left, right, 0)
      end

  `expr` is the AST of an expression. `call_args` must be the AST *of a call*,
  otherwise this function will raise an error. As an example, consider the pipe
  operator `|>/2`, which uses this function to build pipelines.

  Even if the expression is piped into the AST, it doesn't necessarily mean that
  the AST is valid. For example, you could pipe an argument to `div/2`, effectively
  turning it into a call to `div/3`, which is a function that doesn't exist by
  default. The code will raise unless a `div/3` function is locally defined.
  """
  @spec pipe(t(), t(), integer) :: t()
  def pipe(expr, call_args, position)

  def pipe(expr, {:&, _, _} = call_args, _integer) do
    raise ArgumentError, bad_pipe(expr, call_args)
  end

  def pipe(expr, {tuple_or_map, _, _} = call_args, _integer) when tuple_or_map in [:{}, :%{}] do
    raise ArgumentError, bad_pipe(expr, call_args)
  end

  # Without this, `Macro |> Env == Macro.Env`.
  def pipe(expr, {:__aliases__, _, _} = call_args, _integer) do
    raise ArgumentError, bad_pipe(expr, call_args)
  end

  def pipe(expr, {:<<>>, _, _} = call_args, _integer) do
    raise ArgumentError, bad_pipe(expr, call_args)
  end

  def pipe(expr, {unquote, _, []}, _integer) when unquote in [:unquote, :unquote_splicing] do
    raise ArgumentError,
          "cannot pipe #{to_string(expr)} into the special form #{unquote}/1 " <>
            "since #{unquote}/1 is used to build the Elixir AST itself"
  end

  # {:fn, _, _} is what we get when we pipe into an anonymous function without
  # calling it, for example, `:foo |> (fn x -> x end)`.
  def pipe(expr, {:fn, _, _}, _integer) do
    raise ArgumentError,
          "cannot pipe #{to_string(expr)} into an anonymous function without" <>
            " calling the function; use Kernel.then/2 instead or" <>
            " define the anonymous function as a regular private function"
  end

  def pipe(expr, {call, line, atom}, integer) when is_atom(atom) do
    {call, line, List.insert_at([], integer, expr)}
  end

  def pipe(_expr, {op, _line, [arg]}, _integer) when op == :+ or op == :- do
    raise ArgumentError,
          "piping into a unary operator is not supported, please use the qualified name: " <>
            "Kernel.#{op}(#{to_string(arg)}), instead of #{op}#{to_string(arg)}"
  end

  # Piping to an Access.get/2,3 call in the form of brackets
  # (foo |> bar[]) raises a nice error.
  def pipe(
        expr,
        {{_, meta, [Access, :get] = op}, _meta, [first, second]} = _op_args,
        integer
      ) do
    if {:from_brackets, true} in meta do
      raise ArgumentError, """
      wrong operator precedence when piping into bracket-based access

       Instead of:

           #{to_string(expr)} |> #{to_string(first)}[#{to_string(second)}]

       You should write:

           (#{to_string(expr)} |> #{to_string(first)})[#{to_string(second)}]
      """
    else
      {op, meta, List.insert_at([first, second], integer, expr)}
    end
  end

  def pipe(expr, {op, line, args} = op_args, integer) when is_list(args) do
    cond do
      is_atom(op) and operator?(op, 1) ->
        raise ArgumentError,
              "cannot pipe #{to_string(expr)} into #{to_string(op_args)}, " <>
                "the #{to_string(op)} operator can only take one argument"

      is_atom(op) and operator?(op, 2) ->
        raise ArgumentError,
              "cannot pipe #{to_string(expr)} into #{to_string(op_args)}, " <>
                "the #{to_string(op)} operator can only take two arguments"

      true ->
        {op, line, List.insert_at(args, integer, expr)}
    end
  end

  def pipe(expr, call_args, _integer) do
    raise ArgumentError, bad_pipe(expr, call_args)
  end

  defp bad_pipe(expr, call_args) do
    "cannot pipe #{to_string(expr)} into #{to_string(call_args)}, " <>
      "can only pipe into local calls foo(), remote calls Foo.bar() or anonymous function calls foo.()"
  end

  @doc """
  Applies the given function to the node metadata if it contains one.

  This is often useful when used with `Macro.prewalk/2` to remove
  information like lines and hygienic counters from the expression
  for either storage or comparison.

  ## Examples

      iex> quoted = quote line: 10, do: sample()
      {:sample, [line: 10], []}
      iex> Macro.update_meta(quoted, &Keyword.delete(&1, :line))
      {:sample, [], []}

  """
  @spec update_meta(t, (keyword -> keyword)) :: t
  def update_meta(quoted, fun)

  def update_meta({left, meta, right}, fun) when is_list(meta) do
    {left, fun.(meta), right}
  end

  def update_meta(other, _fun) do
    other
  end

  @doc """
  Generates AST nodes for a given number of required argument
  variables using `Macro.var/2`.

  Note the arguments are not unique. If you later on want
  to access the same variables, you can invoke this function
  with the same inputs. Use `generate_unique_arguments/2` to
  generate a unique arguments that can't be overridden.

  ## Examples

      iex> Macro.generate_arguments(2, __MODULE__)
      [{:arg1, [], __MODULE__}, {:arg2, [], __MODULE__}]

  """
  @doc since: "1.5.0"
  @spec generate_arguments(0, context :: atom) :: []
  @spec generate_arguments(pos_integer, context) :: [{atom, [], context}, ...] when context: atom
  def generate_arguments(amount, context), do: generate_arguments(amount, context, &var/2)

  @doc """
  Returns the path to the node in `ast` which `fun` returns true.

  The path is a list, starting with the node in which `fun` returns
  true, followed by all of its parents.

  Computing the path can be an efficient operation when you want
  to find a particular node in the AST within its context and then
  assert something about it.

  ## Examples

      iex> Macro.path(quote(do: [1, 2, 3]), & &1 == 3)
      [3, [1, 2, 3]]

      iex> Macro.path(quote(do: Foo.bar(3)), & &1 == 3)
      [3, quote(do: Foo.bar(3))]

      iex> Macro.path(quote(do: %{foo: [bar: :baz]}), & &1 == :baz)
      [
        :baz,
        {:bar, :baz},
        [bar: :baz],
        {:foo, [bar: :baz]},
        {:%{}, [], [foo: [bar: :baz]]}
      ]

  """
  @doc since: "1.14.0"
  def path(ast, fun) when is_function(fun, 1) do
    path(ast, [], fun)
  end

  defp path({form, _, args} = ast, acc, fun) when is_atom(form) do
    acc = [ast | acc]

    if fun.(ast) do
      acc
    else
      path_args(args, acc, fun)
    end
  end

  defp path({form, _meta, args} = ast, acc, fun) do
    acc = [ast | acc]

    if fun.(ast) do
      acc
    else
      path(form, acc, fun) || path_args(args, acc, fun)
    end
  end

  defp path({left, right} = ast, acc, fun) do
    acc = [ast | acc]

    if fun.(ast) do
      acc
    else
      path(left, acc, fun) || path(right, acc, fun)
    end
  end

  defp path(list, acc, fun) when is_list(list) do
    acc = [list | acc]

    if fun.(list) do
      acc
    else
      path_list(list, acc, fun)
    end
  end

  defp path(ast, acc, fun) do
    if fun.(ast) do
      [ast | acc]
    end
  end

  defp path_args(atom, _acc, _fun) when is_atom(atom), do: nil
  defp path_args(list, acc, fun) when is_list(list), do: path_list(list, acc, fun)

  defp path_list([], _acc, _fun) do
    nil
  end

  defp path_list([arg | args], acc, fun) do
    path(arg, acc, fun) || path_list(args, acc, fun)
  end

  @doc """
  Generates AST nodes for a given number of required argument
  variables using `Macro.unique_var/2`.

  ## Examples

      iex> [var1, var2] = Macro.generate_unique_arguments(2, __MODULE__)
      iex> {:arg1, [counter: c1], __MODULE__} = var1
      iex> {:arg2, [counter: c2], __MODULE__} = var2
      iex> is_integer(c1) and is_integer(c2)
      true

  """
  @doc since: "1.11.3"
  @spec generate_unique_arguments(0, context :: atom) :: []
  @spec generate_unique_arguments(pos_integer, context) :: [
          {atom, [counter: integer], context},
          ...
        ]
        when context: atom
  def generate_unique_arguments(amount, context),
    do: generate_arguments(amount, context, &unique_var/2)

  defp generate_arguments(0, context, _fun) when is_atom(context), do: []

  defp generate_arguments(amount, context, fun)
       when is_integer(amount) and amount > 0 and is_atom(context) do
    for id <- 1..amount, do: fun.(String.to_atom("arg" <> Integer.to_string(id)), context)
  end

  @doc """
  Generates an AST node representing the variable given
  by the atoms `var` and `context`.

  Note this variable is not unique. If you later on want
  to access this same variable, you can invoke `var/2`
  again with the same arguments. Use `unique_var/2` to
  generate a unique variable that can't be overridden.

  ## Examples

  In order to build a variable, a context is expected.
  Most of the times, in order to preserve hygiene, the
  context must be `__MODULE__/0`:

      iex> Macro.var(:foo, __MODULE__)
      {:foo, [], __MODULE__}

  However, if there is a need to access the user variable,
  nil can be given:

      iex> Macro.var(:foo, nil)
      {:foo, [], nil}

  """
  @spec var(var, context) :: {var, [], context} when var: atom, context: atom
  def var(var, context) when is_atom(var) and is_atom(context) do
    {var, [], context}
  end

  @doc """
  Generates an AST node representing a unique variable
  given by the atoms `var` and `context`.

  Calling this function with the same arguments will
  generate another variable, with its own unique counter.
  See `var/2` for an alternative.

  ## Examples

      iex> {:foo, [counter: c], __MODULE__} = Macro.unique_var(:foo, __MODULE__)
      iex> is_integer(c)
      true

  """
  @doc since: "1.11.3"
  @spec unique_var(var, context) :: {var, [counter: integer], context}
        when var: atom, context: atom
  def unique_var(var, context) when is_atom(var) and is_atom(context) do
    {var, [counter: :elixir_module.next_counter(context)], context}
  end

  @doc """
  Performs a depth-first traversal of quoted expressions
  using an accumulator.

  Returns a tuple where the first element is a new AST and the second one is
  the final accumulator. The new AST is the result of invoking `pre` on each
  node of `ast` during the pre-order phase and `post` during the post-order
  phase.

  ## Examples

      iex> ast = quote do: 5 + 3 * 7
      iex> {:+, _, [5, {:*, _, [3, 7]}]} = ast
      iex> {new_ast, acc} =
      ...>  Macro.traverse(
      ...>    ast,
      ...>    [],
      ...>    fn
      ...>      {:+, meta, children}, acc -> {{:-, meta, children}, [:- | acc]}
      ...>      {:*, meta, children}, acc -> {{:/, meta, children}, [:/ | acc]}
      ...>      other, acc -> {other, acc}
      ...>    end,
      ...>    fn
      ...>      {:-, meta, children}, acc -> {{:min, meta, children}, [:min | acc]}
      ...>      {:/, meta, children}, acc -> {{:max, meta, children}, [:max | acc]}
      ...>      other, acc -> {other, acc}
      ...>    end
      ...>  )
      iex> {:min, _, [5, {:max, _, [3, 7]}]} = new_ast
      iex> [:min, :max, :/, :-] = acc
      iex> Code.eval_quoted(new_ast)
      {5, []}

  """
  @spec traverse(t, any, (t, any -> {t, any}), (t, any -> {t, any})) :: {t, any}
  def traverse(ast, acc, pre, post) when is_function(pre, 2) and is_function(post, 2) do
    {ast, acc} = pre.(ast, acc)
    do_traverse(ast, acc, pre, post)
  end

  defp do_traverse({form, meta, args}, acc, pre, post) when is_atom(form) do
    {args, acc} = do_traverse_args(args, acc, pre, post)
    post.({form, meta, args}, acc)
  end

  defp do_traverse({form, meta, args}, acc, pre, post) do
    {form, acc} = pre.(form, acc)
    {form, acc} = do_traverse(form, acc, pre, post)
    {args, acc} = do_traverse_args(args, acc, pre, post)
    post.({form, meta, args}, acc)
  end

  defp do_traverse({left, right}, acc, pre, post) do
    {left, acc} = pre.(left, acc)
    {left, acc} = do_traverse(left, acc, pre, post)
    {right, acc} = pre.(right, acc)
    {right, acc} = do_traverse(right, acc, pre, post)
    post.({left, right}, acc)
  end

  defp do_traverse(list, acc, pre, post) when is_list(list) do
    {list, acc} = do_traverse_args(list, acc, pre, post)
    post.(list, acc)
  end

  defp do_traverse(x, acc, _pre, post) do
    post.(x, acc)
  end

  defp do_traverse_args(args, acc, _pre, _post) when is_atom(args) do
    {args, acc}
  end

  defp do_traverse_args(args, acc, pre, post) when is_list(args) do
    :lists.mapfoldl(
      fn x, acc ->
        {x, acc} = pre.(x, acc)
        do_traverse(x, acc, pre, post)
      end,
      acc,
      args
    )
  end

  @doc """
  Performs a depth-first, pre-order traversal of quoted expressions.

  Returns a new AST where each node is the result of invoking `fun` on each
  corresponding node of `ast`.

  ## Examples

      iex> ast = quote do: 5 + 3 * 7
      iex> {:+, _, [5, {:*, _, [3, 7]}]} = ast
      iex> new_ast = Macro.prewalk(ast, fn
      ...>   {:+, meta, children} -> {:*, meta, children}
      ...>   {:*, meta, children} -> {:+, meta, children}
      ...>   other -> other
      ...> end)
      iex> {:*, _, [5, {:+, _, [3, 7]}]} = new_ast
      iex> Code.eval_quoted(ast)
      {26, []}
      iex> Code.eval_quoted(new_ast)
      {50, []}

  """
  @spec prewalk(t, (t -> t)) :: t
  def prewalk(ast, fun) when is_function(fun, 1) do
    elem(prewalk(ast, nil, fn x, nil -> {fun.(x), nil} end), 0)
  end

  @doc """
  Performs a depth-first, pre-order traversal of quoted expressions
  using an accumulator.

  Returns a tuple where the first element is a new AST where each node is the
  result of invoking `fun` on each corresponding node and the second one is the
  final accumulator.

  ## Examples

      iex> ast = quote do: 5 + 3 * 7
      iex> {:+, _, [5, {:*, _, [3, 7]}]} = ast
      iex> {new_ast, acc} = Macro.prewalk(ast, [], fn
      ...>   {:+, meta, children}, acc -> {{:*, meta, children}, [:+ | acc]}
      ...>   {:*, meta, children}, acc -> {{:+, meta, children}, [:* | acc]}
      ...>   other, acc -> {other, acc}
      ...> end)
      iex> {{:*, _, [5, {:+, _, [3, 7]}]}, [:*, :+]} = {new_ast, acc}
      iex> Code.eval_quoted(ast)
      {26, []}
      iex> Code.eval_quoted(new_ast)
      {50, []}

  """
  @spec prewalk(t, any, (t, any -> {t, any})) :: {t, any}
  def prewalk(ast, acc, fun) when is_function(fun, 2) do
    traverse(ast, acc, fun, fn x, a -> {x, a} end)
  end

  @doc """
  This function behaves like `prewalk/2`, but performs a depth-first,
  post-order traversal of quoted expressions.
  """
  @spec postwalk(t, (t -> t)) :: t
  def postwalk(ast, fun) when is_function(fun, 1) do
    elem(postwalk(ast, nil, fn x, nil -> {fun.(x), nil} end), 0)
  end

  @doc """
  This functions behaves like `prewalk/3`, but performs a depth-first,
  post-order traversal of quoted expressions using an accumulator.
  """
  @spec postwalk(t, any, (t, any -> {t, any})) :: {t, any}
  def postwalk(ast, acc, fun) when is_function(fun, 2) do
    traverse(ast, acc, fn x, a -> {x, a} end, fun)
  end

  @doc """
  Decomposes a local or remote call into its remote part (when provided),
  function name and argument list.

  Returns `:error` when an invalid call syntax is provided.

  ## Examples

      iex> Macro.decompose_call(quote(do: foo))
      {:foo, []}

      iex> Macro.decompose_call(quote(do: foo()))
      {:foo, []}

      iex> Macro.decompose_call(quote(do: foo(1, 2, 3)))
      {:foo, [1, 2, 3]}

      iex> Macro.decompose_call(quote(do: Elixir.M.foo(1, 2, 3)))
      {{:__aliases__, [], [:Elixir, :M]}, :foo, [1, 2, 3]}

      iex> Macro.decompose_call(quote(do: 42))
      :error

      iex> Macro.decompose_call(quote(do: {:foo, [], []}))
      :error

  """
  @spec decompose_call(t()) :: {atom, [t()]} | {t(), atom, [t()]} | :error
  def decompose_call(ast)

  def decompose_call({:{}, _, args}) when is_list(args), do: :error

  def decompose_call({{:., _, [remote, function]}, _, args})
      when is_tuple(remote) or is_atom(remote),
      do: {remote, function, args}

  def decompose_call({name, _, args}) when is_atom(name) and is_atom(args), do: {name, []}

  def decompose_call({name, _, args}) when is_atom(name) and is_list(args), do: {name, args}

  def decompose_call(_), do: :error

  @doc """
  Recursively escapes a value so it can be inserted into a syntax tree.

  ## Examples

      iex> Macro.escape(:foo)
      :foo

      iex> Macro.escape({:a, :b, :c})
      {:{}, [], [:a, :b, :c]}

      iex> Macro.escape({:unquote, [], [1]}, unquote: true)
      1

  ## Options

    * `:unquote` - when true, this function leaves `unquote/1` and
      `unquote_splicing/1` statements unescaped, effectively unquoting
      the contents on escape. This option is useful only when escaping
      ASTs which may have quoted fragments in them. Defaults to false.

    * `:prune_metadata` - when true, removes metadata from escaped AST
      nodes. Note this option changes the semantics of escaped code and
      it should only be used when escaping ASTs. Defaults to false.

      As an example, `ExUnit` stores the AST of every assertion, so when
      an assertion fails we can show code snippets to users. Without this
      option, each time the test module is compiled, we get a different
      MD5 of the module bytecode, because the AST contains metadata,
      such as counters, specific to the compilation environment. By pruning
      the metadata, we ensure that the module is deterministic and reduce
      the amount of data `ExUnit` needs to keep around. Only the minimal
      amount of metadata is kept, such as `:line` and `:no_parens`.

  ## Comparison to `quote/2`

  The `escape/2` function is sometimes confused with `quote/2`,
  because the above examples behave the same with both. The key difference is
  best illustrated when the value to escape is stored in a variable.

      iex> Macro.escape({:a, :b, :c})
      {:{}, [], [:a, :b, :c]}
      iex> quote do: {:a, :b, :c}
      {:{}, [], [:a, :b, :c]}

      iex> value = {:a, :b, :c}
      iex> Macro.escape(value)
      {:{}, [], [:a, :b, :c]}

      iex> quote do: value
      {:value, [], __MODULE__}

      iex> value = {:a, :b, :c}
      iex> quote do: unquote(value)
      {:a, :b, :c}

  `escape/2` is used to escape *values* (either directly passed or variable
  bound), while `quote/2` produces syntax trees for
  expressions.
  """
  @spec escape(term, keyword) :: t()
  def escape(expr, opts \\ []) do
    unquote = Keyword.get(opts, :unquote, false)
    kind = if Keyword.get(opts, :prune_metadata, false), do: :prune_metadata, else: :none
    :elixir_quote.escape(expr, kind, unquote)
  end

  @doc """
  Expands the struct given by `module` in the given `env`.

  This is useful when a struct needs to be expanded at
  compilation time and the struct being expanded may or may
  not have been compiled. This function is also capable of
  expanding structs defined under the module being compiled.

  It will raise `CompileError` if the struct is not available.
  From Elixir v1.12, calling this function also adds an export
  dependency on the given struct.
  """
  @doc since: "1.8.0"
  @spec struct!(module, Macro.Env.t()) ::
          %{required(:__struct__) => module, optional(atom) => any}
        when module: module()
  def struct!(module, env) when is_atom(module) do
    if module == env.module do
      Module.get_attribute(module, :__struct__)
    end ||
      case :elixir_map.maybe_load_struct([line: env.line], module, [], [], env) do
        {:ok, struct} -> struct
        {:error, desc} -> raise ArgumentError, List.to_string(:elixir_map.format_error(desc))
      end
  end

  @doc """
  Validates the given expressions are valid quoted expressions.

  Check the type `t:Macro.t/0` for a complete specification of a
  valid quoted expression.

  It returns `:ok` if the expression is valid. Otherwise it returns
  a tuple in the form of `{:error, remainder}` where `remainder` is
  the invalid part of the quoted expression.

  ## Examples

      iex> Macro.validate({:two_element, :tuple})
      :ok
      iex> Macro.validate({:three, :element, :tuple})
      {:error, {:three, :element, :tuple}}

      iex> Macro.validate([1, 2, 3])
      :ok
      iex> Macro.validate([1, 2, 3, {4}])
      {:error, {4}}

  """
  @spec validate(term) :: :ok | {:error, term}
  def validate(expr) do
    find_invalid(expr) || :ok
  end

  defp find_invalid({left, right}), do: find_invalid(left) || find_invalid(right)

  defp find_invalid({left, meta, right})
       when is_list(meta) and (is_atom(right) or is_list(right)),
       do: find_invalid(left) || find_invalid(right)

  defp find_invalid(list) when is_list(list), do: Enum.find_value(list, &find_invalid/1)

  defp find_invalid(pid) when is_pid(pid), do: nil
  defp find_invalid(atom) when is_atom(atom), do: nil
  defp find_invalid(num) when is_number(num), do: nil
  defp find_invalid(bin) when is_binary(bin), do: nil

  defp find_invalid(fun) when is_function(fun) do
    unless Function.info(fun, :env) == {:env, []} and
             Function.info(fun, :type) == {:type, :external} do
      {:error, fun}
    end
  end

  defp find_invalid(other), do: {:error, other}

  @doc """
  Returns an enumerable that traverses the  `ast` in depth-first,
  pre-order traversal.

  ## Examples

      iex> ast = quote do: foo(1, "abc")
      iex> Enum.map(Macro.prewalker(ast), & &1)
      [{:foo, [], [1, "abc"]}, 1, "abc"]

  """
  @doc since: "1.13.0"
  @spec prewalker(t()) :: Enumerable.t()
  def prewalker(ast) do
    &prewalker([ast], &1, &2)
  end

  defp prewalker(_buffer, {:halt, acc}, _fun) do
    {:halted, acc}
  end

  defp prewalker(buffer, {:suspend, acc}, fun) do
    {:suspended, acc, &prewalker(buffer, &1, fun)}
  end

  defp prewalker([], {:cont, acc}, _fun) do
    {:done, acc}
  end

  defp prewalker([{left, right} = node | tail], {:cont, acc}, fun) do
    prewalker([left, right | tail], fun.(node, acc), fun)
  end

  defp prewalker([{left, meta, right} = node | tail], {:cont, acc}, fun)
       when is_atom(left) and is_list(meta) do
    if is_atom(right) do
      prewalker(tail, fun.(node, acc), fun)
    else
      prewalker(right ++ tail, fun.(node, acc), fun)
    end
  end

  defp prewalker([{left, meta, right} = node | tail], {:cont, acc}, fun) when is_list(meta) do
    if is_atom(right) do
      prewalker([left | tail], fun.(node, acc), fun)
    else
      prewalker([left | right] ++ tail, fun.(node, acc), fun)
    end
  end

  defp prewalker([list | tail], {:cont, acc}, fun) when is_list(list) do
    prewalker(list ++ tail, fun.(list, acc), fun)
  end

  defp prewalker([head | tail], {:cont, acc}, fun) do
    prewalker(tail, fun.(head, acc), fun)
  end

  @doc """
  Returns an enumerable that traverses the  `ast` in depth-first,
  post-order traversal.

  ## Examples

      iex> ast = quote do: foo(1, "abc")
      iex> Enum.map(Macro.postwalker(ast), & &1)
      [1, "abc", {:foo, [], [1, "abc"]}]

  """
  @doc since: "1.13.0"
  @spec postwalker(t()) :: Enumerable.t()
  def postwalker(ast) do
    &postwalker([ast], make_ref(), &1, &2)
  end

  defp postwalker(_buffer, _ref, {:halt, acc}, _fun) do
    {:halted, acc}
  end

  defp postwalker(buffer, ref, {:suspend, acc}, fun) do
    {:suspended, acc, &postwalker(buffer, ref, &1, fun)}
  end

  defp postwalker([], _ref, {:cont, acc}, _fun) do
    {:done, acc}
  end

  defp postwalker([{ref, head} | tail], ref, {:cont, acc}, fun) do
    postwalker(tail, ref, fun.(head, acc), fun)
  end

  defp postwalker([{left, right} = node | tail], ref, {:cont, acc}, fun) do
    postwalker([right, {ref, node} | tail], ref, fun.(left, acc), fun)
  end

  defp postwalker([{left, meta, right} = node | tail], ref, {:cont, acc}, fun)
       when is_atom(left) and is_list(meta) do
    if is_atom(right) do
      postwalker(tail, ref, fun.(node, acc), fun)
    else
      postwalker(right ++ [{ref, node} | tail], ref, {:cont, acc}, fun)
    end
  end

  defp postwalker([{left, meta, right} = node | tail], ref, cont_acc, fun)
       when is_list(meta) do
    if is_atom(right) do
      postwalker([left, {ref, node} | tail], ref, cont_acc, fun)
    else
      postwalker([left | right] ++ [{ref, node} | tail], ref, cont_acc, fun)
    end
  end

  defp postwalker([list | tail], ref, cont_acc, fun) when is_list(list) do
    postwalker(list ++ [{ref, list} | tail], ref, cont_acc, fun)
  end

  defp postwalker([head | tail], ref, {:cont, acc}, fun) do
    postwalker(tail, ref, fun.(head, acc), fun)
  end

  @doc ~S"""
  Unescapes characters in a string.

  This is the unescaping behaviour used by default in Elixir
  single- and double-quoted strings. Check `unescape_string/2`
  for information on how to customize the escaping map.

  In this setup, Elixir will escape the following: `\0`, `\a`, `\b`,
  `\d`, `\e`, `\f`, `\n`, `\r`, `\s`, `\t` and `\v`. Bytes can be
  given as hexadecimals via `\xNN` and Unicode code points as
  `\uNNNN` escapes.

  This function is commonly used on sigil implementations
  (like `~r`, `~s` and others), which receive a raw, unescaped
  string, and it can be used anywhere that needs to mimic how
  Elixir parses strings.

  ## Examples

      iex> Macro.unescape_string("example\\n")
      "example\n"

  In the example above, we pass a string with `\n` escaped
  and return a version with it unescaped.
  """
  @spec unescape_string(String.t()) :: String.t()
  def unescape_string(string) do
    :elixir_interpolation.unescape_string(string)
  end

  @doc ~S"""
  Unescapes characters in a string according to the given mapping.

  Check `unescape_string/1` if you want to use the same mapping
  as Elixir single- and double-quoted strings.

  ## Mapping function

  The mapping function receives an integer representing the code point
  of the character it wants to unescape. There are also the special atoms
  `:newline`, `:unicode`, and `:hex`, which control newline, unicode,
  and escaping respectively.

  Here is the default mapping function implemented by Elixir:

      def unescape_map(:newline), do: true
      def unescape_map(:unicode), do: true
      def unescape_map(:hex), do: true
      def unescape_map(?0), do: ?0
      def unescape_map(?a), do: ?\a
      def unescape_map(?b), do: ?\b
      def unescape_map(?d), do: ?\d
      def unescape_map(?e), do: ?\e
      def unescape_map(?f), do: ?\f
      def unescape_map(?n), do: ?\n
      def unescape_map(?r), do: ?\r
      def unescape_map(?s), do: ?\s
      def unescape_map(?t), do: ?\t
      def unescape_map(?v), do: ?\v
      def unescape_map(e), do: e

  If the `unescape_map/1` function returns `false`, the char is
  not escaped and the backslash is kept in the string.

  ## Examples

  Using the `unescape_map/1` function defined above is easy:

      Macro.unescape_string("example\\n", &unescape_map(&1))

  """
  @spec unescape_string(String.t(), (non_neg_integer -> non_neg_integer | false)) :: String.t()
  def unescape_string(string, map) do
    :elixir_interpolation.unescape_string(string, map)
  end

  @doc false
  @deprecated "Traverse over the arguments using Enum.map/2 instead"
  def unescape_tokens(tokens) do
    for token <- tokens do
      if is_binary(token), do: unescape_string(token), else: token
    end
  end

  @doc false
  @deprecated "Traverse over the arguments using Enum.map/2 instead"
  def unescape_tokens(tokens, map) do
    for token <- tokens do
      if is_binary(token), do: unescape_string(token, map), else: token
    end
  end

  @doc """
  Converts the given expression AST to a string.

  This is a convenience function for converting AST into
  a string, which discards all formatting of the original
  code and wraps newlines around 98 characters. See
  `Code.quoted_to_algebra/2` as a lower level function
  with more control around formatting.

  ## Examples

      iex> Macro.to_string(quote(do: foo.bar(1, 2, 3)))
      "foo.bar(1, 2, 3)"

  """
  @spec to_string(t()) :: String.t()
  # TODO: Allow line_length to be configurable on v1.17
  def to_string(tree) do
    doc = Inspect.Algebra.format(Code.quoted_to_algebra(tree), 98)
    IO.iodata_to_binary(doc)
  end

  @doc """
  Converts the given expression AST to a string.

  The given `fun` is called for every node in the AST with two arguments: the
  AST of the node being printed and the string representation of that same
  node. The return value of this function is used as the final string
  representation for that AST node.

  This function discards all formatting of the original code.

  ## Examples

      Macro.to_string(quote(do: 1 + 2), fn
        1, _string -> "one"
        2, _string -> "two"
        _ast, string -> string
      end)
      #=> "one + two"

  """
  @deprecated "Use Macro.to_string/1 instead"
  @spec to_string(t(), (t(), String.t() -> String.t())) :: String.t()
  def to_string(tree, fun)

  # Variables
  def to_string({var, _, context} = ast, fun) when is_atom(var) and is_atom(context) do
    fun.(ast, Atom.to_string(var))
  end

  # Aliases
  def to_string({:__aliases__, _, refs} = ast, fun) do
    fun.(ast, Enum.map_join(refs, ".", &call_to_string(&1, fun)))
  end

  # Blocks
  def to_string({:__block__, _, [expr]} = ast, fun) do
    fun.(ast, to_string(expr, fun))
  end

  def to_string({:__block__, _, _} = ast, fun) do
    block = adjust_new_lines(block_to_string(ast, fun), "\n  ")
    fun.(ast, "(\n  " <> block <> "\n)")
  end

  # Bits containers
  def to_string({:<<>>, _, parts} = ast, fun) do
    if interpolated?(ast) do
      fun.(ast, interpolate(ast, fun))
    else
      result =
        Enum.map_join(parts, ", ", fn part ->
          str = bitpart_to_string(part, fun)

          if :binary.first(str) == ?< or :binary.last(str) == ?> do
            "(" <> str <> ")"
          else
            str
          end
        end)

      fun.(ast, "<<" <> result <> ">>")
    end
  end

  # Tuple containers
  def to_string({:{}, _, args} = ast, fun) do
    tuple = "{" <> Enum.map_join(args, ", ", &to_string(&1, fun)) <> "}"
    fun.(ast, tuple)
  end

  # Map containers
  def to_string({:%{}, _, args} = ast, fun) do
    map = "%{" <> map_to_string(args, fun) <> "}"
    fun.(ast, map)
  end

  def to_string({:%, _, [struct_name, map]} = ast, fun) do
    {:%{}, _, args} = map
    struct = "%" <> to_string(struct_name, fun) <> "{" <> map_to_string(args, fun) <> "}"
    fun.(ast, struct)
  end

  # Fn keyword
  def to_string({:fn, _, [{:->, _, [_, tuple]}] = arrow} = ast, fun)
      when not is_tuple(tuple) or elem(tuple, 0) != :__block__ do
    fun.(ast, "fn " <> arrow_to_string(arrow, fun) <> " end")
  end

  def to_string({:fn, _, [{:->, _, _}] = block} = ast, fun) do
    fun.(ast, "fn " <> block_to_string(block, fun) <> "\nend")
  end

  def to_string({:fn, _, block} = ast, fun) do
    block = adjust_new_lines(block_to_string(block, fun), "\n  ")
    fun.(ast, "fn\n  " <> block <> "\nend")
  end

  # left -> right
  def to_string([{:->, _, _} | _] = ast, fun) do
    fun.(ast, "(" <> arrow_to_string(ast, fun, true) <> ")")
  end

  # left when right
  def to_string({:when, _, [left, right]} = ast, fun) do
    right =
      if right != [] and Keyword.keyword?(right) do
        kw_list_to_string(right, fun)
      else
        fun.(ast, op_to_string(right, fun, :when, :right))
      end

    fun.(ast, op_to_string(left, fun, :when, :left) <> " when " <> right)
  end

  # Splat when
  def to_string({:when, _, args} = ast, fun) do
    {left, right} = split_last(args)

    result =
      "(" <> Enum.map_join(left, ", ", &to_string(&1, fun)) <> ") when " <> to_string(right, fun)

    fun.(ast, result)
  end

  # Capture
  def to_string({:&, _, [{:/, _, [{name, _, ctx}, arity]}]} = ast, fun)
      when is_atom(name) and is_atom(ctx) and is_integer(arity) do
    result = "&" <> Atom.to_string(name) <> "/" <> to_string(arity, fun)
    fun.(ast, result)
  end

  def to_string({:&, _, [{:/, _, [{{:., _, [mod, name]}, _, []}, arity]}]} = ast, fun)
      when is_atom(name) and is_integer(arity) do
    result =
      "&" <> to_string(mod, fun) <> "." <> Atom.to_string(name) <> "/" <> to_string(arity, fun)

    fun.(ast, result)
  end

  def to_string({:&, _, [arg]} = ast, fun) when not is_integer(arg) do
    fun.(ast, "&(" <> to_string(arg, fun) <> ")")
  end

  # left not in right
  def to_string({:not, _, [{:in, _, [left, right]}]} = ast, fun) do
    fun.(ast, to_string(left, fun) <> " not in " <> to_string(right, fun))
  end

  # Access
  def to_string({{:., _, [Access, :get]}, _, [left, right]} = ast, fun) do
    if op_expr?(left) do
      fun.(ast, "(" <> to_string(left, fun) <> ")" <> to_string([right], fun))
    else
      fun.(ast, to_string(left, fun) <> to_string([right], fun))
    end
  end

  # foo.{bar, baz}
  def to_string({{:., _, [left, :{}]}, _, args} = ast, fun) do
    fun.(ast, to_string(left, fun) <> ".{" <> args_to_string(args, fun) <> "}")
  end

  # All other calls
  def to_string({{:., _, [left, _]} = target, meta, []} = ast, fun) do
    to_string = call_to_string(target, fun)

    if is_tuple(left) && meta[:no_parens] do
      fun.(ast, to_string)
    else
      fun.(ast, to_string <> "()")
    end
  end

  def to_string({target, _, args} = ast, fun) when is_list(args) do
    with :error <- unary_call(ast, fun),
         :error <- op_call(ast, fun),
         :error <- sigil_call(ast, fun) do
      {list, last} = split_last(args)

      result =
        if kw_blocks?(last) do
          case list do
            [] -> call_to_string(target, fun) <> kw_blocks_to_string(last, fun)
            _ -> call_to_string_with_args(target, list, fun) <> kw_blocks_to_string(last, fun)
          end
        else
          call_to_string_with_args(target, args, fun)
        end

      fun.(ast, result)
    else
      {:ok, value} -> value
    end
  end

  # Two-element tuples
  def to_string({left, right}, fun) do
    to_string({:{}, [], [left, right]}, fun)
  end

  # Lists
  def to_string(list, fun) when is_list(list) do
    result =
      cond do
        list == [] ->
          "[]"

        :io_lib.printable_list(list) ->
          {escaped, _} = Identifier.escape(IO.chardata_to_string(list), ?")
          IO.iodata_to_binary([?~, ?c, ?", escaped, ?"])

        Inspect.List.keyword?(list) ->
          "[" <> kw_list_to_string(list, fun) <> "]"

        true ->
          "[" <> Enum.map_join(list, ", ", &to_string(&1, fun)) <> "]"
      end

    fun.(list, result)
  end

  # All other structures
  def to_string(other, fun) do
    fun.(other, inspect_no_limit(other))
  end

  defp inspect_no_limit(value) do
    Kernel.inspect(value, limit: :infinity, printable_limit: :infinity)
  end

  defp bitpart_to_string({:"::", meta, [left, right]} = ast, fun) do
    result =
      if meta[:inferred_bitstring_spec] do
        to_string(left, fun)
      else
        op_to_string(left, fun, :"::", :left) <>
          "::" <> bitmods_to_string(right, fun, :"::", :right)
      end

    fun.(ast, result)
  end

  defp bitpart_to_string(ast, fun) do
    to_string(ast, fun)
  end

  defp bitmods_to_string({op, _, [left, right]} = ast, fun, _, _) when op in [:*, :-] do
    result =
      bitmods_to_string(left, fun, op, :left) <>
        Atom.to_string(op) <> bitmods_to_string(right, fun, op, :right)

    fun.(ast, result)
  end

  defp bitmods_to_string(other, fun, parent_op, side) do
    op_to_string(other, fun, parent_op, side)
  end

  # Block keywords
  kw_keywords = [:do, :rescue, :catch, :else, :after]

  defp kw_blocks?([{:do, _} | _] = kw) do
    Enum.all?(kw, &match?({x, _} when x in unquote(kw_keywords), &1))
  end

  defp kw_blocks?(_), do: false

  # Check if we have an interpolated string.
  defp interpolated?({:<<>>, _, [_ | _] = parts}) do
    Enum.all?(parts, fn
      {:"::", _, [{{:., _, [Kernel, :to_string]}, _, [_]}, {:binary, _, _}]} -> true
      binary when is_binary(binary) -> true
      _ -> false
    end)
  end

  defp interpolated?(_) do
    false
  end

  defp interpolate(ast, fun), do: interpolate(ast, "\"", "\"", fun)

  defp interpolate({:<<>>, _, [parts]}, left, right, _) when left in [~s["""\n], ~s['''\n]] do
    <<left::binary, parts::binary, right::binary>>
  end

  defp interpolate({:<<>>, _, parts}, left, right, fun) do
    parts =
      Enum.map_join(parts, "", fn
        {:"::", _, [{{:., _, [Kernel, :to_string]}, _, [arg]}, {:binary, _, _}]} ->
          "\#{" <> to_string(arg, fun) <> "}"

        binary when is_binary(binary) ->
          escape_sigil(binary, left)
      end)

    <<left::binary, parts::binary, right::binary>>
  end

  defp escape_sigil(parts, "("), do: String.replace(parts, ")", ~S"\)")
  defp escape_sigil(parts, "{"), do: String.replace(parts, "}", ~S"\}")
  defp escape_sigil(parts, "["), do: String.replace(parts, "]", ~S"\]")
  defp escape_sigil(parts, "<"), do: String.replace(parts, ">", ~S"\>")
  defp escape_sigil(parts, delimiter), do: String.replace(parts, delimiter, "\\#{delimiter}")

  defp module_to_string(atom, _fun) when is_atom(atom) do
    inspect_no_limit(atom)
  end

  defp module_to_string({:&, _, [val]} = expr, fun) when not is_integer(val) do
    "(" <> to_string(expr, fun) <> ")"
  end

  defp module_to_string({:fn, _, _} = expr, fun) do
    "(" <> to_string(expr, fun) <> ")"
  end

  defp module_to_string({_, _, [_ | _] = args} = expr, fun) do
    if kw_blocks?(List.last(args)) do
      "(" <> to_string(expr, fun) <> ")"
    else
      to_string(expr, fun)
    end
  end

  defp module_to_string(expr, fun) do
    to_string(expr, fun)
  end

  defp unary_call({op, _, [arg]} = ast, fun) when is_atom(op) do
    if operator?(op, 1) do
      if op == :not or op_expr?(arg) do
        {:ok, fun.(ast, Atom.to_string(op) <> "(" <> to_string(arg, fun) <> ")")}
      else
        {:ok, fun.(ast, Atom.to_string(op) <> to_string(arg, fun))}
      end
    else
      :error
    end
  end

  defp unary_call(_, _) do
    :error
  end

  defp op_call({:"..//", _, [left, middle, right]} = ast, fun) do
    left = op_to_string(left, fun, :.., :left)
    middle = op_to_string(middle, fun, :.., :right)
    right = op_to_string(right, fun, :"//", :right)
    {:ok, fun.(ast, left <> ".." <> middle <> "//" <> right)}
  end

  defp op_call({op, _, [left, right]} = ast, fun) when is_atom(op) do
    if operator?(op, 2) do
      left = op_to_string(left, fun, op, :left)
      right = op_to_string(right, fun, op, :right)
      op = if op in [:..], do: "#{op}", else: " #{op} "
      {:ok, fun.(ast, left <> op <> right)}
    else
      :error
    end
  end

  defp op_call(_, _) do
    :error
  end

  defp sigil_call({sigil, meta, [{:<<>>, _, _} = parts, args]} = ast, fun)
       when is_atom(sigil) and is_list(args) do
    delimiter = Keyword.get(meta, :delimiter, "\"")
    {left, right} = delimiter_pair(delimiter)

    case Atom.to_string(sigil) do
      <<"sigil_", name>> when name >= ?A and name <= ?Z ->
        args = sigil_args(args, fun)
        {:<<>>, _, [binary]} = parts
        formatted = <<?~, name, left::binary, binary::binary, right::binary, args::binary>>
        {:ok, fun.(ast, formatted)}

      <<"sigil_", name>> when name >= ?a and name <= ?z ->
        args = sigil_args(args, fun)
        formatted = "~" <> <<name>> <> interpolate(parts, left, right, fun) <> args
        {:ok, fun.(ast, formatted)}

      _ ->
        :error
    end
  end

  defp sigil_call(_other, _fun) do
    :error
  end

  defp delimiter_pair("["), do: {"[", "]"}
  defp delimiter_pair("{"), do: {"{", "}"}
  defp delimiter_pair("("), do: {"(", ")"}
  defp delimiter_pair("<"), do: {"<", ">"}
  defp delimiter_pair("\"\"\""), do: {"\"\"\"\n", "\"\"\""}
  defp delimiter_pair("'''"), do: {"'''\n", "'''"}
  defp delimiter_pair(str), do: {str, str}

  defp sigil_args([], _fun), do: ""
  defp sigil_args(args, fun), do: fun.(args, List.to_string(args))

  defp op_expr?(expr) do
    case expr do
      {op, _, [_, _]} -> operator?(op, 2)
      {op, _, [_]} -> operator?(op, 1)
      _ -> false
    end
  end

  defp call_to_string(atom, _fun) when is_atom(atom), do: Atom.to_string(atom)
  defp call_to_string({:., _, [arg]}, fun), do: module_to_string(arg, fun) <> "."

  defp call_to_string({:., _, [left, right]}, fun) when is_atom(right),
    do: module_to_string(left, fun) <> "." <> call_to_string_for_atom(right)

  defp call_to_string({:., _, [left, right]}, fun),
    do: module_to_string(left, fun) <> "." <> call_to_string(right, fun)

  defp call_to_string(other, fun), do: to_string(other, fun)

  defp call_to_string_with_args(target, args, fun) do
    target = call_to_string(target, fun)
    args = args_to_string(args, fun)
    target <> "(" <> args <> ")"
  end

  defp call_to_string_for_atom(atom) do
    Macro.inspect_atom(:remote_call, atom)
  end

  defp args_to_string(args, fun) do
    {list, last} = split_last(args)

    if last != [] and Inspect.List.keyword?(last) do
      prefix =
        case list do
          [] -> ""
          _ -> Enum.map_join(list, ", ", &to_string(&1, fun)) <> ", "
        end

      prefix <> kw_list_to_string(last, fun)
    else
      Enum.map_join(args, ", ", &to_string(&1, fun))
    end
  end

  defp kw_blocks_to_string(kw, fun) do
    Enum.reduce(unquote(kw_keywords), " ", fn x, acc ->
      case Keyword.has_key?(kw, x) do
        true -> acc <> kw_block_to_string(x, Keyword.get(kw, x), fun)
        false -> acc
      end
    end) <> "end"
  end

  defp kw_block_to_string(key, value, fun) do
    block = adjust_new_lines(block_to_string(value, fun), "\n  ")
    Atom.to_string(key) <> "\n  " <> block <> "\n"
  end

  defp block_to_string([{:->, _, _} | _] = block, fun) do
    Enum.map_join(block, "\n", fn {:->, _, [left, right]} ->
      left = comma_join_or_empty_paren(left, fun, false)
      left <> "->\n  " <> adjust_new_lines(block_to_string(right, fun), "\n  ")
    end)
  end

  defp block_to_string({:__block__, _, exprs}, fun) do
    Enum.map_join(exprs, "\n", &to_string(&1, fun))
  end

  defp block_to_string(other, fun), do: to_string(other, fun)

  defp map_to_string([{:|, _, [update_map, update_args]}], fun) do
    to_string(update_map, fun) <> " | " <> map_to_string(update_args, fun)
  end

  defp map_to_string(list, fun) do
    cond do
      Inspect.List.keyword?(list) -> kw_list_to_string(list, fun)
      true -> map_list_to_string(list, fun)
    end
  end

  defp kw_list_to_string(list, fun) do
    Enum.map_join(list, ", ", fn {key, value} ->
      Macro.inspect_atom(:key, key) <> " " <> to_string(value, fun)
    end)
  end

  defp map_list_to_string(list, fun) do
    Enum.map_join(list, ", ", fn
      {key, value} -> to_string(key, fun) <> " => " <> to_string(value, fun)
      other -> to_string(other, fun)
    end)
  end

  defp wrap_in_parenthesis(expr, fun) do
    "(" <> to_string(expr, fun) <> ")"
  end

  defp op_to_string({op, _, [_, _]} = expr, fun, parent_op, side) when is_atom(op) do
    case Identifier.binary_op(op) do
      {_, prec} ->
        {parent_assoc, parent_prec} = Identifier.binary_op(parent_op)

        cond do
          parent_prec < prec -> to_string(expr, fun)
          parent_prec > prec -> wrap_in_parenthesis(expr, fun)
          parent_assoc == side -> to_string(expr, fun)
          true -> wrap_in_parenthesis(expr, fun)
        end

      :error ->
        to_string(expr, fun)
    end
  end

  defp op_to_string(expr, fun, _, _), do: to_string(expr, fun)

  defp arrow_to_string(pairs, fun, paren \\ false) do
    Enum.map_join(pairs, "; ", fn {:->, _, [left, right]} ->
      left = comma_join_or_empty_paren(left, fun, paren)
      left <> "-> " <> to_string(right, fun)
    end)
  end

  defp comma_join_or_empty_paren([], _fun, true), do: "() "
  defp comma_join_or_empty_paren([], _fun, false), do: ""

  defp comma_join_or_empty_paren(left, fun, _) do
    Enum.map_join(left, ", ", &to_string(&1, fun)) <> " "
  end

  defp split_last([]) do
    {[], []}
  end

  defp split_last(args) do
    {left, [right]} = Enum.split(args, -1)
    {left, right}
  end

  defp adjust_new_lines(block, replacement) do
    for <<x <- block>>, into: "" do
      case x == ?\n do
        true -> replacement
        false -> <<x>>
      end
    end
  end

  @doc """
  Receives an AST node and expands it once.

  The following contents are expanded:

    * Macros (local or remote)
    * Aliases are expanded (if possible) and return atoms
    * Compilation environment macros (`__CALLER__/0`, `__DIR__/0`, `__ENV__/0` and `__MODULE__/0`)
    * Module attributes reader (`@foo`)

  If the expression cannot be expanded, it returns the expression
  itself. This function does not traverse the AST, only the root
  node is expanded.

  `expand_once/2` performs the expansion just once. Check `expand/2`
  to perform expansion until the node can no longer be expanded.

  ## Examples

  In the example below, we have a macro that generates a module
  with a function named `name_length` that returns the length
  of the module name. The value of this function will be calculated
  at compilation time and not at runtime.

  Consider the implementation below:

      defmacro defmodule_with_length(name, do: block) do
        length = length(Atom.to_charlist(name))

        quote do
          defmodule unquote(name) do
            def name_length, do: unquote(length)
            unquote(block)
          end
        end
      end

  When invoked like this:

      defmodule_with_length My.Module do
        def other_function, do: ...
      end

  The compilation will fail because `My.Module` when quoted
  is not an atom, but a syntax tree as follows:

      {:__aliases__, [], [:My, :Module]}

  That said, we need to expand the aliases node above to an
  atom, so we can retrieve its length. Expanding the node is
  not straightforward because we also need to expand the
  caller aliases. For example:

      alias MyHelpers, as: My

      defmodule_with_length My.Module do
        def other_function, do: ...
      end

  The final module name will be `MyHelpers.Module` and not
  `My.Module`. With `Macro.expand/2`, such aliases are taken
  into consideration. Local and remote macros are also
  expanded. We could rewrite our macro above to use this
  function as:

      defmacro defmodule_with_length(name, do: block) do
        expanded = Macro.expand(name, __CALLER__)
        length = length(Atom.to_charlist(expanded))

        quote do
          defmodule unquote(name) do
            def name_length, do: unquote(length)
            unquote(block)
          end
        end
      end

  """
  @spec expand_once(input(), Macro.Env.t()) :: output()
  def expand_once(ast, env) do
    elem(do_expand_once(ast, env), 0)
  end

  defp do_expand_once({:__aliases__, meta, _} = original, env) do
    case :elixir_aliases.expand_or_concat(original, env) do
      receiver when is_atom(receiver) ->
        :elixir_env.trace({:alias_reference, meta, receiver}, env)
        {receiver, true}

      aliases ->
        aliases = :lists.map(&elem(do_expand_once(&1, env), 0), aliases)

        case :lists.all(&is_atom/1, aliases) do
          true ->
            receiver = :elixir_aliases.concat(aliases)
            :elixir_env.trace({:alias_reference, meta, receiver}, env)
            {receiver, true}

          false ->
            {original, false}
        end
    end
  end

  # Expand compilation environment macros
  defp do_expand_once({:__MODULE__, _, atom}, env) when is_atom(atom), do: {env.module, true}

  defp do_expand_once({:__DIR__, _, atom}, env) when is_atom(atom),
    do: {:filename.dirname(env.file), true}

  defp do_expand_once({:__ENV__, _, atom}, env) when is_atom(atom) do
    env = update_in(env.versioned_vars, &maybe_escape_map/1)
    {maybe_escape_map(env), true}
  end

  defp do_expand_once({{:., _, [{:__ENV__, _, atom}, field]}, _, []} = original, env)
       when is_atom(atom) and is_atom(field) do
    if Map.has_key?(env, field) do
      {maybe_escape_map(Map.get(env, field)), true}
    else
      {original, false}
    end
  end

  defp do_expand_once({atom, meta, context} = original, _env)
       when is_atom(atom) and is_list(meta) and is_atom(context) do
    {original, false}
  end

  defp do_expand_once({atom, meta, args} = original, env)
       when is_atom(atom) and is_list(args) and is_list(meta) do
    arity = length(args)

    if special_form?(atom, arity) do
      {original, false}
    else
      module = env.module

      extra =
        if function_exported?(module, :__info__, 1) do
          [{module, module.__info__(:macros)}]
        else
          []
        end

      s = :elixir_env.env_to_ex(env)

      expand =
        :elixir_dispatch.expand_import(meta, {atom, length(args)}, args, s, env, extra, true)

      case expand do
        {:ok, receiver, quoted} ->
          next = :elixir_module.next_counter(module)
          # We don't want the line to propagate yet, but generated might!
          meta = Keyword.take(meta, [:generated])
          {:elixir_quote.linify_with_context_counter(meta, {receiver, next}, quoted), true}

        {:ok, Kernel, op, [arg]} when op in [:+, :-] ->
          case expand_once(arg, env) do
            integer when is_integer(integer) -> {apply(Kernel, op, [integer]), true}
            _ -> {original, false}
          end

        {:ok, _receiver, _name, _args} ->
          {original, false}

        :error ->
          {original, false}
      end
    end
  end

  # Expand possible macro require invocation
  defp do_expand_once({{:., _, [left, right]}, meta, args} = original, env) when is_atom(right) do
    {receiver, _} = do_expand_once(left, env)

    case is_atom(receiver) do
      false ->
        {original, false}

      true ->
        s = :elixir_env.env_to_ex(env)
        name_arity = {right, length(args)}
        expand = :elixir_dispatch.expand_require(meta, receiver, name_arity, args, s, env)

        case expand do
          {:ok, receiver, quoted} ->
            next = :elixir_module.next_counter(env.module)
            # We don't want the line to propagate yet, but generated might!
            meta = Keyword.take(meta, [:generated])
            {:elixir_quote.linify_with_context_counter(meta, {receiver, next}, quoted), true}

          :error ->
            {original, false}
        end
    end
  end

  # Anything else is just returned
  defp do_expand_once(other, _env), do: {other, false}

  defp maybe_escape_map(map) when is_map(map), do: {:%{}, [], Map.to_list(map)}
  defp maybe_escape_map(other), do: other

  @doc """
  Returns `true` if the given name and arity is a special form.
  """
  @doc since: "1.7.0"
  @spec special_form?(name :: atom(), arity()) :: boolean()
  def special_form?(name, arity) when is_atom(name) and is_integer(arity) do
    :elixir_import.special_form(name, arity)
  end

  @doc """
  Returns `true` if the given name and arity is an operator.

  ## Examples

      iex> Macro.operator?(:not_an_operator, 3)
      false
      iex> Macro.operator?(:.., 0)
      true
      iex> Macro.operator?(:+, 1)
      true
      iex> Macro.operator?(:++, 2)
      true
      iex> Macro.operator?(:..//, 3)
      true

  """
  @doc since: "1.7.0"
  @spec operator?(name :: atom(), arity()) :: boolean()
  def operator?(name, arity)

  def operator?(:"..//", 3),
    do: true

  # Code.Identifier treats :// as a binary operator for precedence
  # purposes but it isn't really one, so we explicitly skip it.
  def operator?(name, 2) when is_atom(name),
    do: Identifier.binary_op(name) != :error and name != :"//"

  def operator?(name, 1) when is_atom(name),
    do: Identifier.unary_op(name) != :error

  def operator?(:.., 0),
    do: true

  def operator?(name, arity) when is_atom(name) and is_integer(arity), do: false

  @doc """
  Returns `true` if the given quoted expression represents a quoted literal.

  Atoms and numbers are always literals. Binaries, lists, tuples,
  maps, and structs are only literals if all of their terms are also literals.

  ## Examples

      iex> Macro.quoted_literal?(quote(do: "foo"))
      true
      iex> Macro.quoted_literal?(quote(do: {"foo", 1}))
      true
      iex> Macro.quoted_literal?(quote(do: {"foo", 1, :baz}))
      true
      iex> Macro.quoted_literal?(quote(do: %{foo: "bar"}))
      true
      iex> Macro.quoted_literal?(quote(do: %URI{path: "/"}))
      true
      iex> Macro.quoted_literal?(quote(do: URI.parse("/")))
      false
      iex> Macro.quoted_literal?(quote(do: {foo, var}))
      false

  """
  @doc since: "1.7.0"
  @spec quoted_literal?(t) :: boolean
  def quoted_literal?(term)

  def quoted_literal?({:__aliases__, _, args}),
    do: quoted_literal?(args)

  def quoted_literal?({:%, _, [left, right]}),
    do: quoted_literal?(left) and quoted_literal?(right)

  def quoted_literal?({:%{}, _, args}), do: quoted_literal?(args)
  def quoted_literal?({:{}, _, args}), do: quoted_literal?(args)
  def quoted_literal?({:__MODULE__, _, ctx}) when is_atom(ctx), do: true
  def quoted_literal?({:<<>>, _, segments}), do: Enum.all?(segments, &quoted_bitstring_segment?/1)
  def quoted_literal?({left, right}), do: quoted_literal?(left) and quoted_literal?(right)
  def quoted_literal?(list) when is_list(list), do: :lists.all(&quoted_literal?/1, list)
  def quoted_literal?(term), do: is_atom(term) or is_number(term) or is_binary(term)

  defp quoted_bitstring_segment?(term) when is_integer(term) or is_binary(term), do: true

  defp quoted_bitstring_segment?({:"::", _, [term, modifier]})
       when is_integer(term) or is_binary(term),
       do: quoted_bitstring_modifier?(modifier)

  defp quoted_bitstring_segment?(_other), do: false

  defp quoted_bitstring_modifier?({:-, _, [left, right]}),
    do: quoted_bitstring_modifier?(left) and quoted_bitstring_modifier?(right)

  defp quoted_bitstring_modifier?({atom, _, [size]})
       when atom in [:size, :unit] and is_integer(size),
       do: true

  defp quoted_bitstring_modifier?({:*, _, [left, right]})
       when is_integer(left) and is_integer(right),
       do: true

  defp quoted_bitstring_modifier?({modifier, _, ctx}) when is_atom(ctx) or ctx == [],
    do: :elixir_bitstring.validate_spec(modifier, nil) != :none

  defp quoted_bitstring_modifier?(_other), do: false

  @doc false
  @deprecated "Use Macro.expand_literals/2 instead"
  def expand_literal(ast, env) do
    expand_literals(ast, env)
  end

  @doc """
  Expands all literals in `ast` with the given `env`.

  This function is mostly used to remove compile-time dependencies
  from AST nodes. In such cases, the given environment is usually
  manipulated to represent a function:

      Macro.expand_literals(ast, %{env | function: {:my_code, 1}})

  At the moment, the only expandable literal nodes in an AST are
  aliases, so this function only expands aliases (and it does so
  anywhere in a literal).

  However, be careful when removing compile-time dependencies between
  modules. If you remove them but you still invoke the module at
  compile-time, Elixir will be unable to properly recompile modules
  when they change.
  """
  @doc since: "1.14.1"
  @spec expand_literals(input(), Macro.Env.t()) :: output()
  def expand_literals(ast, env) do
    {ast, :ok} = expand_literals(ast, :ok, fn node, :ok -> {expand(node, env), :ok} end)
    ast
  end

  @doc """
  Expands all literals in `ast` with the given `acc` and `fun`.

  `fun` will be invoked with an expandable AST node and `acc` and
  must return a new node with `acc`. This is a general version of
  `expand_literals/2` which supports a custom expansion function.
  Please check `expand_literals/2` for use cases and pitfalls.
  """
  @doc since: "1.14.1"
  @spec expand_literals(t(), acc, (t(), acc -> {t(), acc})) :: t() when acc: term()
  def expand_literals(ast, acc, fun)

  def expand_literals({:__aliases__, meta, args}, acc, fun) do
    {args, acc} = expand_literals(args, acc, fun)

    if :lists.all(&is_atom/1, args) do
      fun.({:__aliases__, meta, args}, acc)
    else
      {{:__aliases__, meta, args}, acc}
    end
  end

  def expand_literals({:__MODULE__, _meta, ctx} = node, acc, fun) when is_atom(ctx) do
    fun.(node, acc)
  end

  def expand_literals({:%, meta, [left, right]}, acc, fun) do
    {left, acc} = expand_literals(left, acc, fun)
    {right, acc} = expand_literals(right, acc, fun)
    {{:%, meta, [left, right]}, acc}
  end

  def expand_literals({:%{}, meta, args}, acc, fun) do
    {args, acc} = expand_literals(args, acc, fun)
    {{:%{}, meta, args}, acc}
  end

  def expand_literals({:{}, meta, args}, acc, fun) do
    {args, acc} = expand_literals(args, acc, fun)
    {{:{}, meta, args}, acc}
  end

  def expand_literals({left, right}, acc, fun) do
    {left, acc} = expand_literals(left, acc, fun)
    {right, acc} = expand_literals(right, acc, fun)
    {{left, right}, acc}
  end

  def expand_literals(list, acc, fun) when is_list(list) do
    :lists.mapfoldl(&expand_literals(&1, &2, fun), acc, list)
  end

  def expand_literals(
        {{:., _, [{:__aliases__, _, [:Application]}, :compile_env]} = node, meta,
         [app, key, default]},
        acc,
        fun
      ) do
    {default, acc} = expand_literals(default, acc, fun)
    {{node, meta, [app, key, default]}, acc}
  end

  def expand_literals(term, acc, _fun), do: {term, acc}

  @doc """
  Receives an AST node and expands it until it can no longer
  be expanded.

  Note this function does not traverse the AST, only the root
  node is expanded.

  This function uses `expand_once/2` under the hood. Check
  it out for more information and examples.
  """
  @spec expand(input(), Macro.Env.t()) :: output()
  def expand(ast, env) do
    expand_until({ast, true}, env)
  end

  defp expand_until({ast, true}, env) do
    expand_until(do_expand_once(ast, env), env)
  end

  defp expand_until({ast, false}, _env) do
    ast
  end

  @doc """
  Converts the given argument to a string with the underscore-slash format.

  The argument must either be an atom or a string.
  If an atom is given, it is assumed to be an Elixir module,
  so it is converted to a string and then processed.

  This function was designed to format language identifiers/tokens with the underscore-slash format,
  that's why it belongs to the `Macro` module. Do not use it as a general
  mechanism for underscoring strings as it does not support Unicode or
  characters that are not valid in Elixir identifiers.

  ## Examples

      iex> Macro.underscore("FooBar")
      "foo_bar"

      iex> Macro.underscore("Foo.Bar")
      "foo/bar"

      iex> Macro.underscore(Foo.Bar)
      "foo/bar"

  In general, `underscore` can be thought of as the reverse of
  `camelize`, however, in some cases formatting may be lost:

      iex> Macro.underscore("SAPExample")
      "sap_example"

      iex> Macro.camelize("sap_example")
      "SapExample"

      iex> Macro.camelize("hello_10")
      "Hello10"

      iex> Macro.camelize("foo/bar")
      "Foo.Bar"

  """
  @spec underscore(module() | atom() | String.t()) :: String.t()
  def underscore(atom_or_string)

  def underscore(atom) when is_atom(atom) do
    "Elixir." <> rest = Atom.to_string(atom)
    underscore(rest)
  end

  def underscore(<<h, t::binary>>) do
    <<to_lower_char(h)>> <> do_underscore(t, h)
  end

  def underscore("") do
    ""
  end

  defp do_underscore(<<h, t, rest::binary>>, _)
       when h >= ?A and h <= ?Z and not (t >= ?A and t <= ?Z) and not (t >= ?0 and t <= ?9) and
              t != ?. and t != ?_ do
    <<?_, to_lower_char(h), t>> <> do_underscore(rest, t)
  end

  defp do_underscore(<<h, t::binary>>, prev)
       when h >= ?A and h <= ?Z and not (prev >= ?A and prev <= ?Z) and prev != ?_ do
    <<?_, to_lower_char(h)>> <> do_underscore(t, h)
  end

  defp do_underscore(<<?., t::binary>>, _) do
    <<?/>> <> underscore(t)
  end

  defp do_underscore(<<h, t::binary>>, _) do
    <<to_lower_char(h)>> <> do_underscore(t, h)
  end

  defp do_underscore(<<>>, _) do
    <<>>
  end

  @doc """
  Converts the given string to CamelCase format.

  This function was designed to camelize language identifiers/tokens,
  that's why it belongs to the `Macro` module. Do not use it as a general
  mechanism for camelizing strings as it does not support Unicode or
  characters that are not valid in Elixir identifiers.

  ## Examples

      iex> Macro.camelize("foo_bar")
      "FooBar"

      iex> Macro.camelize("foo/bar")
      "Foo.Bar"

  If uppercase characters are present, they are not modified in any way
  as a mechanism to preserve acronyms:

      iex> Macro.camelize("API.V1")
      "API.V1"
      iex> Macro.camelize("API_SPEC")
      "API_SPEC"

  """
  @spec camelize(String.t()) :: String.t()
  def camelize(string)

  def camelize(""), do: ""
  def camelize(<<?_, t::binary>>), do: camelize(t)
  def camelize(<<h, t::binary>>), do: <<to_upper_char(h)>> <> do_camelize(t)

  defp do_camelize(<<?_, ?_, t::binary>>), do: do_camelize(<<?_, t::binary>>)

  defp do_camelize(<<?_, h, t::binary>>) when h >= ?a and h <= ?z,
    do: <<to_upper_char(h)>> <> do_camelize(t)

  defp do_camelize(<<?_, h, t::binary>>) when h >= ?0 and h <= ?9, do: <<h>> <> do_camelize(t)
  defp do_camelize(<<?_>>), do: <<>>
  defp do_camelize(<<?/, t::binary>>), do: <<?.>> <> camelize(t)
  defp do_camelize(<<h, t::binary>>), do: <<h>> <> do_camelize(t)
  defp do_camelize(<<>>), do: <<>>

  defp to_upper_char(char) when char >= ?a and char <= ?z, do: char - 32
  defp to_upper_char(char), do: char

  defp to_lower_char(char) when char >= ?A and char <= ?Z, do: char + 32
  defp to_lower_char(char), do: char

  ## Atom handling

  @doc """
  Classifies a runtime `atom` based on its possible AST placement.

  It returns one of the following atoms:

    * `:alias` - the atom represents an alias

    * `:identifier` - the atom can be used as a variable or local function
      call (as well as be an unquoted atom)

    * `:unquoted` - the atom can be used in its unquoted form,
      includes operators and atoms with `@` in them

    * `:quoted` - all other atoms which can only be used in their quoted form

  Most operators are going to be `:unquoted`, such as `:+`, with
  some exceptions returning `:quoted` due to ambiguity, such as
  `:"::"`. Use `operator?/2` to check if a given atom is an operator.

  ## Examples

      iex> Macro.classify_atom(:foo)
      :identifier
      iex> Macro.classify_atom(Foo)
      :alias
      iex> Macro.classify_atom(:foo@bar)
      :unquoted
      iex> Macro.classify_atom(:+)
      :unquoted
      iex> Macro.classify_atom(:Foo)
      :unquoted
      iex> Macro.classify_atom(:"with spaces")
      :quoted

  """
  @doc since: "1.14.0"
  @spec classify_atom(atom) :: :alias | :identifier | :quoted | :unquoted
  def classify_atom(atom) do
    case inner_classify(atom) do
      :alias -> :alias
      :identifier -> :identifier
      type when type in [:unquoted_operator, :not_callable] -> :unquoted
      _ -> :quoted
    end
  end

  @doc ~S"""
  Inspects `atom` according to different source formats.

  The atom can be inspected according to the three different
  formats it appears in the AST: as a literal (`:literal`),
  as a key (`:key`), or as the function name of a remote call
  (`:remote_call`).

  ## Examples

  ### As a literal

  Literals include regular atoms, quoted atoms, operators,
  aliases, and the special `nil`, `true`, and `false` atoms.

      iex> Macro.inspect_atom(:literal, nil)
      "nil"
      iex> Macro.inspect_atom(:literal, :foo)
      ":foo"
      iex> Macro.inspect_atom(:literal, :<>)
      ":<>"
      iex> Macro.inspect_atom(:literal, :Foo)
      ":Foo"
      iex> Macro.inspect_atom(:literal, Foo.Bar)
      "Foo.Bar"
      iex> Macro.inspect_atom(:literal, :"with spaces")
      ":\"with spaces\""

  ### As a key

  Inspect an atom as a key of a keyword list or a map.

      iex> Macro.inspect_atom(:key, :foo)
      "foo:"
      iex> Macro.inspect_atom(:key, :<>)
      "<>:"
      iex> Macro.inspect_atom(:key, :Foo)
      "Foo:"
      iex> Macro.inspect_atom(:key, :"with spaces")
      "\"with spaces\":"

  ### As a remote call

  Inspect an atom the function name of a remote call.

      iex> Macro.inspect_atom(:remote_call, :foo)
      "foo"
      iex> Macro.inspect_atom(:remote_call, :<>)
      "<>"
      iex> Macro.inspect_atom(:remote_call, :Foo)
      "\"Foo\""
      iex> Macro.inspect_atom(:remote_call, :"with spaces")
      "\"with spaces\""

  """
  @doc since: "1.14.0"
  @spec inspect_atom(:literal | :key | :remote_call, atom) :: binary
  def inspect_atom(source_format, atom)

  def inspect_atom(:literal, atom) when is_nil(atom) or is_boolean(atom) do
    Atom.to_string(atom)
  end

  def inspect_atom(:literal, atom) when is_atom(atom) do
    binary = Atom.to_string(atom)

    case classify_atom(atom) do
      :alias ->
        case binary do
          binary when binary in ["Elixir", "Elixir.Elixir"] -> binary
          "Elixir.Elixir." <> _rest -> binary
          "Elixir." <> rest -> rest
        end

      :quoted ->
        {escaped, _} = Code.Identifier.escape(binary, ?")
        IO.iodata_to_binary([?:, ?", escaped, ?"])

      _ ->
        ":" <> binary
    end
  end

  def inspect_atom(:key, atom) when is_atom(atom) do
    binary = Atom.to_string(atom)

    case classify_atom(atom) do
      :alias ->
        IO.iodata_to_binary([?", binary, ?", ?:])

      :quoted ->
        {escaped, _} = Code.Identifier.escape(binary, ?")
        IO.iodata_to_binary([?", escaped, ?", ?:])

      _ ->
        IO.iodata_to_binary([binary, ?:])
    end
  end

  def inspect_atom(:remote_call, atom) when is_atom(atom) do
    binary = Atom.to_string(atom)

    case inner_classify(atom) do
      type when type in [:identifier, :unquoted_operator, :quoted_operator] ->
        binary

      type ->
        escaped =
          if type in [:not_callable, :alias] do
            binary
          else
            elem(Code.Identifier.escape(binary, ?"), 0)
          end

        IO.iodata_to_binary([?", escaped, ?"])
    end
  end

  # Classifies the given atom into one of the following categories:
  #
  #   * `:alias` - a valid Elixir alias, like `Foo`, `Foo.Bar` and so on
  #
  #   * `:identifier` - an atom that can be used as a variable/local call;
  #     this category includes identifiers like `:foo`
  #
  #   * `:unquoted_operator` - all callable operators, such as `:<>`. Note
  #     operators such as `:..` are not callable because of ambiguity
  #
  #   * `:quoted_operator` - callable operators that must be wrapped in quotes when
  #     defined as an atom. For example, `::` must be written as `:"::"` to avoid
  #     the ambiguity between the atom and the keyword identifier
  #
  #   * `:not_callable` - an atom that cannot be used as a function call after the
  #     `.` operator. Those are typically AST nodes that are special forms (such as
  #     `:%{}` and `:<<>>>`) as well as nodes that are ambiguous in calls (such as
  #     `:..` and `:...`). This category also includes atoms like `:Foo`, since
  #     they are valid identifiers but they need quotes to be used in function
  #     calls (`Foo."Bar"`)
  #
  #   * `:other` - any other atom (these are usually escaped when inspected, like
  #     `:"foo and bar"`)
  #
  defp inner_classify(atom) when is_atom(atom) do
    cond do
      atom in [:%, :%{}, :{}, :<<>>, :..., :.., :., :"..//", :->] ->
        :not_callable

      # <|>, ^^^, and ~~~ are deprecated
      atom in [:"::", :"^^^", :"~~~", :"<|>"] ->
        :quoted_operator

      operator?(atom, 1) or operator?(atom, 2) ->
        :unquoted_operator

      true ->
        charlist = Atom.to_charlist(atom)

        if valid_alias?(charlist) do
          :alias
        else
          case :elixir_config.identifier_tokenizer().tokenize(charlist) do
            {kind, _acc, [], _, _, special} ->
              cond do
                kind != :identifier or :lists.member(:at, special) ->
                  :not_callable

                # identifier_tokenizer used to return errors for non-nfc, but
                # now it nfc-normalizes everything. However, lack of nfc is
                # still a good reason to quote an atom when printing.
                :lists.member(:nfkc, special) ->
                  :other

                true ->
                  :identifier
              end

            _ ->
              :other
          end
        end
    end
  end

  defp valid_alias?([?E, ?l, ?i, ?x, ?i, ?r] ++ rest), do: valid_alias_piece?(rest)
  defp valid_alias?(_other), do: false

  defp valid_alias_piece?([?., char | rest]) when char >= ?A and char <= ?Z,
    do: valid_alias_piece?(trim_leading_while_valid_identifier(rest))

  defp valid_alias_piece?([]), do: true
  defp valid_alias_piece?(_other), do: false

  defp trim_leading_while_valid_identifier([char | rest])
       when char >= ?a and char <= ?z
       when char >= ?A and char <= ?Z
       when char >= ?0 and char <= ?9
       when char == ?_ do
    trim_leading_while_valid_identifier(rest)
  end

  defp trim_leading_while_valid_identifier(other) do
    other
  end

  @doc """
  Default backend for `Kernel.dbg/2`.

  This function provides a default backend for `Kernel.dbg/2`. See the
  `Kernel.dbg/2` documentation for more information.

  This function:

    * prints information about the given `env`
    * prints information about `code` and its returned value (using `opts` to inspect terms)
    * returns the value returned by evaluating `code`

  You can call this function directly to build `Kernel.dbg/2` backends that fall back
  to this function.

  This function raises if the context of the given `env` is `:match` or `:guard`.
  """
  @doc since: "1.14.0"
  @spec dbg(t, t, Macro.Env.t()) :: t
  def dbg(code, options, %Macro.Env{} = env) do
    case env.context do
      :match ->
        raise ArgumentError,
              "invalid expression in match, dbg is not allowed in patterns " <>
                "such as function clauses, case clauses or on the left side of the = operator"

      :guard ->
        raise ArgumentError,
              "invalid expression in guard, dbg is not allowed in guards. " <>
                "To learn more about guards, visit: https://hexdocs.pm/elixir/patterns-and-guards.html"

      _ ->
        :ok
    end

    header = dbg_format_header(env)

    quote do
      to_debug = unquote(dbg_ast_to_debuggable(code))
      unquote(__MODULE__).__dbg__(unquote(header), to_debug, unquote(options))
    end
  end

  # Pipelines.
  defp dbg_ast_to_debuggable({:|>, _meta, _args} = pipe_ast) do
    value_var = unique_var(:value, __MODULE__)
    values_acc_var = unique_var(:values, __MODULE__)

    [start_ast | rest_asts] = asts = for {ast, 0} <- unpipe(pipe_ast), do: ast
    rest_asts = Enum.map(rest_asts, &pipe(value_var, &1, 0))

    initial_acc =
      quote do
        unquote(value_var) = unquote(start_ast)
        unquote(values_acc_var) = [unquote(value_var)]
      end

    values_ast =
      for step_ast <- rest_asts, reduce: initial_acc do
        ast_acc ->
          quote do
            unquote(ast_acc)
            unquote(value_var) = unquote(step_ast)
            unquote(values_acc_var) = [unquote(value_var) | unquote(values_acc_var)]
          end
      end

    quote do
      unquote(values_ast)

      {:pipe, unquote(escape(asts)), Enum.reverse(unquote(values_acc_var))}
    end
  end

  dbg_decomposed_binary_operators = [:&&, :||, :and, :or]

  # Logic operators.
  defp dbg_ast_to_debuggable({op, _meta, [_left, _right]} = ast)
       when op in unquote(dbg_decomposed_binary_operators) do
    acc_var = unique_var(:acc, __MODULE__)
    result_var = unique_var(:result, __MODULE__)

    quote do
      unquote(acc_var) = []
      unquote(dbg_boolean_tree(ast, acc_var, result_var))
      {:logic_op, Enum.reverse(unquote(acc_var))}
    end
  end

  defp dbg_ast_to_debuggable({:case, _meta, [expr, [do: clauses]]} = ast) do
    clauses_returning_index =
      Enum.with_index(clauses, fn {:->, meta, [left, right]}, index ->
        {:->, meta, [left, {right, index}]}
      end)

    quote do
      expr = unquote(expr)

      {result, clause_index} =
        case expr do
          unquote(clauses_returning_index)
        end

      {:case, unquote(escape(ast)), expr, clause_index, result}
    end
  end

  defp dbg_ast_to_debuggable({:cond, _meta, [[do: clauses]]} = ast) do
    modified_clauses =
      Enum.with_index(clauses, fn {:->, _meta, [[left], right]}, index ->
        hd(
          quote do
            clause_value = unquote(left) ->
              {unquote(escape(left)), clause_value, unquote(index), unquote(right)}
          end
        )
      end)

    quote do
      {clause_ast, clause_value, clause_index, value} =
        cond do
          unquote(modified_clauses)
        end

      {:cond, unquote(escape(ast)), clause_ast, clause_value, clause_index, value}
    end
  end

  # Any other AST.
  defp dbg_ast_to_debuggable(ast) do
    quote do: {:value, unquote(escape(ast)), unquote(ast)}
  end

  # This is a binary operator. We replace the left side with a recursive call to
  # this function to decompose it, and then execute the operation and add it to the acc.
  defp dbg_boolean_tree({op, _meta, [left, right]} = ast, acc_var, result_var)
       when op in unquote(dbg_decomposed_binary_operators) do
    replaced_left = dbg_boolean_tree(left, acc_var, result_var)

    quote do
      unquote(result_var) = unquote(op)(unquote(replaced_left), unquote(right))

      unquote(acc_var) = [
        {unquote(escape(ast)), unquote(result_var)} | unquote(acc_var)
      ]

      unquote(result_var)
    end
  end

  # This is finally an expression, so we assign "result = expr", add it to the acc, and
  # return the result.
  defp dbg_boolean_tree(ast, acc_var, result_var) do
    quote do
      unquote(result_var) = unquote(ast)
      unquote(acc_var) = [{unquote(escape(ast)), unquote(result_var)} | unquote(acc_var)]
      unquote(result_var)
    end
  end

  # Made public to be called from Macro.dbg/3, so that we generate as little code
  # as possible and call out into a function as soon as we can.
  @doc false
  def __dbg__(header_string, to_debug, options) do
    {print_location?, options} = Keyword.pop(options, :print_location, true)
    syntax_colors = if IO.ANSI.enabled?(), do: IO.ANSI.syntax_colors(), else: []
    options = Keyword.merge([width: 80, pretty: true, syntax_colors: syntax_colors], options)

    {formatted, result} = dbg_format_ast_to_debug(to_debug, options)

    formatted =
      if print_location? do
        [:cyan, :italic, header_string, :reset, "\n", formatted, "\n"]
      else
        [formatted, "\n"]
      end

    ansi_enabled? = options[:syntax_colors] != []
    :ok = IO.write(IO.ANSI.format(formatted, ansi_enabled?))

    result
  end

  defp dbg_format_ast_to_debug({:pipe, code_asts, values}, options) do
    result = List.last(values)
    code_strings = Enum.map(code_asts, &to_string_with_colors(&1, options))
    [{first_ast, first_value} | asts_with_values] = Enum.zip(code_strings, values)
    first_formatted = [dbg_format_ast(first_ast), " ", inspect(first_value, options), ?\n]

    rest_formatted =
      Enum.map(asts_with_values, fn {code_ast, value} ->
        [:faint, "|> ", :reset, dbg_format_ast(code_ast), " ", inspect(value, options), ?\n]
      end)

    {[first_formatted | rest_formatted], result}
  end

  defp dbg_format_ast_to_debug({:logic_op, components}, options) do
    {_ast, final_value} = List.last(components)

    formatted =
      Enum.map(components, fn {ast, value} ->
        [dbg_format_ast(to_string_with_colors(ast, options)), " ", inspect(value, options), ?\n]
      end)

    {formatted, final_value}
  end

  defp dbg_format_ast_to_debug({:case, ast, expr_value, clause_index, value}, options) do
    {:case, _meta, [expr_ast, _]} = ast

    formatted = [
      dbg_maybe_underline("Case argument", options),
      ":\n",
      dbg_format_ast_with_value(expr_ast, expr_value, options),
      ?\n,
      dbg_maybe_underline("Case expression", options),
      " (clause ##{clause_index + 1} matched):\n",
      dbg_format_ast_with_value(ast, value, options)
    ]

    {formatted, value}
  end

  defp dbg_format_ast_to_debug(
         {:cond, ast, clause_ast, clause_value, clause_index, value},
         options
       ) do
    formatted = [
      dbg_maybe_underline("Cond clause", options),
      " (clause ##{clause_index + 1} matched):\n",
      dbg_format_ast_with_value(clause_ast, clause_value, options),
      ?\n,
      dbg_maybe_underline("Cond expression", options),
      ":\n",
      dbg_format_ast_with_value(ast, value, options)
    ]

    {formatted, value}
  end

  defp dbg_format_ast_to_debug({:value, code_ast, value}, options) do
    {dbg_format_ast_with_value(code_ast, value, options), value}
  end

  defp dbg_format_ast_with_value(ast, value, options) do
    [dbg_format_ast(to_string_with_colors(ast, options)), " ", inspect(value, options), ?\n]
  end

  defp to_string_with_colors(ast, options) do
    options = Keyword.take(options, [:syntax_colors])

    algebra = Code.quoted_to_algebra(ast, options)
    IO.iodata_to_binary(Inspect.Algebra.format(algebra, 98))
  end

  defp dbg_format_header(env) do
    env = Map.update!(env, :file, &(&1 && Path.relative_to_cwd(&1)))
    [stacktrace_entry] = Macro.Env.stacktrace(env)
    "[" <> Exception.format_stacktrace_entry(stacktrace_entry) <> "]"
  end

  defp dbg_maybe_underline(string, options) do
    if options[:syntax_colors] != [] do
      IO.ANSI.format([:underline, string, :reset])
    else
      string
    end
  end

  defp dbg_format_ast(ast) do
    [ast, :faint, " #=>", :reset]
  end
end
