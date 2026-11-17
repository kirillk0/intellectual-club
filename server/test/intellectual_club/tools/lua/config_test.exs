defmodule IntellectualClub.Tools.Lua.ConfigTest do
  use ExUnit.Case, async: true

  alias IntellectualClub.Tools.Lua.{Config, Http, Schema}

  describe "default/0 and metadata" do
    test "provides a valid counter with optional integer amounts and no network access" do
      config = Config.default()

      assert :ok = Config.validate(config)
      assert [] = Config.permissions(config)
      assert [] = Config.secret_names(config)
      assert [function] = Config.functions(config)
      assert function["name"] == "increment"
      assert function["enabled"] == true
      assert is_binary(function["description"])
      assert Enum.sort(Map.keys(function)) == ~w(description enabled name schema)
      assert function["schema"] == hd(config["manifest"]["functions"])["input_schema"]
      assert :ok = Schema.validate(%{}, function["schema"])
      assert :ok = Schema.validate(%{"amount" => -2}, function["schema"])
      assert {:error, _} = Schema.validate(%{"amount" => "2"}, function["schema"])
      assert {:error, _} = Schema.validate(%{"unexpected" => 1}, function["schema"])
      assert config["source"] =~ "exports.increment(args, ctx)"
      assert config["source"] =~ "ctx.state.count"
      assert String.ends_with?(String.trim(config["source"]), "return exports")
    end

    test "the default source exports a working counter using the supplied context state" do
      source = """
      local exports = (function()
      #{Config.default()["source"]}
      end)()
      local ctx = { state = {} }
      local first = exports.increment({}, ctx)
      local second = exports.increment({ amount = 4 }, ctx)
      local third = exports.increment({ amount = -2 }, ctx)
      return first.count, second.count, third.count, ctx.state.count
      """

      lua = Lua.new(max_instructions: 10_000, max_call_depth: 32, max_string_bytes: 65_536)
      assert {[1, 5, 3, 3], _lua} = Lua.eval!(lua, source)
    end

    test "preserves the manifest function order and schemas using string metadata keys" do
      first = function("z_first")
      second = function("a_second")
      config = put_in(Config.default(), ["manifest", "functions"], [first, second])

      assert :ok = Config.validate(config)
      assert Enum.map(Config.functions(config), & &1["name"]) == ["z_first", "a_second"]

      assert Enum.map(Config.functions(config), & &1["schema"]) ==
               [first["input_schema"], second["input_schema"]]
    end

    test "extracts HTTP rules and deduplicates secret names in first-seen order" do
      rules = [
        %{
          "url" => "https://api.example.com/v1/*",
          "methods" => ["GET"],
          "secrets" => ["TOKEN", "ACCOUNT"]
        },
        %{
          "url" => "https://api.example.com/v2/*",
          "methods" => ["POST"],
          "secrets" => ["ACCOUNT", "OTHER"]
        },
        %{"url" => "https://public.example.com/*", "methods" => ["GET"]}
      ]

      config = put_in(Config.default(), ["manifest", "permissions", "http"], rules)

      assert :ok = Config.validate(config)
      assert Config.permissions(config) == rules
      assert Config.secret_names(config) == ["TOKEN", "ACCOUNT", "OTHER"]
    end

    test "extraction helpers tolerate absent or incomplete configurations" do
      for config <- [
            nil,
            [],
            %{},
            %{"manifest" => nil},
            %{"manifest" => %{}},
            %{"manifest" => %{"functions" => [nil, %{}]}}
          ] do
        assert [] = Config.functions(config)
        assert [] = Config.permissions(config)
        assert [] = Config.secret_names(config)
      end
    end
  end

  describe "validate/1 configuration structure" do
    test "requires a string-keyed config and manifest with source and functions" do
      for config <- [
            nil,
            [],
            "config",
            %URI{},
            %{},
            %{"source" => "return {}"},
            %{"manifest" => %{}},
            %{"source" => "return {}", "manifest" => []}
          ] do
        assert {:error, message} = Config.validate(config)
        assert message =~ "config"
      end
    end

    test "rejects unknown fields at every configuration boundary" do
      default = Config.default()

      configs = [
        {Map.put(default, "timeout", 1), "config"},
        {put_in(default, ["manifest", "extra"], true), "manifest"},
        {put_in(default, ["manifest", "functions"], [Map.put(function(), "enabled", false)]),
         "functions[0]"},
        {put_in(default, ["manifest", "permissions", "files"], []), "permissions"}
      ]

      for {config, location} <- configs do
        assert {:error, message} = Config.validate(config)
        assert message =~ location
        assert message =~ "unknown field"
      end
    end

    test "rejects atom keys rather than coercing them" do
      default = Config.default()

      for config <- [
            Map.put(default, :source, "return {}"),
            put_in(default, ["manifest", :functions], []),
            put_in(default, ["manifest", "functions"], [Map.put(function(), :name, "run")]),
            put_in(default, ["manifest", "permissions", :http], [])
          ] do
        assert {:error, message} = Config.validate(config)
        assert message =~ "keys"
      end
    end

    test "accepts missing permissions and defaults to no HTTP access" do
      default = Config.default()
      no_permissions = update_in(default, ["manifest"], &Map.delete(&1, "permissions"))
      no_http = put_in(default, ["manifest", "permissions"], %{})

      for config <- [no_permissions, no_http] do
        assert :ok = Config.validate(config)
        assert [] = Config.permissions(config)
        assert [] = Config.secret_names(config)
      end

      for permissions <- [nil, [], true] do
        assert {:error, message} =
                 Config.validate(put_in(default, ["manifest", "permissions"], permissions))

        assert message =~ "permissions"
      end
    end
  end

  describe "source validation" do
    test "accepts exactly 64 KiB and rejects excess bytes including multibyte source" do
      assert :ok =
               Config.validate(Map.put(Config.default(), "source", String.duplicate("a", 65_536)))

      assert :ok =
               Config.validate(Map.put(Config.default(), "source", String.duplicate("я", 32_768)))

      for source <- [String.duplicate("a", 65_537), String.duplicate("я", 32_769)] do
        assert {:error, message} = Config.validate(Map.put(Config.default(), "source", source))
        assert message =~ "source"
        assert message =~ "65536"
      end
    end

    test "rejects non-string and invalid UTF-8 source" do
      for source <- [nil, 1, [], <<255>>] do
        assert {:error, message} = Config.validate(Map.put(Config.default(), "source", source))
        assert message =~ "source"
      end
    end

    test "does not parse or execute source while checking the manifest" do
      for source <- [
            "",
            "this is not valid Lua !!!",
            "while true do end",
            "error('must not execute')"
          ] do
        assert :ok = Config.validate(Map.put(Config.default(), "source", source))
      end
    end
  end

  describe "function validation" do
    test "requires a nonempty array with at most 32 functions" do
      functions = Enum.map(1..32, &function("function_#{&1}"))
      assert :ok = Config.validate(put_in(Config.default(), ["manifest", "functions"], functions))

      for functions <- [
            [],
            nil,
            %{},
            [nil],
            [function() | :invalid],
            functions ++ [function("last")]
          ] do
        assert {:error, message} =
                 Config.validate(put_in(Config.default(), ["manifest", "functions"], functions))

        assert message =~ "functions"
      end
    end

    test "requires unique case-sensitive names" do
      assert :ok = config_with_functions([function("run"), function("Run")]) |> Config.validate()

      assert {:error, message} =
               config_with_functions([function("run"), function("run")]) |> Config.validate()

      assert message =~ "functions[1].name"
      assert message =~ "duplicate"
    end

    test "requires names matching the ASCII identifier contract" do
      for name <- ["A", "run_1", String.duplicate("x", 64)] do
        assert :ok = config_with_functions([function(name)]) |> Config.validate()
      end

      for name <- [
            nil,
            1,
            "",
            "_run",
            "1run",
            "run-name",
            "run.name",
            "run\n",
            "счётчик",
            <<255>>,
            String.duplicate("x", 65)
          ] do
        assert {:error, message} = config_with_functions([function(name)]) |> Config.validate()
        assert message =~ ".name"
      end
    end

    test "requires descriptions and limits them to 4096 Unicode characters" do
      for description <- ["", String.duplicate("x", 4096), String.duplicate("я", 4096)] do
        assert :ok =
                 Config.validate(
                   config_with_functions([Map.put(function(), "description", description)])
                 )
      end

      for description <- [nil, 12, <<255>>, String.duplicate("x", 4097)] do
        assert {:error, message} =
                 Config.validate(
                   config_with_functions([Map.put(function(), "description", description)])
                 )

        assert message =~ ".description"
      end

      assert {:error, _} =
               Config.validate(config_with_functions([Map.delete(function(), "description")]))
    end

    test "requires an explicitly object-typed argument schema" do
      for schema <- [nil, true, %{}, %{"type" => "string"}, %{"type" => ["object", "null"]}] do
        assert {:error, message} =
                 Config.validate(
                   config_with_functions([Map.put(function(), "input_schema", schema)])
                 )

        assert message =~ ".input_schema"
      end
    end

    test "includes the function location in nested schema errors" do
      schema = %{"type" => "object", "properties" => %{"value" => %{"pattern" => "unsafe"}}}

      config =
        config_with_functions([function(), Map.put(function("other"), "input_schema", schema)])

      assert {:error, message} = Config.validate(config)
      assert message =~ "functions[1].input_schema"
      assert message =~ "value"
      assert message =~ "pattern"
    end

    test "never interns function names" do
      name = "lua_config_name_#{System.unique_integer([:positive])}"
      assert_raise ArgumentError, fn -> String.to_existing_atom(name) end
      assert :ok = Config.validate(config_with_functions([function(name)]))
      assert [%{"name" => ^name}] = Config.functions(config_with_functions([function(name)]))
      assert_raise ArgumentError, fn -> String.to_existing_atom(name) end
    end
  end

  describe "HTTP permissions validation" do
    test "delegates rules to the HTTP validator and preserves its error" do
      valid = %{
        "url" => "https://api.example.com/v1/*",
        "methods" => ["GET"],
        "secrets" => ["TOKEN"]
      }

      for rules <- [
            nil,
            %{},
            [Map.put(valid, "unknown", true)],
            [Map.put(valid, "methods", ["INVALID"])],
            [Map.put(valid, "secrets", [1])]
          ] do
        assert {:error, http_message} = Http.validate_permissions(rules)
        config = put_in(Config.default(), ["manifest", "permissions", "http"], rules)
        assert {:error, message} = Config.validate(config)
        assert message =~ "permissions.http"
        assert message =~ http_message
      end
    end
  end

  defp function(name \\ "run") do
    %{"name" => name, "description" => "Run a function.", "input_schema" => %{"type" => "object"}}
  end

  defp config_with_functions(functions),
    do: put_in(Config.default(), ["manifest", "functions"], functions)
end
