Code.require_file "../test_helper.exs", __DIR__

defmodule IEx.AutocompleteTest do
  use ExUnit.Case, async: true

  setup do
    evaluator = IEx.Server.start_evaluator([])
    Process.put(:evaluator, evaluator)
    :ok
  end

  defmodule MyServer do
    def evaluator do
      Process.get(:evaluator)
    end
  end

  defp eval(line) do
    ExUnit.CaptureIO.capture_io(fn ->
      evaluator = MyServer.evaluator
      Process.group_leader(evaluator, Process.group_leader)
      send evaluator, {:eval, self(), line <> "\n", %IEx.State{}}
      assert_receive {:evaled, _, _}
    end)
  end

  defp expand(expr) do
    IEx.Autocomplete.expand(Enum.reverse(expr), MyServer)
  end

  test "Erlang module completion" do
    assert expand(':zl') == {:yes, 'ib', []}
  end

  test "Erlang module no completion" do
    assert expand(':unknown') == {:no, '', []}
    assert expand('Enum:') == {:no, '', []}
  end

  test "Erlang module multiple values completion" do
    {:yes, '', list} = expand(':user')
    assert 'user' in list
    assert 'user_drv' in list
  end

  test "Erlang root completion" do
    {:yes, '', list} = expand(':')
    assert is_list(list)
    assert 'lists' in list
  end

  test "Elixir proxy" do
    {:yes, '', list} = expand('E')
    assert 'Elixir' in list
  end

  test "Elixir completion" do
    assert expand('En') == {:yes, 'um', []}
    assert expand('Enumera') == {:yes, 'ble', []}
  end

  test "Elixir completion with self" do
    assert expand('Enumerable') == {:yes, '.', []}
  end

  test "Elixir completion on modules from load path" do
    assert expand('Str') == {:yes, [], ['Stream', 'String', 'StringIO']}
    assert expand('Ma') == {:yes, '', ['Macro', 'Map', 'MapSet', 'MatchError']}
    assert expand('Dic') == {:yes, 't', []}
    assert expand('Ex')  == {:yes, [], ['ExUnit', 'Exception']}
  end

  test "Elixir no completion for underscored functions with no doc" do
    {:module, _, bytecode, _} =
      defmodule Elixir.Sample do
        def __foo__(), do: 0
        @doc "Bar doc"
        def __bar__(), do: 1
      end
    File.write!("Elixir.Sample.beam", bytecode)
    assert Code.get_docs(Sample, :docs)
    assert expand('Sample._') == {:yes, '_bar__', []}
  after
    File.rm("Elixir.Sample.beam")
    :code.purge(Sample)
    :code.delete(Sample)
  end

  test "Elixir no completion" do
    assert expand('.')   == {:no, '', []}
    assert expand('Xyz') == {:no, '', []}
    assert expand('x.Foo') == {:no, '', []}
    assert expand('x.Foo.get_by') == {:no, '', []}
  end

  test "Elixir root submodule completion" do
    assert expand('Elixir.Acce') == {:yes, 'ss', []}
  end

  test "Elixir submodule completion" do
    assert expand('String.Cha') == {:yes, 'rs', []}
  end

  test "Elixir submodule no completion" do
    assert expand('IEx.Xyz') == {:no, '', []}
  end

  test "function completion" do
    assert expand('System.ve') == {:yes, 'rsion', []}
    assert expand(':ets.fun2') == {:yes, 'ms', []}
  end

  test "function completion with arity" do
    assert expand('String.printable?')  == {:yes, '', ['printable?/1']}
    assert expand('String.printable?/') == {:yes, '', ['printable?/1']}
  end

  test "function completion using a variable bound to a module" do
    eval("mod = String")
    assert expand('mod.print') == {:yes, 'able?', []}
  end

  test "map atom key completion is supported" do
    eval("map = %{foo: 1, bar_1: 23, bar_2: 14}")
    assert expand('map.f') == {:yes, 'oo', []}
    assert expand('map.b') == {:yes, 'ar_', []}
    assert expand('map.bar_') == {:yes, '', ['bar_1', 'bar_2']}
    assert expand('map.c') == {:no, '', []}
    assert expand('map.') == {:yes, '', ['bar_1', 'bar_2', 'foo']}
    assert expand('map.foo') == {:no, '', []}
  end

  test "nested map atom key completion is supported" do
    eval("map = %{nested: %{deeply: %{foo: 1, bar_1: 23, bar_2: 14, mod: String, num: 1}}}")
    assert expand('map.nested.deeply.f') == {:yes, 'oo', []}
    assert expand('map.nested.deeply.b') == {:yes, 'ar_', []}
    assert expand('map.nested.deeply.bar_') == {:yes, '', ['bar_1', 'bar_2']}
    assert expand('map.nested.deeply.') == {:yes, '', ['bar_1', 'bar_2', 'foo', 'mod', 'num']}
    assert expand('map.nested.deeply.mod.print') == {:yes, 'able?', []}

    assert expand('map.nested') == {:yes, '.', []}
    assert expand('map.nested.deeply') == {:yes, '.', []}
    assert expand('map.nested.deeply.foo') == {:no, '', []}

    assert expand('map.nested.deeply.c') == {:no, '', []}
    assert expand('map.a.b.c.f') == {:no, '', []}
  end

  test "map string key completion is not supported" do
    eval(~S(map = %{"foo" => 1}))
    assert expand('map.f') == {:no, '', []}
  end

  test "autocompletion off a bound variable only works for modules and maps" do
    eval("num = 5; map = %{nested: %{num: 23}}")
    assert expand('num.print') == {:no, '', []}
    assert expand('map.nested.num.f') == {:no, '', []}
    assert expand('map.nested.num.key.f') == {:no, '', []}
  end

  test "autocompletion using access syntax does is not supported" do
    eval("map = %{nested: %{deeply: %{num: 23}}}")
    assert expand('map[:nested][:deeply].n') == {:no, '', []}
    assert expand('map[:nested].deeply.n') == {:no, '', []}
    assert expand('map.nested.[:deeply].n') == {:no, '', []}
  end

  test "autocompletion off of unbound variables is not supported" do
    eval("num = 5")
    assert expand('other_var.f') == {:no, '', []}
    assert expand('a.b.c.d') == {:no, '', []}
  end

  test "macro completion" do
    {:yes, '', list} = expand('Kernel.is_')
    assert is_list(list)
  end

  test "imports completion" do
    {:yes, '', list} = expand('')
    assert is_list(list)
    assert 'h/1' in list
    assert 'unquote/1' in list
    assert 'pwd/0' in list
  end

  test "kernel import completion" do
    assert expand('defstru') == {:yes, 'ct', []}
    assert expand('put_') == {:yes, '', ['put_elem/3', 'put_in/2', 'put_in/3']}
  end

  test "variable name completion" do
    eval("numeral = 3; number = 3; nothing = nil")
    assert expand('numb') == {:yes, 'er', []}
    assert expand('num') == {:yes, '', ['number', 'numeral']}
    assert expand('no') == {:yes, '', ['nothing', 'node/0', 'node/1', 'not/1']}
  end

  test "completion of manually imported functions and macros" do
    eval("import Enum; import Supervisor, only: [count_children: 1]; import Protocol")
    assert expand('take') == {:yes, '', ['take/2', 'take_every/2', 'take_random/2', 'take_while/2']}
    assert expand('count') == {:yes, '', ['count/1', 'count/2', 'count_children/1']}
    assert expand('der') == {:yes, 'ive', []}
  end

  defmacro define_var do
    quote do: var!(my_var_1, Elixir) = 1
  end

  test "ignores quoted variables when performing variable completion" do
    eval("require #{__MODULE__}; #{__MODULE__}.define_var(); my_var_2 = 2")
    assert expand('my_var') == {:yes, '_2', []}
  end

  test "kernel special form completion" do
    assert expand('unquote_spl') == {:yes, 'icing', []}
  end

  test "completion inside expression" do
    assert expand('1 En') == {:yes, 'um', []}
    assert expand('Test(En') == {:yes, 'um', []}
    assert expand('Test :zl') == {:yes, 'ib', []}
    assert expand('[:zl') == {:yes, 'ib', []}
    assert expand('{:zl') == {:yes, 'ib', []}
  end

  test "ampersand completion" do
    assert expand('&Enu') == {:yes, 'm', []}
    assert expand('&Enum.a') == {:yes, [], ['all?/1', 'all?/2', 'any?/1', 'any?/2', 'at/2', 'at/3']}
    assert expand('f = &Enum.a') == {:yes, [], ['all?/1', 'all?/2', 'any?/1', 'any?/2', 'at/2', 'at/3']}
  end

  defmodule SublevelTest.LevelA.LevelB do
  end

  test "Elixir completion sublevel" do
    assert expand('IEx.AutocompleteTest.SublevelTest.') == {:yes, 'LevelA', []}
  end

  test "complete aliases of Elixir modules" do
    eval("alias List, as: MyList")
    assert expand('MyL') == {:yes, 'ist', []}
    assert expand('MyList') == {:yes, '.', []}
    assert expand('MyList.to_integer') == {:yes, [], ['to_integer/1', 'to_integer/2']}
  end

  test "complete aliases of Erlang modules" do
    eval("alias :lists, as: EList")
    assert expand('EL') == {:yes, 'ist', []}
    assert expand('EList') == {:yes, '.', []}
    assert expand('EList.map') == {:yes, [], ['map/2', 'mapfoldl/3', 'mapfoldr/3']}
  end

  test "completion for functions added when compiled module is reloaded" do
    {:module, _, bytecode, _} =
      defmodule Sample do
        def foo(), do: 0
      end
    File.write!("Elixir.IEx.AutocompleteTest.Sample.beam", bytecode)
    assert Code.get_docs(Sample, :docs)
    assert expand('IEx.AutocompleteTest.Sample.foo') == {:yes, '', ['foo/0']}

    Code.compiler_options(ignore_module_conflict: true)
    defmodule Sample do
      def foo(), do: 0
      def foobar(), do: 0
    end
    assert expand('IEx.AutocompleteTest.Sample.foo') == {:yes, '', ['foo/0', 'foobar/0']}
  after
    File.rm("Elixir.IEx.AutocompleteTest.Sample.beam")
    Code.compiler_options(ignore_module_conflict: false)
    :code.purge(Sample)
    :code.delete(Sample)
  end

  defmodule MyStruct do
    defstruct [:my_val]
  end

  test "completion for struct names" do
    assert expand('%IEx.AutocompleteTest.MyStr') == {:yes, 'uct', []}
  end

  test "completion for struct keys" do
    eval("struct = %IEx.AutocompleteTest.MyStruct{}")
    assert expand('struct.my') == {:yes, '_val', []}
  end

  test "ignore invalid Elixir module literals" do
    defmodule :"Elixir.IEx.AutocompleteTest.Unicodé", do: nil
    assert expand('IEx.AutocompleteTest.Unicod') == {:no, '', []}
  after
    :code.purge(:"Elixir.IEx.AutocompleteTest.Unicodé")
    :code.delete(:"Elixir.IEx.AutocompleteTest.Unicodé")
  end

  test "ignore invalid Erlang module literals" do
    defmodule :"iex_autocomplete_unicodé", do: nil
    assert expand(':iex_autocomplete_unicod') == {:no, '', []}
  after
    :code.purge(:"iex_autocomplete_unicodé")
    :code.delete(:"iex_autocomplete_unicodé")
  end
end
