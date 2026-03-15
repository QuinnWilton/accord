  defmodule Engine.Api.Proxy.Protocol do
    use Accord.Protocol

    initial :proxying

    state :proxying do
      on {:start_buffering, caller :: term()} do
        reply(:ok)
        branch :empty, goto: :buffering
        branch :in_flight, goto: :draining
      end

      on {:buffer, contents :: term(), return :: term()}, reply: term(), goto: :proxying
      on {:drop, contents :: term(), return :: term()}, reply: term(), goto: :proxying
      on :buffering?, reply: false, goto: :proxying
    end

    state :draining do
      on {:start_buffering, caller :: term()}, reply: {:error, term()}, goto: :draining
      on {:buffer, contents :: term(), return :: term()}, reply: :ok, goto: :draining
      on {:drop, contents :: term(), return :: term()}, reply: term(), goto: :draining
      on :buffering?, reply: true, goto: :draining

      cast :drained, goto: :buffering
    end

    state :buffering do
      on {:start_buffering, caller :: term()}, reply: {:error, term()}, goto: :buffering
      on {:buffer, contents :: term(), return :: term()}, reply: :ok, goto: :buffering
      on {:drop, contents :: term(), return :: term()}, reply: term(), goto: :buffering
      on :buffering?, reply: true, goto: :buffering

      cast :initiator_down, goto: :proxying
    end

    property :buffering_resolves do
      liveness in_state(:buffering), leads_to: in_state(:proxying)
    end

    property :draining_resolves do
      liveness in_state(:draining), leads_to: in_state(:buffering)
    end
  end
