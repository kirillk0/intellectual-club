defmodule IntellectualClub.Tools.Lua.SchemaTest do
  use ExUnit.Case, async: true

  alias IntellectualClub.Tools.Lua.Schema

  describe "validate_schema/1" do
    test "accepts empty schemas and nested supported keywords" do
      schema = %{
        "type" => "object",
        "title" => "Arguments",
        "description" => "Tool arguments.",
        "properties" => %{
          "rows" => %{
            "type" => "array",
            "items" => %{"type" => ["integer", "null"]},
            "minItems" => 0,
            "maxItems" => 10
          },
          "label" => %{
            "type" => "string",
            "minLength" => 1,
            "maxLength" => 20,
            "default" => "label"
          },
          "amount" => %{
            "type" => "number",
            "minimum" => 0,
            "maximum" => 100,
            "exclusiveMinimum" => -1,
            "exclusiveMaximum" => 101,
            "multipleOf" => 0.5
          },
          "kind" => %{"enum" => ["a", "b"], "const" => "a"},
          "options" => %{"type" => "object", "additionalProperties" => %{"type" => "boolean"}}
        },
        "required" => ["rows"],
        "additionalProperties" => false,
        "anyOf" => [%{"required" => ["label"]}, %{"required" => ["amount"]}],
        "oneOf" => [%{"required" => ["kind"]}, %{"required" => ["options"]}],
        "allOf" => [%{"type" => "object"}]
      }

      assert :ok = Schema.validate_schema(%{})
      assert :ok = Schema.validate_schema(schema)
    end

    test "requires JSON schema objects with string keys" do
      for schema <- [nil, true, false, [], "object", %URI{}, %{type: "object"}] do
        assert {:error, message} = Schema.validate_schema(schema)
        assert message =~ "schema"
      end
    end

    test "rejects unknown and unsupported keywords instead of ignoring them" do
      for keyword <-
            ~w($ref $defs $schema definitions pattern patternProperties format not uniqueItems nullable unknown) do
        assert {:error, message} = Schema.validate_schema(%{keyword => "ignored"})
        assert message =~ keyword
        assert message =~ "unsupported"
      end
    end

    test "requires known types or a nonempty list of distinct known types" do
      for type <- ~w(object array string number integer boolean null) ++ [["string", "null"]] do
        assert :ok = Schema.validate_schema(%{"type" => type})
      end

      for type <- [
            nil,
            true,
            1,
            "Object",
            "unknown",
            [],
            ["string", "unknown"],
            ["string", "string"]
          ] do
        assert {:error, message} = Schema.validate_schema(%{"type" => type})
        assert message =~ "type"
      end
    end

    test "validates property, item and additional-property schemas recursively" do
      for schema <- [
            %{"properties" => []},
            %{"properties" => %{"name" => true}},
            %{"properties" => %{"name" => %{"unknown" => true}}},
            %{"items" => []},
            %{"items" => false},
            %{"additionalProperties" => "true"},
            %{"additionalProperties" => %{"$ref" => "https://example.com/schema"}}
          ] do
        assert {:error, _message} = Schema.validate_schema(schema)
      end

      for value <- [true, false, %{}] do
        assert :ok = Schema.validate_schema(%{"additionalProperties" => value})
      end
    end

    test "required contains only unique string names" do
      assert :ok = Schema.validate_schema(%{"required" => []})
      assert :ok = Schema.validate_schema(%{"required" => ["", "name"]})

      for value <- [nil, true, "name", [1], ["name", "name"]] do
        assert {:error, message} = Schema.validate_schema(%{"required" => value})
        assert message =~ "required"
      end
    end

    test "validates count and numeric bounds" do
      for keyword <- ~w(minItems maxItems minLength maxLength) do
        for value <- [0, 2, 2.0] do
          assert :ok = Schema.validate_schema(%{keyword => value})
        end

        for value <- [-1, 0.5, "1", true, nil] do
          assert {:error, message} = Schema.validate_schema(%{keyword => value})
          assert message =~ keyword
        end
      end

      for keyword <- ~w(min max minimum maximum exclusiveMinimum exclusiveMaximum) do
        assert :ok = Schema.validate_schema(%{keyword => -0.5})

        for value <- [nil, true, "1"] do
          assert {:error, message} = Schema.validate_schema(%{keyword => value})
          assert message =~ keyword
        end
      end

      for value <- [0, -1, nil, true, "0.1"] do
        assert {:error, message} = Schema.validate_schema(%{"multipleOf" => value})
        assert message =~ "multipleOf"
      end
    end

    test "requires nonempty enum arrays unique under JSON numeric equality" do
      assert :ok = Schema.validate_schema(%{"enum" => [nil, false, 1, "1", [], %{}]})

      for values <- [[], nil, %{}, [1, 1.0], [[1], [1.0]], [%{"x" => 1}, %{"x" => 1.0}]] do
        assert {:error, message} = Schema.validate_schema(%{"enum" => values})
        assert message =~ "enum"
      end
    end

    test "annotations are typed but defaults remain annotations" do
      assert :ok = Schema.validate_schema(%{"type" => "string", "default" => 1})

      for keyword <- ~w(description title) do
        assert {:error, message} = Schema.validate_schema(%{keyword => 1})
        assert message =~ keyword
      end
    end

    test "requires nonempty arrays of schemas for combinators" do
      for keyword <- ~w(anyOf oneOf allOf) do
        assert :ok = Schema.validate_schema(%{keyword => [%{}]})

        for value <- [[], %{}, nil, [false], [%{"unknown" => true}]] do
          assert {:error, message} = Schema.validate_schema(%{keyword => value})
          assert message =~ keyword
        end
      end
    end

    test "enforces the encoded 64 KiB boundary including JSON escaping" do
      base = %{"type" => "object", "description" => ""}
      remaining = 65_536 - byte_size(Jason.encode!(base))
      schema = Map.put(base, "description", String.duplicate("a", remaining))

      assert byte_size(Jason.encode!(schema)) == 65_536
      assert :ok = Schema.validate_schema(schema)

      assert {:error, message} =
               Schema.validate_schema(Map.update!(schema, "description", &(&1 <> "a")))

      assert message =~ "65536"

      assert {:error, _} =
               Schema.validate_schema(%{"description" => String.duplicate("\n", 33_000)})

      assert {:error, _} = Schema.validate_schema(%{"enum" => Enum.to_list(1..20_000)})
    end

    test "limits nested schema and annotation containers to 32 levels" do
      schema = Enum.reduce(1..31, %{}, fn _, nested -> %{"items" => nested} end)
      assert :ok = Schema.validate_schema(schema)
      assert {:error, message} = Schema.validate_schema(%{"items" => schema})
      assert message =~ "32 levels"

      annotation = Enum.reduce(1..31, nil, fn _, nested -> [nested] end)
      assert :ok = Schema.validate_schema(%{"default" => annotation})
      assert {:error, _} = Schema.validate_schema(%{"default" => [annotation]})
    end

    test "rejects non-JSON values and invalid UTF-8 in all schema positions" do
      for schema <- [
            %{"description" => <<255>>},
            %{"properties" => %{<<255>> => %{}}},
            %{"default" => %{"nested" => :atom}},
            %{"const" => {1, 2}},
            %{"enum" => [%{key: "value"}]},
            %{"default" => %URI{}},
            %{"required" => ["name" | :invalid]}
          ] do
        assert {:error, _message} = Schema.validate_schema(schema)
      end
    end

    test "never interns property names or schema keywords" do
      name = "lua_schema_key_#{System.unique_integer([:positive])}"
      assert_raise ArgumentError, fn -> String.to_existing_atom(name) end
      assert :ok = Schema.validate_schema(%{"properties" => %{name => %{}}})
      assert :ok = Schema.validate(%{name => 1}, %{"properties" => %{name => %{}}})
      assert {:error, _} = Schema.validate_schema(%{name => true})
      assert_raise ArgumentError, fn -> String.to_existing_atom(name) end
    end
  end

  describe "validate/2" do
    test "checks each JSON type and union types without coercion" do
      cases = [
        {"object", %{}, []},
        {"array", [], %{}},
        {"string", "1", 1},
        {"number", 1.5, "1.5"},
        {"integer", 2.0, 2.1},
        {"boolean", false, 0},
        {"null", nil, false}
      ]

      for {type, valid, invalid} <- cases do
        assert :ok = Schema.validate(valid, %{"type" => type})
        assert {:error, message} = Schema.validate(invalid, %{"type" => type})
        assert message =~ type
      end

      assert :ok = Schema.validate(nil, %{"type" => ["string", "null"]})
      assert :ok = Schema.validate("value", %{"type" => ["string", "null"]})
      assert {:error, _} = Schema.validate(false, %{"type" => ["string", "null"]})
    end

    test "validates required fields and additional properties without inserting defaults" do
      schema = %{
        "type" => "object",
        "properties" => %{"name" => %{"type" => "string", "default" => "fallback"}},
        "required" => ["name"],
        "additionalProperties" => false
      }

      assert :ok = Schema.validate(%{"name" => "test"}, schema)
      assert {:error, message} = Schema.validate(%{}, schema)
      assert message =~ "name"
      assert message =~ "required"
      assert {:error, message} = Schema.validate(%{"name" => "test", "extra" => true}, schema)
      assert message =~ "extra"
      assert message =~ "additional"
      assert :ok = Schema.validate(%{}, Map.delete(schema, "required"))
      assert :ok = Schema.validate(%{"name" => nil}, %{"required" => ["name"]})
      assert :ok = Schema.validate(%{"unknown" => 1}, %{"type" => "object"})
      assert :ok = Schema.validate(%{"unknown" => 1}, %{"additionalProperties" => true})
    end

    test "validates additional properties against their schema" do
      schema = %{
        "properties" => %{"label" => %{"type" => "string"}},
        "additionalProperties" => %{"type" => "integer"}
      }

      assert :ok = Schema.validate(%{"label" => "ok", "count" => 3}, schema)
      assert {:error, message} = Schema.validate(%{"label" => "ok", "count" => "3"}, schema)
      assert message =~ "count"
      assert message =~ "integer"
    end

    test "reports full paths through nested objects and array items" do
      schema = %{
        "properties" => %{
          "rows" => %{"items" => %{"properties" => %{"id" => %{"type" => "integer"}}}}
        }
      }

      assert :ok = Schema.validate(%{"rows" => [%{"id" => 1}]}, schema)

      assert {:error, message} =
               Schema.validate(%{"rows" => [%{"id" => 1}, %{"id" => "bad"}]}, schema)

      assert message =~ "$[\"rows\"][1][\"id\"]"
    end

    test "checks array lengths at inclusive boundaries" do
      schema = %{"type" => "array", "minItems" => 1, "maxItems" => 2}
      assert :ok = Schema.validate([nil], schema)
      assert :ok = Schema.validate([1, 2], schema)
      assert {:error, message} = Schema.validate([], schema)
      assert message =~ "minItems"
      assert {:error, message} = Schema.validate([1, 2, 3], schema)
      assert message =~ "maxItems"
    end

    test "counts Unicode code points rather than bytes or grapheme clusters" do
      schema = %{"type" => "string", "minLength" => 1, "maxLength" => 2}
      assert :ok = Schema.validate("я😀", schema)
      assert :ok = Schema.validate("e\u0301", schema)
      assert {:error, _} = Schema.validate("", schema)
      assert {:error, _} = Schema.validate("abc", schema)
      assert {:error, _} = Schema.validate("e\u0301", %{"maxLength" => 1})
      assert {:error, _} = Schema.validate("👩‍💻", schema)
    end

    test "checks inclusive and exclusive numeric boundaries" do
      assert :ok = Schema.validate(1, %{"minimum" => 1, "maximum" => 1})
      assert :ok = Schema.validate(1.5, %{"exclusiveMinimum" => 1, "exclusiveMaximum" => 2})
      assert :ok = Schema.validate(1, %{"min" => 1, "max" => 1})

      for {value, schema} <- [
            {0, %{"minimum" => 1}},
            {2, %{"maximum" => 1}},
            {1, %{"exclusiveMinimum" => 1}},
            {2, %{"exclusiveMaximum" => 2}},
            {0, %{"min" => 1}},
            {2, %{"max" => 1}}
          ] do
        assert {:error, _message} = Schema.validate(value, schema)
      end
    end

    test "checks multipleOf with exact decimal arithmetic without overflow" do
      for {value, divisor} <- [
            {0, 3},
            {-6, 3},
            {0.3, 0.1},
            {0.07, 0.01},
            {1.0e308, 1.0e-308},
            {9_007_199_254_740_993, 3}
          ] do
        assert :ok = Schema.validate(value, %{"multipleOf" => divisor})
      end

      for {value, divisor} <- [
            {1, 3},
            {0.31, 0.1},
            {0.30000000000000004, 0.1},
            {1.0e-308, 1.0e308},
            {9_007_199_254_740_993, 2}
          ] do
        assert {:error, message} = Schema.validate(value, %{"multipleOf" => divisor})
        assert message =~ "multipleOf"
      end
    end

    test "enum and const use structural JSON equality without coercing types" do
      assert :ok = Schema.validate(%{"items" => [1.0]}, %{"const" => %{"items" => [1]}})
      assert :ok = Schema.validate(1.0, %{"enum" => [1, "one"]})
      assert :ok = Schema.validate(nil, %{"const" => nil})
      assert {:error, _} = Schema.validate("1", %{"const" => 1})
      assert {:error, _} = Schema.validate(false, %{"enum" => [nil, 0]})
      assert {:error, _} = Schema.validate(%{"items" => [2]}, %{"const" => %{"items" => [1]}})
    end

    test "applies typed keywords only to matching JSON types" do
      assert :ok = Schema.validate(nil, %{"type" => ["string", "null"], "minLength" => 5})

      assert :ok =
               Schema.validate("text", %{"minimum" => 10, "minItems" => 2, "required" => ["id"]})

      assert :ok =
               Schema.validate(1, %{
                 "properties" => %{"id" => %{}},
                 "additionalProperties" => false
               })
    end

    test "anyOf accepts one or more matching branches" do
      schema = %{"anyOf" => [%{"type" => "integer"}, %{"type" => "number"}, %{"const" => nil}]}
      assert :ok = Schema.validate(1, schema)
      assert :ok = Schema.validate(1.5, schema)
      assert :ok = Schema.validate(nil, schema)
      assert {:error, message} = Schema.validate("1", schema)
      assert message =~ "anyOf"
    end

    test "oneOf requires exactly one matching branch" do
      schema = %{"oneOf" => [%{"type" => "integer"}, %{"type" => "number"}]}
      assert :ok = Schema.validate(1.5, schema)
      assert {:error, message} = Schema.validate(1, schema)
      assert message =~ "oneOf"
      assert message =~ "at least 2"
      assert {:error, message} = Schema.validate(nil, schema)
      assert message =~ "matched 0"
    end

    test "allOf and nested combinations preserve every constraint" do
      schema = %{
        "allOf" => [%{"type" => "integer"}, %{"anyOf" => [%{"minimum" => 2}, %{"const" => 0}]}]
      }

      assert :ok = Schema.validate(0, schema)
      assert :ok = Schema.validate(2, schema)
      assert {:error, message} = Schema.validate(1, schema)
      assert message =~ "allOf[1]"
      assert message =~ "anyOf"
      assert {:error, _} = Schema.validate(2.5, schema)
    end

    test "rejects non-JSON input even without matching property constraints" do
      for value <- [
            :atom,
            {1, 2},
            self(),
            fn -> :ok end,
            %URI{},
            %{key: 1},
            [1 | 2],
            <<255>>,
            %{"unknown" => %{key: true}},
            %{"unknown" => <<255>>}
          ] do
        assert {:error, message} = Schema.validate(value, %{})
        assert message =~ "$"
      end
    end

    test "leaves the input size limit to the runtime" do
      assert :ok = Schema.validate(String.duplicate("x", 70_000), %{"type" => "string"})
    end

    test "validates the schema before applying constraints" do
      assert {:error, message} = Schema.validate(%{}, %{"pattern" => "unsafe"})
      assert message =~ "schema"
      assert message =~ "unsupported"
    end
  end
end
