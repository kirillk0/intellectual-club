defmodule IntellectualClub.Tools.Drivers.DriverContractTest do
  @moduledoc """
  Behavior shared by the built-in tool drivers: fixed function lists, argument,
  configuration and context validation before any I/O, unknown functions and
  image MIME detection. Driver-specific behavior lives in the per-driver files.
  """

  use IntellectualClub.DataCase, async: true

  alias IntellectualClub.Tools.Drivers.NativeArtifactReader
  alias IntellectualClub.Tools.Drivers.NativeBraveSearch
  alias IntellectualClub.Tools.Drivers.NativeGameTools
  alias IntellectualClub.Tools.Drivers.NativeWebReader
  alias IntellectualClub.Tools.Drivers.Ssh
  alias IntellectualClub.Tools.ExecutionContext
  alias IntellectualClub.Tools.ToolInstance

  @ssh_config %{"host" => "example.com", "username" => "root"}
  @ssh_password %{"password" => "secret"}

  describe "fixed_functions/1" do
    for {driver, type, expected} <- [
          {NativeArtifactReader, "native-artifact-reader",
           {:exactly, ["read_file", "search_file", "read_image", "upload_file"]}},
          {NativeBraveSearch, "native-web-search", {:includes, ["web_search"]}},
          {NativeGameTools, "native-game-tools", {:includes, ["random_select"]}},
          {NativeWebReader, "native-web-reader", {:includes, ["read_url", "search_url"]}}
        ] do
      @driver driver
      @type_name type
      @expected expected

      test "#{inspect(driver)} exposes its fixed functions" do
        names =
          %ToolInstance{type: @type_name, config: %{}, secrets: %{}}
          |> @driver.fixed_functions()
          |> Enum.map(&Map.get(&1, "name"))

        case @expected do
          {:exactly, expected} -> assert names == expected
          {:includes, expected} -> assert expected -- names == []
        end
      end
    end
  end

  # {name, driver, {type, config, secrets}, function, args, context?, expected}
  @validation_cases [
    {"web search requires an API key", NativeBraveSearch, {"native-web-search", %{}, %{}},
     "web_search", %{"query" => "elixir"}, false, {:tool_error, "API key"}},
    {"web search requires a query", NativeBraveSearch,
     {"native-web-search", %{}, %{"brave_api_key" => "brave-token"}}, "web_search", %{}, false,
     {:contains, "Argument `query` is required."}},
    {"read_url requires url", NativeWebReader, {"native-web-reader", %{}, %{}}, "read_url", %{},
     false, "Argument `url` is required."},
    {"read_url validates page", NativeWebReader, {"native-web-reader", %{}, %{}}, "read_url",
     %{"url" => "https://example.com", "page" => -1}, false,
     "Argument `page` must be a non-negative integer (1-based)."},
    {"search_url requires regex", NativeWebReader, {"native-web-reader", %{}, %{}}, "search_url",
     %{"url" => "https://example.com"}, false, "Argument `regex` is required."},
    {"ssh requires config.host", Ssh,
     {"ssh", %{"host" => "", "username" => "root"}, @ssh_password}, "run_command",
     %{"command" => "echo ok"}, false, "Tool instance config.host is required."},
    {"ssh requires a command", Ssh, {"ssh", @ssh_config, @ssh_password}, "run_command", %{},
     false, "Argument `command` or `argv` is required."},
    {"ssh requires credentials", Ssh, {"ssh", @ssh_config, %{}}, "run_command",
     %{"command" => "echo ok"}, false, {:contains_downcased, "credentials"}},
    {"artifact reader requires an execution context", NativeArtifactReader,
     {"native-artifact-reader", %{}, %{}}, "read_file",
     %{"file_id" => "00000000-0000-4000-8000-000000000001"}, false,
     "Execution context is required for read_file."},
    {"read_file requires file_id", NativeArtifactReader, {"native-artifact-reader", %{}, %{}},
     "read_file", %{}, true, "Argument `file_id` is required."},
    {"read_file requires a UUID file_id", NativeArtifactReader,
     {"native-artifact-reader", %{}, %{}}, "read_file", %{"file_id" => "bad"}, true,
     "Argument `file_id` must be a valid UUID."},
    {"read_file validates page", NativeArtifactReader, {"native-artifact-reader", %{}, %{}},
     "read_file", %{"file_id" => "00000000-0000-4000-8000-000000000001", "page" => -1}, true,
     "Argument `page` must be a non-negative integer (1-based)."},
    {"search_file validates regex", NativeArtifactReader, {"native-artifact-reader", %{}, %{}},
     "search_file", %{"file_id" => "00000000-0000-4000-8000-000000000001", "regex" => "["}, true,
     {:starts_with, "Invalid regex:"}}
  ]

  describe "execute/3,4 validation" do
    for {name, driver, instance, function, args, context?, expected} <- @validation_cases do
      @driver driver
      @instance instance
      @function function
      @args args
      @context? context?
      @expected expected

      test name do
        {type, config, secrets} = @instance
        tool_instance = %ToolInstance{type: type, config: config, secrets: secrets}

        result =
          if @context? do
            context = %ExecutionContext{owner_id: 1, chat_id: 1}
            @driver.execute(tool_instance, @function, @args, context)
          else
            @driver.execute(tool_instance, @function, @args)
          end

        assert_result(@expected, result)
      end
    end

    for {driver, type, config, secrets} <- [
          {NativeArtifactReader, "native-artifact-reader", %{}, %{}},
          {NativeBraveSearch, "native-web-search", %{}, %{}},
          {NativeGameTools, "native-game-tools", %{}, %{}},
          {NativeWebReader, "native-web-reader", %{}, %{}},
          {Ssh, "ssh", @ssh_config, @ssh_password}
        ] do
      @driver driver
      @tool_instance %ToolInstance{type: type, config: config, secrets: secrets}

      test "#{inspect(driver)} rejects unknown functions" do
        assert {:error, "Unknown function: unknown"} =
                 @driver.execute(@tool_instance, "unknown", %{})
      end
    end
  end

  describe "configuration validation on create" do
    test "SSH requires the config fields declared by its schema" do
      %{user: actor} = user_fixture()

      assert {:error, error} =
               ToolInstance
               |> Ash.Changeset.for_create(
                 :create,
                 %{
                   type: "ssh",
                   name: "SSH",
                   config: %{"host" => "", "username" => ""},
                   secrets: %{"password" => "secret"},
                   max_output_tokens: 20_000
                 },
                 actor: actor
               )
               |> Ash.create()

      message = Exception.message(error)
      assert message =~ "Host is required."
      assert message =~ "Username is required."
    end

    test "web search stores a legacy token secret as the Brave API key" do
      %{user: actor} = user_fixture()

      tool_instance =
        create_tool_instance!(actor,
          type: "native-web-search",
          secrets: %{"token" => "brave-token"}
        )

      assert tool_instance.secrets == %{"brave_api_key" => "brave-token"}

      assert {:error, message} = NativeBraveSearch.execute(tool_instance, "web_search", %{})
      assert message =~ "Argument `query` is required."
    end
  end

  describe "detect_image_mime/1" do
    for driver <- [NativeArtifactReader, Ssh] do
      @driver driver

      test "#{inspect(driver)} detects images and rejects other payloads" do
        assert {:ok, "image/png"} = @driver.detect_image_mime(png_1x1())

        assert {:error, "File content is not a valid image."} =
                 @driver.detect_image_mime("<html><body>404 Not Found</body></html>")
      end
    end
  end

  defp assert_result({:tool_error, text}, {:ok, result}) do
    assert result.raw["isError"]
    assert result.text =~ text
  end

  defp assert_result({:contains, text}, {:error, message}), do: assert(message =~ text)

  defp assert_result({:contains_downcased, text}, {:error, message}),
    do: assert(String.downcase(message) =~ text)

  defp assert_result({:starts_with, text}, {:error, message}),
    do: assert(String.starts_with?(message, text))

  defp assert_result(message, result) when is_binary(message),
    do: assert(result == {:error, message})

  defp assert_result(expected, result),
    do: flunk("expected #{inspect(expected)}, got #{inspect(result)}")
end
