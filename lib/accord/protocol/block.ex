defmodule Accord.Protocol.Block do
  @moduledoc false

  # Inner macros for the `on ... do ... end` block form.
  # These accumulate into module attributes that are read after the block.

  alias Accord.IR.Branch

  @doc false
  defmacro reply(type_spec) do
    reply_type = Accord.Protocol.parse_reply_spec(type_spec)
    escaped = Macro.escape(reply_type)

    quote do
      Module.put_attribute(__MODULE__, :accord_on_reply_type, unquote(escaped))
    end
  end

  @doc false
  defmacro goto(state_name) do
    quote do
      Module.put_attribute(__MODULE__, :accord_on_goto, unquote(state_name))
    end
  end

  @doc false
  defmacro guard(func) do
    escaped_ast = Macro.escape(func)

    quote do
      Module.put_attribute(__MODULE__, :accord_on_guard, %{
        fun: unquote(func),
        ast: unquote(escaped_ast)
      })
    end
  end

  @doc false
  defmacro update(func) do
    escaped_ast = Macro.escape(func)

    quote do
      Module.put_attribute(__MODULE__, :accord_on_update, %{
        fun: unquote(func),
        ast: unquote(escaped_ast)
      })
    end
  end

  @doc false
  defmacro branch(reply_spec, opts) do
    next_state = Keyword.fetch!(opts, :goto)
    reply_type = Accord.Protocol.parse_reply_spec(reply_spec)
    escaped = Macro.escape(reply_type)

    quote do
      branches = Module.get_attribute(__MODULE__, :accord_on_branches)

      Module.put_attribute(
        __MODULE__,
        :accord_on_branches,
        [%Branch{reply_type: unquote(escaped), next_state: unquote(next_state)} | branches]
      )
    end
  end
end
