defmodule Accord.CompileErrorsTest do
  @moduledoc """
  Comprehensive compile-time error and span reporting tests.

  Verifies every validation pass error code at three levels:
  1. Report structure — correct error code, message text, and label count
  2. Span resolution — span labels point at the expected source tokens
  3. Formatted output — Pentiment rendering includes source context
  """
  use ExUnit.Case, async: true

  alias Accord.IR
  alias Accord.IR.{Branch, Check, Property, State, Track, Transition}
  alias Accord.Test.SpanHelper
  alias Pentiment.Span.Search

  # -- Helpers --

  # Writes source content to a temp file, returns {path, source} for span resolution.
  defp write_source(content) do
    tmp_dir = System.tmp_dir!()
    path = Path.join(tmp_dir, "compile_errors_test_#{:rand.uniform(1_000_000)}.ex")
    File.write!(path, content)
    on_exit(fn -> File.rm(path) end)
    source = Pentiment.Source.from_file(path)
    {path, source}
  end

  defp search_span(line, pattern) do
    Search.new(line: line, pattern: pattern)
  end

  defp format_report(report, source) do
    Pentiment.format(report, source, colors: false)
  end

  # Base IR with tracks, states, and transitions for property validation tests.
  defp property_ir(path, properties) do
    %IR{
      name: Test,
      source_file: path,
      initial: :unlocked,
      tracks: [
        %Track{name: :holder, type: :term, default: nil},
        %Track{name: :fence_token, type: :non_neg_integer, default: 0}
      ],
      states: %{
        unlocked: %State{
          name: :unlocked,
          transitions: [
            %Transition{
              message_pattern: {:acquire, :_},
              message_types: [:term],
              message_arg_names: ["cid"],
              kind: :call,
              branches: [
                %Branch{reply_type: {:tagged, :ok, :pos_integer}, next_state: :locked}
              ]
            }
          ]
        },
        locked: %State{
          name: :locked,
          transitions: [
            %Transition{
              message_pattern: {:release, :_},
              message_types: [:pos_integer],
              message_arg_names: ["token"],
              kind: :call,
              branches: [%Branch{reply_type: {:literal, :ok}, next_state: :unlocked}]
            }
          ]
        },
        stopped: %State{name: :stopped, terminal: true}
      },
      anystate: [
        %Transition{
          message_pattern: :ping,
          message_types: [],
          kind: :call,
          branches: [%Branch{reply_type: {:literal, :pong}, next_state: :__same__}]
        }
      ],
      properties: properties
    }
  end

  # ==================================================================
  # E001 — initial state undefined (ValidateStructure)
  # ==================================================================

  describe "E001 — initial state undefined" do
    test "report with correct code, message, and no labels" do
      ir = %IR{
        name: Test,
        initial: :nonexistent,
        states: %{ready: %State{name: :ready}}
      }

      assert {:error, [report]} = Accord.Pass.ValidateStructure.run(ir)
      assert report.code == "E001"
      assert report.message =~ "initial state :nonexistent is not defined"
      assert report.labels == []
    end
  end

  # ==================================================================
  # E002 — goto to undefined state (ValidateStructure)
  # ==================================================================

  describe "E002 — goto to undefined state" do
    setup do
      #                   line 1
      #                   line 2
      {path, source} =
        write_source("state :ready do\n  on :go, reply: :ok, goto: :nowhere\nend\n")

      %{path: path, source: source}
    end

    test "report, span, and formatted output", %{path: path, source: source} do
      ir = %IR{
        name: Test,
        source_file: path,
        initial: :ready,
        states: %{
          ready: %State{
            name: :ready,
            transitions: [
              %Transition{
                message_pattern: :go,
                message_types: [],
                kind: :call,
                branches: [
                  %Branch{
                    reply_type: {:literal, :ok},
                    next_state: :nowhere,
                    next_state_span: search_span(2, ":nowhere")
                  }
                ],
                span: search_span(2, ":go")
              }
            ]
          }
        }
      }

      assert {:error, [report]} = Accord.Pass.ValidateStructure.run(ir)
      assert report.code == "E002"
      assert report.message =~ "undefined state reference :nowhere"
      assert length(report.labels) == 1

      [label] = report.labels
      assert label.priority == :primary
      assert label.message =~ "goto target :nowhere is not defined"
      assert SpanHelper.resolve_text(label.span, source) == ":nowhere"

      formatted = format_report(report, source)
      assert formatted =~ "E002"
      assert formatted =~ "undefined state reference"
      assert formatted =~ ":nowhere"
    end
  end

  # ==================================================================
  # E003 — terminal state has transitions (ValidateStructure)
  # ==================================================================

  describe "E003 — terminal state has transitions" do
    setup do
      {path, source} = write_source("state :stopped, terminal: true\n")
      %{path: path, source: source}
    end

    test "report, span, and formatted output", %{path: path, source: source} do
      ir = %IR{
        name: Test,
        source_file: path,
        initial: :ready,
        states: %{
          ready: %State{
            name: :ready,
            transitions: [
              %Transition{
                message_pattern: :stop,
                message_types: [],
                kind: :call,
                branches: [%Branch{reply_type: {:literal, :stopped}, next_state: :stopped}]
              }
            ]
          },
          stopped: %State{
            name: :stopped,
            terminal: true,
            span: search_span(1, ":stopped"),
            transitions: [
              %Transition{
                message_pattern: :ping,
                message_types: [],
                kind: :call,
                branches: [%Branch{reply_type: {:literal, :pong}, next_state: :stopped}]
              }
            ]
          }
        }
      }

      assert {:error, [report]} = Accord.Pass.ValidateStructure.run(ir)
      assert report.code == "E003"
      assert report.message =~ "terminal state :stopped has transitions"
      assert length(report.labels) == 1

      [label] = report.labels
      assert label.priority == :primary
      assert label.message =~ "declared as terminal here"
      assert SpanHelper.resolve_text(label.span, source) == ":stopped"

      formatted = format_report(report, source)
      assert formatted =~ "E003"
      assert formatted =~ "terminal state"
      assert formatted =~ ":stopped"
    end
  end

  # ==================================================================
  # E010 — track default type mismatch (ValidateTypes)
  # ==================================================================

  describe "E010 — track default type mismatch" do
    setup do
      {path, source} = write_source("track :counter, :pos_integer, default: \"bad\"\n")
      %{path: path, source: source}
    end

    test "report, span, and formatted output", %{path: path, source: source} do
      ir = %IR{
        name: Test,
        source_file: path,
        initial: :ready,
        tracks: [
          %Track{
            name: :counter,
            type: :pos_integer,
            default: "bad",
            span: search_span(1, ":counter")
          }
        ],
        states: %{
          ready: %State{name: :ready, terminal: true}
        }
      }

      assert {:error, [report]} = Accord.Pass.ValidateTypes.run(ir)
      assert report.code == "E010"
      assert report.message =~ "track :counter"
      assert report.message =~ "does not conform to type"
      assert length(report.labels) == 1

      [label] = report.labels
      assert label.priority == :primary
      assert label.message =~ "declared here"
      assert SpanHelper.resolve_text(label.span, source) == ":counter"

      formatted = format_report(report, source)
      assert formatted =~ "E010"
      assert formatted =~ ":counter"
    end
  end

  # ==================================================================
  # E011 — call transition with no branches (ValidateTypes)
  # ==================================================================

  describe "E011 — call transition with no branches" do
    setup do
      {path, source} = write_source("state :ready do\n  on :ping, goto: :ready\nend\n")
      %{path: path, source: source}
    end

    test "report, span, and formatted output", %{path: path, source: source} do
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
                branches: [],
                span: search_span(2, ":ping")
              }
            ]
          }
        }
      }

      assert {:error, [report]} = Accord.Pass.ValidateTypes.run(ir)
      assert report.code == "E011"
      assert report.message =~ "call transition has no branches"
      assert length(report.labels) == 1

      [label] = report.labels
      assert label.priority == :primary
      assert label.message =~ "this transition needs a reply type"
      assert SpanHelper.resolve_text(label.span, source) == ":ping"

      formatted = format_report(report, source)
      assert formatted =~ "E011"
      assert formatted =~ ":ping"
    end
  end

  # ==================================================================
  # E020 — ambiguous dispatch (ValidateDeterminism)
  # ==================================================================

  describe "E020 — ambiguous dispatch" do
    setup do
      {path, source} =
        write_source(
          "state :ready do\n  on :ping, reply: :pong, goto: :ready\n  on :ping, reply: :ok, goto: :ready\nend\n"
        )

      %{path: path, source: source}
    end

    test "report with primary and secondary labels", %{path: path, source: source} do
      span1 = search_span(2, ":ping")
      span2 = search_span(3, ":ping")

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
                span: span1
              },
              %Transition{
                message_pattern: :ping,
                message_types: [],
                kind: :call,
                branches: [%Branch{reply_type: {:literal, :ok}, next_state: :ready}],
                span: span2
              }
            ]
          }
        }
      }

      assert {:error, [report]} = Accord.Pass.ValidateDeterminism.run(ir)
      assert report.code == "E020"
      assert report.message =~ "ambiguous dispatch"
      assert report.message =~ ":ping"
      assert length(report.labels) == 2

      [first, second] = report.labels
      assert first.priority == :primary
      assert first.message =~ "first definition"
      assert second.priority == :secondary
      assert second.message =~ "conflicts with first"

      assert SpanHelper.resolve_text(first.span, source) == ":ping"
      assert SpanHelper.resolve_text(second.span, source) == ":ping"

      formatted = format_report(report, source)
      assert formatted =~ "E020"
      assert formatted =~ "ambiguous dispatch"
      assert formatted =~ "first definition"
    end
  end

  # ==================================================================
  # E030 — bounded check undefined track (ValidateProperties)
  # ==================================================================

  describe "E030 — bounded check undefined track" do
    setup do
      {path, source} =
        write_source("property :bad_bounded do\n  bounded :nonexistent, max: 100\nend\n")

      %{path: path, source: source}
    end

    test "report, span, and formatted output", %{path: path, source: source} do
      ir =
        property_ir(path, [
          %Property{
            name: :bad_bounded,
            checks: [
              %Check{
                kind: :bounded,
                spec: %{track: :nonexistent, max: 100},
                span: search_span(2, "bounded")
              }
            ]
          }
        ])

      assert {:error, [report]} = Accord.Pass.ValidateProperties.run(ir)
      assert report.code == "E030"
      assert report.message =~ "bounded check references undefined track :nonexistent"
      assert length(report.labels) == 1

      [label] = report.labels
      assert label.priority == :primary
      assert label.message =~ "track :nonexistent is not defined"
      assert SpanHelper.resolve_text(label.span, source) == ":nonexistent"

      formatted = format_report(report, source)
      assert formatted =~ "E030"
      assert formatted =~ ":nonexistent"
    end
  end

  # ==================================================================
  # E031 — correspondence check undefined event (ValidateProperties)
  # ==================================================================

  describe "E031 — correspondence undefined event" do
    setup do
      {path, source} =
        write_source(
          "property :bad_corr do\n  correspondence :nonexistent, close: [:release]\nend\n"
        )

      %{path: path, source: source}
    end

    test "report, span, and formatted output", %{path: path, source: source} do
      ir =
        property_ir(path, [
          %Property{
            name: :bad_corr,
            checks: [
              %Check{
                kind: :correspondence,
                spec: %{open: :nonexistent, close: [:release]},
                span: search_span(2, "correspondence")
              }
            ]
          }
        ])

      assert {:error, [report]} = Accord.Pass.ValidateProperties.run(ir)
      assert report.code == "E031"
      assert report.message =~ "correspondence check references undefined open event :nonexistent"
      assert length(report.labels) == 1

      [label] = report.labels
      assert label.message =~ "does not appear in any transition"
      assert SpanHelper.resolve_text(label.span, source) == ":nonexistent"

      formatted = format_report(report, source)
      assert formatted =~ "E031"
      assert formatted =~ ":nonexistent"
    end
  end

  # ==================================================================
  # E032 — local invariant undefined state (ValidateProperties)
  # ==================================================================

  describe "E032 — local invariant undefined state" do
    setup do
      {path, source} =
        write_source(
          "property :bad_inv do\n  invariant :nonexistent, fn _msg, _tracks -> true end\nend\n"
        )

      %{path: path, source: source}
    end

    test "report, span, and formatted output", %{path: path, source: source} do
      ir =
        property_ir(path, [
          %Property{
            name: :bad_inv,
            checks: [
              %Check{
                kind: :local_invariant,
                spec: %{state: :nonexistent, fun: fn _msg, _tracks -> true end},
                span: search_span(2, "invariant")
              }
            ]
          }
        ])

      assert {:error, [report]} = Accord.Pass.ValidateProperties.run(ir)
      assert report.code == "E032"
      assert report.message =~ "local_invariant check references undefined state :nonexistent"
      assert length(report.labels) == 1

      [label] = report.labels
      assert label.message =~ "state :nonexistent is not defined"
      assert SpanHelper.resolve_text(label.span, source) == ":nonexistent"

      formatted = format_report(report, source)
      assert formatted =~ "E032"
    end
  end

  # ==================================================================
  # E033 — reachable undefined state (ValidateProperties)
  # ==================================================================

  describe "E033 — reachable undefined state" do
    setup do
      {path, source} = write_source("property :bad_reach do\n  reachable :nonexistent\nend\n")
      %{path: path, source: source}
    end

    test "report, span, and formatted output", %{path: path, source: source} do
      ir =
        property_ir(path, [
          %Property{
            name: :bad_reach,
            checks: [
              %Check{
                kind: :reachable,
                spec: %{target: :nonexistent},
                span: search_span(2, "reachable")
              }
            ]
          }
        ])

      assert {:error, [report]} = Accord.Pass.ValidateProperties.run(ir)
      assert report.code == "E033"
      assert report.message =~ "reachable check references undefined state :nonexistent"
      assert length(report.labels) == 1

      [label] = report.labels
      assert label.message =~ "state :nonexistent is not defined"
      assert SpanHelper.resolve_text(label.span, source) == ":nonexistent"

      formatted = format_report(report, source)
      assert formatted =~ "E033"
    end
  end

  # ==================================================================
  # E034 — precedence undefined state (ValidateProperties)
  # ==================================================================

  describe "E034 — precedence undefined state" do
    setup do
      {path, source} =
        write_source("property :bad_prec do\n  precedence :nonexistent, :also_missing\nend\n")

      %{path: path, source: source}
    end

    test "produces two E034 errors for target and required", %{path: path, source: source} do
      span = search_span(2, "precedence")

      ir =
        property_ir(path, [
          %Property{
            name: :bad_prec,
            checks: [
              %Check{
                kind: :precedence,
                spec: %{target: :nonexistent, required: :also_missing},
                span: span
              }
            ]
          }
        ])

      assert {:error, reports} = Accord.Pass.ValidateProperties.run(ir)
      assert length(reports) == 2

      [target_report, required_report] = reports
      assert target_report.code == "E034"
      assert target_report.message =~ "target state :nonexistent"
      assert required_report.code == "E034"
      assert required_report.message =~ "required state :also_missing"

      # Each label points at its specific argument.
      assert length(target_report.labels) == 1
      [target_label] = target_report.labels
      assert SpanHelper.resolve_text(target_label.span, source) == ":nonexistent"

      assert length(required_report.labels) == 1
      [required_label] = required_report.labels
      assert SpanHelper.resolve_text(required_label.span, source) == ":also_missing"

      formatted = format_report(target_report, source)
      assert formatted =~ "E034"
      assert formatted =~ ":nonexistent"
    end
  end

  # ==================================================================
  # E035 — field path unknown event (ResolveFieldPaths)
  # ==================================================================

  describe "E035 — field path unknown event" do
    setup do
      {path, source} =
        write_source("property :bad_ordered do\n  ordered :nonexistent, by: :cid\nend\n")

      %{path: path, source: source}
    end

    test "report, span on check argument, and formatted output", %{path: path, source: source} do
      ir =
        property_ir(path, [
          %Property{
            name: :bad_ordered,
            span: search_span(1, ":bad_ordered"),
            checks: [
              %Check{
                kind: :ordered,
                spec: %{event: :nonexistent, by: :cid},
                span: search_span(2, "ordered")
              }
            ]
          }
        ])

      assert {:error, [report]} = Accord.Pass.ResolveFieldPaths.run(ir)
      assert report.code == "E035"
      assert report.message =~ "field path references unknown event :nonexistent"
      assert length(report.labels) == 1

      [label] = report.labels
      assert label.message =~ "event :nonexistent does not appear in any transition"
      assert SpanHelper.resolve_text(label.span, source) == ":nonexistent"

      formatted = format_report(report, source)
      assert formatted =~ "E035"
      assert formatted =~ ":nonexistent"
    end
  end

  # ==================================================================
  # E036 — field name not in parameters (ResolveFieldPaths)
  # ==================================================================

  describe "E036 — field name not in parameters" do
    setup do
      {path, source} =
        write_source("property :bad_field do\n  ordered :acquire, by: :nonexistent\nend\n")

      %{path: path, source: source}
    end

    test "report, span on check argument, and formatted output", %{path: path, source: source} do
      ir =
        property_ir(path, [
          %Property{
            name: :bad_field,
            span: search_span(1, ":bad_field"),
            checks: [
              %Check{
                kind: :ordered,
                spec: %{event: :acquire, by: :nonexistent},
                span: search_span(2, "ordered")
              }
            ]
          }
        ])

      assert {:error, [report]} = Accord.Pass.ResolveFieldPaths.run(ir)
      assert report.code == "E036"
      assert report.message =~ "field :nonexistent not found in :acquire message parameters"
      assert length(report.labels) == 1

      [label] = report.labels
      assert label.message =~ ":nonexistent is not a parameter of :acquire"
      assert SpanHelper.resolve_text(label.span, source) == ":nonexistent"

      formatted = format_report(report, source)
      assert formatted =~ "E036"
      assert formatted =~ ":nonexistent"
    end
  end

  # ==================================================================
  # W001 — unreachable state (ValidateReachability)
  # ==================================================================

  describe "W001 — unreachable state" do
    setup do
      {path, source} =
        write_source("state :orphan do\n  on :wake, reply: :ok, goto: :ready\nend\n")

      %{path: path, source: source}
    end

    test "warning with span on unreachable state", %{path: path, source: source} do
      ir = %IR{
        name: Test,
        source_file: path,
        initial: :ready,
        states: %{
          ready: %State{
            name: :ready,
            transitions: [
              %Transition{
                message_pattern: :stop,
                message_types: [],
                kind: :call,
                branches: [%Branch{reply_type: {:literal, :stopped}, next_state: :stopped}]
              }
            ]
          },
          stopped: %State{name: :stopped, terminal: true},
          orphan: %State{
            name: :orphan,
            span: search_span(1, ":orphan"),
            transitions: [
              %Transition{
                message_pattern: :wake,
                message_types: [],
                kind: :call,
                branches: [%Branch{reply_type: {:literal, :ok}, next_state: :ready}]
              }
            ]
          }
        }
      }

      warnings = Accord.Pass.ValidateReachability.warnings(ir)
      assert [report] = warnings
      assert report.code == "W001"
      assert report.severity == :warning
      assert report.message =~ "state :orphan is unreachable"
      assert length(report.labels) == 1

      [label] = report.labels
      assert label.message =~ "unreachable state"
      assert SpanHelper.resolve_text(label.span, source) == ":orphan"

      formatted = format_report(report, source)
      assert formatted =~ "W001"
      assert formatted =~ ":orphan"
    end
  end

  # ==================================================================
  # W002 — no terminal state reachable (ValidateReachability)
  # ==================================================================

  describe "W002 — no terminal reachable" do
    test "warning with no labels" do
      ir = %IR{
        name: Test,
        initial: :ready,
        states: %{
          ready: %State{
            name: :ready,
            transitions: [
              %Transition{
                message_pattern: :ping,
                message_types: [],
                kind: :call,
                branches: [%Branch{reply_type: {:literal, :pong}, next_state: :ready}]
              }
            ]
          },
          done: %State{
            name: :done,
            terminal: true
          }
        }
      }

      warnings = Accord.Pass.ValidateReachability.warnings(ir)
      assert [report] = warnings
      assert report.code == "W002"
      assert report.severity == :warning
      assert report.message =~ "no terminal state is reachable"
      assert report.labels == []
    end
  end

  # ==================================================================
  # Nil span graceful degradation
  # ==================================================================

  describe "nil span graceful degradation" do
    test "E002 with nil transition span produces report without labels" do
      ir = %IR{
        name: Test,
        initial: :ready,
        states: %{
          ready: %State{
            name: :ready,
            transitions: [
              %Transition{
                message_pattern: :go,
                message_types: [],
                kind: :call,
                branches: [%Branch{reply_type: {:literal, :ok}, next_state: :nowhere}],
                span: nil
              }
            ]
          }
        }
      }

      assert {:error, [report]} = Accord.Pass.ValidateStructure.run(ir)
      assert report.code == "E002"
      assert report.labels == []
    end

    test "E020 with nil transition spans produces report without labels" do
      ir = %IR{
        name: Test,
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
                span: nil
              },
              %Transition{
                message_pattern: :ping,
                message_types: [],
                kind: :call,
                branches: [%Branch{reply_type: {:literal, :ok}, next_state: :ready}],
                span: nil
              }
            ]
          }
        }
      }

      assert {:error, [report]} = Accord.Pass.ValidateDeterminism.run(ir)
      assert report.code == "E020"
      assert report.labels == []
    end
  end

  # ==================================================================
  # Multiple errors
  # ==================================================================

  describe "multiple errors" do
    test "ValidateStructure collects E001 and E002 together" do
      ir = %IR{
        name: Test,
        initial: :nonexistent,
        states: %{
          ready: %State{
            name: :ready,
            transitions: [
              %Transition{
                message_pattern: :go,
                message_types: [],
                kind: :call,
                branches: [%Branch{reply_type: {:literal, :ok}, next_state: :also_missing}]
              }
            ]
          }
        }
      }

      assert {:error, errors} = Accord.Pass.ValidateStructure.run(ir)
      assert length(errors) >= 2
      codes = Enum.map(errors, & &1.code)
      assert "E001" in codes
      assert "E002" in codes
    end

    test "ValidateProperties collects multiple property errors" do
      ir =
        property_ir(nil, [
          %Property{
            name: :bad_bounded,
            checks: [
              %Check{kind: :bounded, spec: %{track: :nonexistent, max: 100}}
            ]
          },
          %Property{
            name: :bad_reachable,
            checks: [
              %Check{kind: :reachable, spec: %{target: :nonexistent}}
            ]
          }
        ])

      assert {:error, errors} = Accord.Pass.ValidateProperties.run(ir)
      assert length(errors) == 2
      codes = Enum.map(errors, & &1.code)
      assert "E030" in codes
      assert "E033" in codes
    end
  end

  # ==================================================================
  # Integration tests — full DSL → IR → validation → CompileError
  # ==================================================================

  describe "integration — E001 via DSL" do
    test "initial state not in states map raises CompileError" do
      error =
        assert_raise CompileError, fn ->
          defmodule IntE001 do
            use Accord.Protocol

            initial :nonexistent
            state :ready, terminal: true
          end
        end

      assert error.description =~ "E001"
      assert error.description =~ "initial state :nonexistent is not defined"
    end
  end

  describe "integration — E002 via DSL" do
    test "goto to undefined state raises CompileError with source context" do
      error =
        assert_raise CompileError, fn ->
          defmodule IntE002 do
            use Accord.Protocol

            initial :ready

            state :ready do
              on :go, reply: :ok, goto: :nowhere
            end
          end
        end

      assert error.description =~ "E002"
      assert error.description =~ "undefined state reference :nowhere"
      # Label message proves the span was resolved and rendered.
      assert error.description =~ "goto target :nowhere is not defined"
      # Source context shows the DSL line; span resolves to :nowhere.
      assert error.description =~ "on :go, reply: :ok, goto: :nowhere"
    end
  end

  describe "integration — E010 via DSL" do
    test "track default type mismatch raises CompileError" do
      error =
        assert_raise CompileError, fn ->
          defmodule IntE010 do
            use Accord.Protocol

            initial :ready

            track :counter, :pos_integer, default: "bad"

            state :ready do
              on :stop, reply: :stopped, goto: :stopped
            end

            state :stopped, terminal: true
          end
        end

      assert error.description =~ "E010"
      assert error.description =~ "track :counter"
      # Label message proves the span was resolved and rendered.
      assert error.description =~ "declared here"
      # Source context shows the DSL line; span resolves to :counter.
      assert error.description =~ "track :counter, :pos_integer"
    end
  end

  describe "integration — E020 via DSL" do
    test "ambiguous dispatch raises CompileError with source context" do
      error =
        assert_raise CompileError, fn ->
          defmodule IntE020 do
            use Accord.Protocol

            initial :ready

            state :ready do
              on :ping, reply: :pong, goto: :ready
              on :ping, reply: :ok, goto: :ready
              on :stop, reply: :stopped, goto: :stopped
            end

            state :stopped, terminal: true
          end
        end

      assert error.description =~ "E020"
      assert error.description =~ "ambiguous dispatch"
      # Both span labels rendered; span resolves to :ping on each line.
      assert error.description =~ "first definition"
      assert error.description =~ "conflicts with first"
      assert error.description =~ "on :ping, reply: :pong, goto: :ready"
      assert error.description =~ "on :ping, reply: :ok, goto: :ready"
    end
  end

  describe "integration — E030 via DSL" do
    test "bounded check with undefined track raises CompileError" do
      error =
        assert_raise CompileError, fn ->
          defmodule IntE030 do
            use Accord.Protocol

            initial :ready

            state :ready do
              on :stop, reply: :stopped, goto: :stopped
            end

            state :stopped, terminal: true

            property :bad_bounded do
              bounded :nonexistent, max: 100
            end
          end
        end

      assert error.description =~ "E030"
      assert error.description =~ "bounded check references undefined track :nonexistent"
      # Label message proves the span was resolved and rendered.
      assert error.description =~ "track :nonexistent is not defined"
      # Source context shows the check line; span resolves to :nonexistent.
      assert error.description =~ "bounded :nonexistent"
    end
  end

  describe "integration — E033 via DSL" do
    test "reachable check with undefined state raises CompileError" do
      error =
        assert_raise CompileError, fn ->
          defmodule IntE033 do
            use Accord.Protocol

            initial :ready

            state :ready do
              on :stop, reply: :stopped, goto: :stopped
            end

            state :stopped, terminal: true

            property :bad_reachable do
              reachable :nonexistent
            end
          end
        end

      assert error.description =~ "E033"
      assert error.description =~ "reachable check references undefined state :nonexistent"
      # Label message proves the span was resolved and rendered.
      assert error.description =~ "state :nonexistent is not defined"
      # Source context shows the check line; span resolves to :nonexistent.
      assert error.description =~ "reachable :nonexistent"
    end
  end
end
