defmodule Accord.Protocol.Property do
  @moduledoc false

  # Inner macros for the `property :name do ... end` block form.
  # These accumulate checks into module attributes that are read
  # after the block closes.

  alias Accord.IR.Check

  @doc false
  defmacro invariant(func) do
    escaped_ast = Macro.escape(func)
    span = span_ast(__CALLER__)

    quote do
      checks = Module.get_attribute(__MODULE__, :accord_property_checks)

      check = %Check{
        kind: :invariant,
        spec: %{fun: unquote(func), ast: unquote(escaped_ast)},
        span: unquote(span)
      }

      Module.put_attribute(__MODULE__, :accord_property_checks, [check | checks])
    end
  end

  @doc false
  defmacro invariant(state_name, func) do
    escaped_ast = Macro.escape(func)
    span = span_ast(__CALLER__)

    quote do
      checks = Module.get_attribute(__MODULE__, :accord_property_checks)

      check = %Check{
        kind: :local_invariant,
        spec: %{state: unquote(state_name), fun: unquote(func), ast: unquote(escaped_ast)},
        span: unquote(span)
      }

      Module.put_attribute(__MODULE__, :accord_property_checks, [check | checks])
    end
  end

  @doc false
  defmacro action(func) do
    escaped_ast = Macro.escape(func)
    span = span_ast(__CALLER__)

    quote do
      checks = Module.get_attribute(__MODULE__, :accord_property_checks)

      check = %Check{
        kind: :action,
        spec: %{fun: unquote(func), ast: unquote(escaped_ast)},
        span: unquote(span)
      }

      Module.put_attribute(__MODULE__, :accord_property_checks, [check | checks])
    end
  end

  @doc false
  defmacro liveness(trigger, opts) do
    target = Keyword.fetch!(opts, :leads_to)
    fairness = Keyword.get(opts, :fairness, :weak)
    span = span_ast(__CALLER__)

    quote do
      checks = Module.get_attribute(__MODULE__, :accord_property_checks)

      check = %Check{
        kind: :liveness,
        spec: %{
          trigger: unquote(trigger),
          target: unquote(target),
          fairness: unquote(fairness)
        },
        span: unquote(span)
      }

      Module.put_attribute(__MODULE__, :accord_property_checks, [check | checks])
    end
  end

  @doc false
  defmacro correspondence(open, close) do
    span = span_ast(__CALLER__)

    quote do
      checks = Module.get_attribute(__MODULE__, :accord_property_checks)

      check = %Check{
        kind: :correspondence,
        spec: %{open: unquote(open), close: unquote(close)},
        span: unquote(span)
      }

      Module.put_attribute(__MODULE__, :accord_property_checks, [check | checks])
    end
  end

  @doc false
  defmacro bounded(track_name, opts) do
    max = Keyword.fetch!(opts, :max)
    span = span_ast(__CALLER__)

    quote do
      checks = Module.get_attribute(__MODULE__, :accord_property_checks)

      check = %Check{
        kind: :bounded,
        spec: %{track: unquote(track_name), max: unquote(max)},
        span: unquote(span)
      }

      Module.put_attribute(__MODULE__, :accord_property_checks, [check | checks])
    end
  end

  @doc false
  defmacro ordered(event, opts) do
    by = Keyword.fetch!(opts, :by)
    span = span_ast(__CALLER__)

    quote do
      checks = Module.get_attribute(__MODULE__, :accord_property_checks)

      check = %Check{
        kind: :ordered,
        spec: %{event: unquote(event), by: unquote(by)},
        span: unquote(span)
      }

      Module.put_attribute(__MODULE__, :accord_property_checks, [check | checks])
    end
  end

  @doc false
  defmacro precedence(target, required) do
    span = span_ast(__CALLER__)

    quote do
      checks = Module.get_attribute(__MODULE__, :accord_property_checks)

      check = %Check{
        kind: :precedence,
        spec: %{target: unquote(target), required: unquote(required)},
        span: unquote(span)
      }

      Module.put_attribute(__MODULE__, :accord_property_checks, [check | checks])
    end
  end

  @doc false
  defmacro reachable(target) do
    span = span_ast(__CALLER__)

    quote do
      checks = Module.get_attribute(__MODULE__, :accord_property_checks)

      check = %Check{
        kind: :reachable,
        spec: %{target: unquote(target)},
        span: unquote(span)
      }

      Module.put_attribute(__MODULE__, :accord_property_checks, [check | checks])
    end
  end

  @doc false
  defmacro forbidden(func) do
    escaped_ast = Macro.escape(func)
    span = span_ast(__CALLER__)

    quote do
      checks = Module.get_attribute(__MODULE__, :accord_property_checks)

      check = %Check{
        kind: :forbidden,
        spec: %{fun: unquote(func), ast: unquote(escaped_ast)},
        span: unquote(span)
      }

      Module.put_attribute(__MODULE__, :accord_property_checks, [check | checks])
    end
  end

  defp span_ast(caller) do
    meta = [line: caller.line]

    meta =
      case Map.get(caller, :column) do
        nil -> meta
        col -> Keyword.put(meta, :column, col)
      end

    quote do
      Pentiment.Elixir.span_from_meta(unquote(meta))
    end
  end
end
