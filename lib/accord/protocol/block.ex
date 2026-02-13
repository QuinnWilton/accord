defmodule Accord.Protocol.Block do
  @moduledoc false

  # Inner macros for the `on ... do ... end` block form.
  # These accumulate into module attributes that are read after the block.

  alias Accord.IR.Branch

  @doc false
  defmacro reply(type_spec) do
    reply_type = Accord.Protocol.parse_reply_spec(type_spec)
    escaped = Macro.escape(reply_type)
    line = __CALLER__.line
    pattern = Macro.to_string(type_spec)

    quote do
      Module.put_attribute(__MODULE__, :accord_on_reply_type, unquote(escaped))

      Module.put_attribute(
        __MODULE__,
        :accord_on_reply_span,
        Pentiment.Span.search(line: unquote(line), pattern: unquote(pattern))
      )
    end
  end

  @doc false
  defmacro reply(type_spec, opts) do
    reply_type = Accord.Protocol.parse_reply_spec(type_spec)
    escaped = Macro.escape(reply_type)
    line = __CALLER__.line
    pattern = Macro.to_string(type_spec)

    where_fn = Keyword.get(opts, :where)
    escaped_where = if where_fn, do: Macro.escape(where_fn)

    quote do
      Module.put_attribute(__MODULE__, :accord_on_reply_type, unquote(escaped))

      Module.put_attribute(
        __MODULE__,
        :accord_on_reply_span,
        Pentiment.Span.search(line: unquote(line), pattern: unquote(pattern))
      )

      if unquote(where_fn) do
        Module.put_attribute(__MODULE__, :accord_on_reply_constraint, %{
          fun: unquote(where_fn),
          ast: unquote(escaped_where)
        })
      end
    end
  end

  @doc false
  defmacro goto(state_name) do
    line = __CALLER__.line
    pattern = inspect(state_name)

    quote do
      Module.put_attribute(__MODULE__, :accord_on_goto, unquote(state_name))

      Module.put_attribute(
        __MODULE__,
        :accord_on_goto_span,
        Pentiment.Span.search(line: unquote(line), pattern: unquote(pattern))
      )
    end
  end

  @doc false
  defmacro guard(func) do
    escaped_ast = Macro.escape(func)
    line = __CALLER__.line

    quote do
      Module.put_attribute(__MODULE__, :accord_on_guard, %{
        fun: unquote(func),
        ast: unquote(escaped_ast),
        span: Pentiment.Span.search(line: unquote(line), pattern: "guard")
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
    where_fn = Keyword.get(opts, :where)
    reply_type = Accord.Protocol.parse_reply_spec(reply_spec)
    escaped = Macro.escape(reply_type)
    escaped_where = if where_fn, do: Macro.escape(where_fn)
    line = __CALLER__.line
    pattern = Macro.to_string(reply_spec)
    next_state_pattern = inspect(next_state)

    quote do
      constraint =
        if unquote(where_fn) do
          %{fun: unquote(where_fn), ast: unquote(escaped_where)}
        end

      branches = Module.get_attribute(__MODULE__, :accord_on_branches)

      Module.put_attribute(
        __MODULE__,
        :accord_on_branches,
        [
          %Branch{
            reply_type: unquote(escaped),
            next_state: unquote(next_state),
            constraint: constraint,
            span: Pentiment.Span.search(line: unquote(line), pattern: unquote(pattern)),
            next_state_span:
              Pentiment.Span.search(line: unquote(line), pattern: unquote(next_state_pattern))
          }
          | branches
        ]
      )
    end
  end
end
