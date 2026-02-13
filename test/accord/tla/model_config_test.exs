defmodule Accord.TLA.ModelConfigTest do
  use ExUnit.Case, async: true

  alias Accord.TLA.ModelConfig

  describe "builtin_defaults/0" do
    test "contains standard type domains" do
      defaults = ModelConfig.builtin_defaults()

      assert defaults[:pos_integer] == 1..3
      assert defaults[:non_neg_integer] == 0..3
      assert defaults[:integer] == -2..2
      assert defaults[:boolean] == [true, false]
      assert defaults[:atom] == {:model_values, 3}
      assert defaults[:term] == {:model_values, 3}
    end
  end

  describe "load/1" do
    @tag :tmp_dir
    test "returns empty config when no files exist", %{tmp_dir: tmp_dir} do
      config = ModelConfig.load(project_root: tmp_dir)

      assert config.domains == %{}
      assert config.symmetry_sets == []
      assert config.max_list_length == 3
    end

    @tag :tmp_dir
    test "loads project-wide config from .accord_model.exs", %{tmp_dir: tmp_dir} do
      config_path = Path.join(tmp_dir, ".accord_model.exs")

      File.write!(config_path, """
      [
        domains: %{
          pos_integer: 1..5,
          client_id: {:model_values, [:c1, :c2, :c3]}
        },
        max_list_length: 5
      ]
      """)

      config = ModelConfig.load(project_root: tmp_dir)

      assert config.domains[:pos_integer] == 1..5
      assert config.domains[:client_id] == {:model_values, [:c1, :c2, :c3]}
      assert config.max_list_length == 5
    end

    @tag :tmp_dir
    test "loads per-protocol config", %{tmp_dir: tmp_dir} do
      protocol_path = Path.join(tmp_dir, "lock_model.exs")

      File.write!(protocol_path, """
      [
        domains: %{
          token: 1..10,
          client_id: {:model_values, [:c1, :c2]}
        },
        symmetry_sets: [:client_id]
      ]
      """)

      config = ModelConfig.load(protocol_config_path: protocol_path)

      assert config.domains[:token] == 1..10
      assert config.domains[:client_id] == {:model_values, [:c1, :c2]}
      assert config.symmetry_sets == [:client_id]
    end

    @tag :tmp_dir
    test "protocol config overrides project config", %{tmp_dir: tmp_dir} do
      project_path = Path.join(tmp_dir, ".accord_model.exs")

      File.write!(project_path, """
      [
        domains: %{
          pos_integer: 1..5,
          client_id: {:model_values, 4}
        }
      ]
      """)

      protocol_path = Path.join(tmp_dir, "lock_model.exs")

      File.write!(protocol_path, """
      [
        domains: %{
          client_id: {:model_values, [:c1, :c2]}
        }
      ]
      """)

      config =
        ModelConfig.load(
          project_root: tmp_dir,
          protocol_config_path: protocol_path
        )

      # Protocol overrides project for client_id.
      assert config.domains[:client_id] == {:model_values, [:c1, :c2]}
      # Project value preserved for pos_integer.
      assert config.domains[:pos_integer] == 1..5
    end
  end

  describe "resolve_domain/3" do
    test "parameter name takes priority over type" do
      config = %ModelConfig{
        domains: %{
          token: 1..10,
          pos_integer: 1..5
        }
      }

      assert ModelConfig.resolve_domain(config, :token, :pos_integer) == 1..10
    end

    test "falls back to type name" do
      config = %ModelConfig{
        domains: %{
          pos_integer: 1..5
        }
      }

      assert ModelConfig.resolve_domain(config, :unknown_param, :pos_integer) == 1..5
    end

    test "falls back to built-in default" do
      config = %ModelConfig{domains: %{}}

      assert ModelConfig.resolve_domain(config, :unknown_param, :pos_integer) == 1..3
    end

    test "unknown type falls back to model_values" do
      config = %ModelConfig{domains: %{}}

      assert ModelConfig.resolve_domain(config, :unknown, :unknown_type) == {:model_values, 3}
    end
  end

  describe "resolve_init/3" do
    test "returns override when present" do
      config = %ModelConfig{init: %{balance: 3}}

      assert ModelConfig.resolve_init(config, :balance, 1000) == 3
    end

    test "falls back to protocol default when no override" do
      config = %ModelConfig{init: %{}}

      assert ModelConfig.resolve_init(config, :balance, 1000) == 1000
    end
  end

  describe "init field" do
    @tag :tmp_dir
    test "parsed from config file", %{tmp_dir: tmp_dir} do
      config_path = Path.join(tmp_dir, "model.exs")

      File.write!(config_path, """
      [
        domains: %{balance: 0..6},
        init: %{balance: 3}
      ]
      """)

      config = ModelConfig.load(protocol_config_path: config_path)

      assert config.init == %{balance: 3}
    end

    @tag :tmp_dir
    test "protocol init overrides project init", %{tmp_dir: tmp_dir} do
      project_path = Path.join(tmp_dir, ".accord_model.exs")

      File.write!(project_path, """
      [
        init: %{balance: 5, counter: 0}
      ]
      """)

      protocol_path = Path.join(tmp_dir, "model.exs")

      File.write!(protocol_path, """
      [
        init: %{balance: 3}
      ]
      """)

      config =
        ModelConfig.load(
          project_root: tmp_dir,
          protocol_config_path: protocol_path
        )

      # Protocol overrides project for balance.
      assert config.init[:balance] == 3
      # Project value preserved for counter.
      assert config.init[:counter] == 0
    end

    test "defaults to empty map" do
      config = %ModelConfig{}

      assert config.init == %{}
    end
  end

  describe "domain_to_tla/1" do
    test "range" do
      assert ModelConfig.domain_to_tla(1..5) == "1..5"
    end

    test "explicit atom list" do
      assert ModelConfig.domain_to_tla([:a, :b, :c]) == ~s({"a", "b", "c"})
    end

    test "explicit integer list" do
      assert ModelConfig.domain_to_tla([0, 1, 2]) == "{0, 1, 2}"
    end

    test "model values by count" do
      assert ModelConfig.domain_to_tla({:model_values, 3}) == "{mv1, mv2, mv3}"
    end

    test "model values by name" do
      assert ModelConfig.domain_to_tla({:model_values, [:c1, :c2]}) == "{c1, c2}"
    end

    test "boolean list" do
      assert ModelConfig.domain_to_tla([true, false]) == ~s({"true", "false"})
    end
  end
end
