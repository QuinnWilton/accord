defmodule Accord.Pass.RefineSpansTest do
  use ExUnit.Case, async: true

  alias Accord.IR
  alias Accord.IR.{Branch, State, Transition}
  alias Accord.Pass.RefineSpans

  @source_content """
  defmodule Test do
    use Accord.Protocol

    initial :ready

    state :ready do
      on :ping, reply: :pong, goto: :ready
      on :stop, reply: :stopped, goto: :stopped
    end

    state :stopped, terminal: true
  end
  """

  setup do
    tmp_dir = System.tmp_dir!()
    path = Path.join(tmp_dir, "refine_spans_test_#{:rand.uniform(100_000)}.ex")
    File.write!(path, @source_content)
    on_exit(fn -> File.rm(path) end)
    %{path: path}
  end

  test "refines state name span to the atom token", %{path: path} do
    ir = %IR{
      name: Test,
      source_file: path,
      initial: :ready,
      states: %{
        ready: %State{
          name: :ready,
          transitions: [],
          span: %Pentiment.Span.Position{start_line: 6, start_column: 3}
        }
      }
    }

    assert {:ok, refined} = RefineSpans.run(ir)
    span = refined.states[:ready].span

    # Should point at :ready on line 6.
    assert span.start_line == 6
    assert span.start_column > 3
  end

  test "refines transition message span", %{path: path} do
    ir = %IR{
      name: Test,
      source_file: path,
      initial: :ready,
      states: %{
        ready: %State{
          name: :ready,
          transitions: [
            %Transition{
              message_pattern: :ping,
              message_types: [],
              kind: :call,
              branches: [%Branch{reply_type: {:literal, :pong}, next_state: :ready}],
              span: %Pentiment.Span.Position{start_line: 7, start_column: 5}
            }
          ]
        }
      }
    }

    assert {:ok, refined} = RefineSpans.run(ir)
    [transition] = refined.states[:ready].transitions
    assert transition.span.start_line == 7
  end

  test "gracefully handles missing source file" do
    ir = %IR{
      name: Test,
      source_file: "/nonexistent/file.ex",
      initial: :ready,
      states: %{
        ready: %State{
          name: :ready,
          transitions: [],
          span: %Pentiment.Span.Position{start_line: 1, start_column: 1}
        }
      }
    }

    assert {:ok, _} = RefineSpans.run(ir)
  end

  test "passes through when source_file is nil" do
    ir = %IR{
      name: Test,
      source_file: nil,
      initial: :ready,
      states: %{}
    }

    assert {:ok, ^ir} = RefineSpans.run(ir)
  end
end
