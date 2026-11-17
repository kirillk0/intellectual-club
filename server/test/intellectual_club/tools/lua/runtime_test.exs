defmodule IntellectualClub.Tools.Lua.RuntimeTest do
  use ExUnit.Case, async: false
  import IntellectualClub.TestEnv
  alias IntellectualClub.Tools.Lua.Runtime

  test "standard data libraries, recursion, random and pure sequence helpers are available" do
    source = """
    return { run = function(args, ctx)
      local function fact(n) if n < 2 then return 1 end return n * fact(n - 1) end
      math.randomseed(123)
      local xs = seq.filter(seq.map({1,2,3}, function(x) return x * 2 end), function(x) return x > 2 end)
      return { factorial = fact(6), total = seq.reduce(xs, function(a,b) return a+b end, 0),
        upper = ("abc"):upper(), length = utf8.len("Привет"), random = math.random(1, 6),
        found = seq.find(xs, function(x) return x == 6 end),
        any = seq.any(xs, function(x) return x == 4 end), all = seq.all(xs, function(x) return x > 3 end),
        time = os.time({year=2026, month=1, day=1, hour=0}), date = os.date("%Y", 0) }
    end }
    """

    assert {:ok, %{"result" => result, "logs" => []}, %{}} = run(source)
    assert result["factorial"] == 720
    assert result["total"] == 10
    assert result["length"] == 6
    assert result["upper"] == "ABC"
    assert result["found"] == 6
    assert result["any"] and result["all"]
    assert result["random"] in 1..6
    assert result["date"] == "1970"
    assert is_integer(result["time"])
  end

  test "ambient IO, environment, dynamic code, debug and package APIs are absent" do
    assert {:ok, %{"result" => true}, %{}} =
             run("""
             return { run = function()
               for _, name in ipairs({"io", "debug", "package", "require", "load", "loadfile", "dofile", "collectgarbage"}) do
                 assert(_G[name] == nil, name)
               end
               assert(os.getenv == nil and os.execute == nil and os.tmpname == nil and os.exit == nil and os.setlocale == nil)
               return true
             end }
             """)
  end

  test "JSON preserves nested objects, empty arrays, nulls and state edits" do
    args = %{"array" => [], "object" => %{}, "null" => nil, "nested" => [false, nil, %{}, []]}

    assert {:ok, %{"result" => ^args}, %{"copy" => ^args}} =
             run(
               """
               return { run = function(args, ctx)
                 assert(args.null == json.null)
                 ctx.state.copy = json.decode(json.encode(args))
                 return ctx.state.copy
               end }
               """,
               args
             )

    assert {:ok, %{"result" => [[], %{}, nil, %{}]}, %{}} =
             run("""
             return { run = function() return {json.array(), json.object(), json.null, {}} end }
             """)
  end

  test "JSON rejects cycles, holes, mixed keys, functions, invalid strings and nonobject state" do
    for body <- [
          "local x = {}; x.self = x; return x",
          "return {[1]=1, [3]=3}",
          "return {[1]=1, key=2}",
          "return {callback=function() end}",
          "return string.char(255)",
          "ctx.state = json.array(); return true",
          "return 1, 2"
        ] do
      assert {:error, _} = run("return {run=function(args, ctx) " <> body <> " end}")
    end
  end

  test "fresh calls cannot observe globals or random seeds from an earlier call" do
    assert {:ok, %{"result" => 1}, %{}} =
             run("counter = (counter or 0) + 1; return {run=function() return counter end}")

    assert {:ok, %{"result" => 1}, %{}} =
             run("counter = (counter or 0) + 1; return {run=function() return counter end}")

    script = "return {run=function() math.randomseed(24); return math.random() end}"
    assert {:ok, first, %{}} = run(script)
    assert {:ok, ^first, %{}} = run(script)
  end

  test "print is returned as bounded per-call logs rather than server output" do
    assert {:ok, %{"result" => nil, "logs" => ["hello\t42"]}, %{}} =
             run("return {run=function() print('hello',42) end}")

    put_app_env(:lua_tool_limits, log_bytes: 5)
    assert {:error, message} = run("return {run=function() print('too long') end}")
    assert message =~ "log limit"
  end

  test "instruction, call depth, allocation and JSON limits stop erroneous scripts" do
    put_app_env(:lua_tool_limits, max_instructions: 200, max_call_depth: 16)

    for source <- [
          "return {run=function() while true do end end}",
          "return {run=function() local function f() return 1+f() end return f() end}",
          "return {run=function() return string.rep('a',2000000) end}",
          "return {run=function() return string.rep('a',300000) end}"
        ] do
      assert {:error, _message} = run(source)
    end
  end

  test "native string builders reject large allocations before materializing them" do
    put_app_env(:lua_tool_limits, max_string_bytes: 2_048)

    for body <- [
          "return string.pack('c1000000000', 'x')",
          "return table.concat({string.rep('x',1500),string.rep('x',1500)})",
          "return string.format('%s%s',string.rep('x',1500),string.rep('x',1500))",
          "return (string.gsub(string.rep('x',100),'.',string.rep('y',100)))",
          "return (string.gsub(string.rep('x',100),'.',function() return string.rep('y',100) end))"
        ] do
      assert {:error, message} = run("return {run=function() " <> body <> " end}")
      assert message =~ "limit"
    end
  end

  test "guarded helpers retain ordinary formatting, pack, replacement and metatable semantics" do
    assert {:ok, %{"result" => ["007", "ok", "a:b", "Xbc", "<a><b>", "xb"]}, %{}} =
             run("""
             return {run=function()
               local packed = string.pack("c2", "ok")
               local values = setmetatable({}, {__index=function(_,i) return ({"a","b"})[i] end, __len=function() return 2 end})
               local replaced = string.gsub("abc","a",function() return "X" end)
               local captured = string.gsub("ab","(.)","<%1>")
               local mapped = string.gsub("ab",".",{a="x"})
               return {string.format("%03d",7), packed, table.concat(values,":"), replaced, captured, mapped}
             end}
             """)
  end

  test "protected host errors preserve preceding state edits" do
    for call <- [
          "json.decode('invalid')",
          "json.encode(function() end)",
          "json.array(false)",
          "json.object(false)",
          "http.request({url=function() end})",
          "table.concat({false})",
          "string.pack('c1000000000', 'x')"
        ] do
      assert {:ok, %{"result" => false}, %{"count" => 7}} =
               run("""
               return {run=function(args, ctx)
                 ctx.state.count = 1
                 local ok = pcall(function()
                   ctx.state.count = 7
                   #{call}
                 end)
                 return ok
               end}
               """)
    end
  end

  test "handled host errors retain the cumulative instruction budget" do
    put_app_env(:lua_tool_limits, max_instructions: 1_000)

    assert {:error, message} =
             run("""
             return {run=function()
               for i=1,100 do
                 pcall(function()
                   local n=0
                   for j=1,20 do n=n+j end
                   json.decode("invalid")
                 end)
               end
               return true
             end}
             """)

    assert message =~ "instruction"
  end

  test "protected replacement and metatable errors preserve callback state and error values" do
    assert {:ok, %{"result" => %{"message" => "stopped"}}, %{"count" => 7}} =
             run("""
             return {run=function(args, ctx)
               local ok, err = pcall(function()
                 string.gsub("abc", ".", function()
                   ctx.state.count = 7
                   error({message="stopped"})
                 end)
               end)
               assert(not ok)
               return err
             end}
             """)

    put_app_env(:lua_tool_limits, max_string_bytes: 32)

    for call <- [
          ~s|string.gsub("a", ".", function() ctx.state.count = 7; return string.rep("x",32) end)|,
          ~s|table.concat(setmetatable({}, {__index=function() ctx.state.count=7; return false end}), "", 1, 1)|
        ] do
      assert {:ok, %{"result" => false}, %{"count" => 7}} =
               run("""
               return {run=function(args, ctx)
                 local ok = pcall(function() #{call} end)
                 return ok
               end}
               """)
    end
  end

  test "whole-match replacements count nonoverlapping matches without quadratic allocation estimates" do
    put_app_env(:lua_tool_limits, max_string_bytes: 2_048)

    assert {:ok, %{"result" => true}, %{}} =
             run("""
             return {run=function()
               local source = string.rep("x", 2048)
               local result, count = string.gsub(source, ".", "%0")
               assert(result == source and count == 2048)
               assert(string.gsub("a", ".", "%%0") == "%0")
               return true
             end}
             """)
  end

  test "unpermitted HTTP fails without network access, including a protected call" do
    assert {:ok, %{"result" => false}, %{}} =
             run("""
             return {run=function()
               local ok = pcall(http.request, {method="GET", url="https://example.com/"})
               return ok
             end}
             """)
  end

  test "syntax validation compiles only and never executes top-level code" do
    assert :ok = Runtime.validate_source("while true do end", :runtime_test)
    assert {:error, message} = Runtime.validate_source("return {", :runtime_test)
    assert is_binary(message)
  end

  defp run(source, args \\ %{}, state \\ %{}),
    do: Runtime.execute(source, "run", args, state, [], %{}, :runtime_test)
end
