defmodule Accord.Protocol.Property do
  @moduledoc false

  # Inner macros for the `property :name do ... end` block form.
  # These accumulate checks into module attributes that are read
  # after the block closes.
  #
  # Each check's span is inherited from the parent property's span
  # (stored in :accord_current_property_span by the property macro).
  # This means check spans resolve to the property name atom,
  # connecting violations back to the owning property declaration.

  alias Accord.IR.Check

  @doc false
  defmacro invariant(func) do
    escaped_ast = Macro.escape(func)

    quote do
      checks = Module.get_attribute(__MODULE__, :accord_property_checks)

      check = %Check{
        kind: :invariant,
        spec: %{fun: unquote(func), ast: unquote(escaped_ast)},
        span: Module.get_attribute(__MODULE__, :accord_current_property_span)
      }

      Module.put_attribute(__MODULE__, :accord_property_checks, [check | checks])
    end
  end

  @doc false
  defmacro invariant(state_name, func) do
    escaped_ast = Macro.escape(func)

    quote do
      checks = Module.get_attribute(__MODULE__, :accord_property_checks)

      check = %Check{
        kind: :local_invariant,
        spec: %{state: unquote(state_name), fun: unquote(func), ast: unquote(escaped_ast)},
        span: Module.get_attribute(__MODULE__, :accord_current_property_span)
      }

      Module.put_attribute(__MODULE__, :accord_property_checks, [check | checks])
    end
  end

  @doc false
  defmacro action(func) do
    escaped_ast = Macro.escape(func)

    quote do
      checks = Module.get_attribute(__MODULE__, :accord_property_checks)

      check = %Check{
        kind: :action,
        spec: %{fun: unquote(func), ast: unquote(escaped_ast)},
        span: Module.get_attribute(__MODULE__, :accord_current_property_span)
      }

      Module.put_attribute(__MODULE__, :accord_property_checks, [check | checks])
    end
  end

  @doc false
  defmacro liveness(trigger, opts) do
    target = Keyword.fetch!(opts, :leads_to)
    fairness = Keyword.get(opts, :fairness, :weak)
    timeout = Keyword.get(opts, :timeout, :infinity)

    quote do
      checks = Module.get_attribute(__MODULE__, :accord_property_checks)

      check = %Check{
        kind: :liveness,
        spec: %{
          trigger: unquote(trigger),
          target: unquote(target),
          fairness: unquote(fairness),
          timeout: unquote(timeout)
        },
        span: Module.get_attribute(__MODULE__, :accord_current_property_span)
      }

      Module.put_attribute(__MODULE__, :accord_property_checks, [check | checks])
    end
  end

  @doc false
  defmacro correspondence(open, close, opts \\ []) do
    by = Keyword.get(opts, :by)

    quote do
      checks = Module.get_attribute(__MODULE__, :accord_property_checks)

      check = %Check{
        kind: :correspondence,
        spec: %{open: unquote(open), close: unquote(close), by: unquote(by)},
        span: Module.get_attribute(__MODULE__, :accord_current_property_span)
      }

      Module.put_attribute(__MODULE__, :accord_property_checks, [check | checks])
    end
  end

  @doc false
  defmacro bounded(track_name, opts) do
    max = Keyword.fetch!(opts, :max)

    quote do
      checks = Module.get_attribute(__MODULE__, :accord_property_checks)

      check = %Check{
        kind: :bounded,
        spec: %{track: unquote(track_name), max: unquote(max)},
        span: Module.get_attribute(__MODULE__, :accord_current_property_span)
      }

      Module.put_attribute(__MODULE__, :accord_property_checks, [check | checks])
    end
  end

  @doc false
  defmacro ordered(event, opts) do
    by = Keyword.fetch!(opts, :by)

    quote do
      checks = Module.get_attribute(__MODULE__, :accord_property_checks)

      check = %Check{
        kind: :ordered,
        spec: %{event: unquote(event), by: unquote(by)},
        span: Module.get_attribute(__MODULE__, :accord_current_property_span)
      }

      Module.put_attribute(__MODULE__, :accord_property_checks, [check | checks])
    end
  end

  @doc false
  defmacro precedence(target, required) do
    quote do
      checks = Module.get_attribute(__MODULE__, :accord_property_checks)

      check = %Check{
        kind: :precedence,
        spec: %{target: unquote(target), required: unquote(required)},
        span: Module.get_attribute(__MODULE__, :accord_current_property_span)
      }

      Module.put_attribute(__MODULE__, :accord_property_checks, [check | checks])
    end
  end

  @doc false
  defmacro reachable(target) do
    quote do
      checks = Module.get_attribute(__MODULE__, :accord_property_checks)

      check = %Check{
        kind: :reachable,
        spec: %{target: unquote(target)},
        span: Module.get_attribute(__MODULE__, :accord_current_property_span)
      }

      Module.put_attribute(__MODULE__, :accord_property_checks, [check | checks])
    end
  end

  @doc false
  defmacro forbidden(func) do
    escaped_ast = Macro.escape(func)

    quote do
      checks = Module.get_attribute(__MODULE__, :accord_property_checks)

      check = %Check{
        kind: :forbidden,
        spec: %{fun: unquote(func), ast: unquote(escaped_ast)},
        span: Module.get_attribute(__MODULE__, :accord_current_property_span)
      }

      Module.put_attribute(__MODULE__, :accord_property_checks, [check | checks])
    end
  end
end
